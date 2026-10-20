import XCTest
@testable import PersonalAICore

final class RetrievalTests: XCTestCase {
    struct World {
        let db: ArchiveDatabase, dir: URL, store: ArchiveStore, memory: MemoryStore, entities: EntityStore
        let retriever: HybridRetriever, ids: [String: Int64], vectors: VectorIndex
    }

    /// A small hand-written life: several topics across months, plus synthetic noise, indexed with chunks + hashing embeddings.
    func world(noise: Int = 3000) async throws -> World {
        let (db, dir) = try makeTempDB()
        let store = ArchiveStore(db: db)
        try SyntheticArchive(seed: 9).generate(into: store, messages: noise, avgConversationLength: 20, years: 2, end: Date(timeIntervalSince1970: ts("2025-06-01T00:00:00Z")))
        let src = try store.upsertSource(kind: "generic", name: "real", externalID: "real")
        var ids: [String: Int64] = [:]
        func conv(_ name: String, _ title: String, _ start: String, _ lines: [(Role, String)]) throws {
            let t0 = ts(start)
            let (c, _) = try store.upsertConversation(sourceID: src, externalID: name, title: title, createdAt: t0, updatedAt: t0)
            ids["conv:" + name] = c
            try store.appendMessages(conversationID: c, lines.enumerated().map { NewMessage(role: $1.0, text: $1.1, createdAt: t0 + Double($0) * 60, externalID: "\(name)-\($0)") })
            for i in 0..<lines.count { ids["\(name)-\(i)"] = try db.read { try $0.scalarInt("SELECT id FROM message WHERE conversation_id=? AND seq=?", [.int(c), .int(i)]) } }
        }
        try conv("lisbon", "Lisbon trip", "2025-01-10T09:00:00Z", [
            (.user, "I'm planning a trip to Lisbon in April. I want somewhere quiet near Alfama."),
            (.assistant, "Alfama is lovely. Consider Hotel Santiago de Alfama or a guesthouse near the Sé."),
            (.user, "I picked Casa do Largo, the small guesthouse. It was 95 euros a night and has a terrace."),
            (.assistant, "Great choice. Book early for April."),
        ])
        try conv("garden", "Balcony garden", "2025-03-05T18:00:00Z", [
            (.user, "I decided to grow tomatoes on the balcony, but only shade varieties because it gets four hours of sun."),
            (.assistant, "Black Krim and Cherokee Purple tolerate shade."),
            (.user, "Decision made: Black Krim in the large pot, basil in the small one."),
        ])
        try conv("health", "Diet notes", "2025-02-14T12:00:00Z", [
            (.user, "I'm allergic to cashews so please never suggest recipes with them."),
            (.assistant, "Understood, no cashews."),
            (.user, "Also I stopped eating dairy in January."),
        ])
        try conv("alex-work", "Work chat", "2025-04-01T10:00:00Z", [
            (.user, "Alex from work wants the quarterly slides by Friday and keeps changing the template."),
            (.assistant, "That sounds frustrating."),
        ])
        try conv("alex-bro", "Family", "2025-04-20T10:00:00Z", [
            (.user, "My brother Alex is moving to Porto next month and asked if I could help him pack."),
            (.assistant, "Porto is lovely."),
        ])
        let archive = db
        let ents = EntityStore(db: archive)
        let coworker = try ents.create(kind: "person", name: "Alex", description: "coworker", aliases: ["alex from work"])
        let brother = try ents.create(kind: "person", name: "Alex", description: "brother", aliases: ["my brother alex", "brother alex", "alex's"])
        try ents.recordMention(entity: coworker, messageID: ids["alex-work-0"]!, conversationID: ids["conv:alex-work"]!, at: ts("2025-04-01T10:00:00Z"))
        try ents.recordMention(entity: brother, messageID: ids["alex-bro-0"]!, conversationID: ids["conv:alex-bro"]!, at: ts("2025-04-20T10:00:00Z"))
        ids["coworker"] = coworker; ids["brother"] = brother

        let embedder = HashingEmbedder(dim: 256)
        let vectors = try VectorIndex(archive: db, space: 1, name: "chunks", embedderID: embedder.id, dim: embedder.dim)
        let pipe = IndexingPipeline(archive: store, chunker: Chunker(store: store), vectors: vectors, embedder: embedder)
        pipe.embedBatch = 256
        try pipe.chunkStep(conversations: 100_000)
        while try await pipe.embedStep() > 0 {}
        let mem = MemoryStore(archive: store)
        let r = HybridRetriever(archive: store, vectors: vectors, embedder: embedder, memory: mem, entities: ents)
        r.memoryVectors = try VectorIndex(archive: db, space: 3, name: "memories", embedderID: embedder.id, dim: embedder.dim, itemKind: "memory")
        return World(db: db, dir: dir, store: store, memory: mem, entities: ents, retriever: r, ids: ids, vectors: vectors)
    }

    func pipe(_ w: World) -> IndexingPipeline { IndexingPipeline(archive: w.store, chunker: Chunker(store: w.store), vectors: w.vectors, embedder: HashingEmbedder(dim: 256)) }

    func testExactAndTimeBoundedAndCrossChatRecall() async throws {
        let w = try await world(); defer { try? FileManager.default.removeItem(at: w.dir) }
        // exact original message
        var r = try await w.retriever.retrieve("find the original message where I said I'm allergic to cashews")
        XCTAssertEqual(r.confidence, .good)
        XCTAssertTrue(r.spans.first?.messages.contains { $0.id == w.ids["health-0"] } ?? false, "top evidence must be the original message")

        // new chat, continuing an old topic, no title given
        r = try await w.retriever.retrieve("back to the trip: which guesthouse did I choose and how much was it?", context: RetrievalContext(now: Date(timeIntervalSince1970: ts("2025-05-01T00:00:00Z"))))
        XCTAssertTrue(r.spans.prefix(2).contains { $0.messages.contains { $0.id == w.ids["lisbon-2"] } }, "old conversation recovered without naming it; got \(r.spans.map { ($0.conversationTitle, $0.channels, $0.score) }) plan terms \(r.plan.terms) diag \(r.diagnostics)")

        // date-bounded
        r = try await w.retriever.retrieve("what did I decide about the balcony in March 2025", context: RetrievalContext(now: Date(timeIntervalSince1970: ts("2025-06-01T00:00:00Z"))))
        XCTAssertEqual(r.plan.time?.hard, true)
        XCTAssertTrue(r.spans.allSatisfy { $0.date.timeIntervalSince1970 >= ts("2025-03-01T00:00:00Z") && $0.date.timeIntervalSince1970 < ts("2025-04-01T00:00:00Z") })
        XCTAssertTrue(r.spans.first?.messages.contains { $0.id == w.ids["garden-2"] } ?? false)
    }

    func testUnrelatedQueryReturnsNothingRatherThanInventingAConnection() async throws {
        let w = try await world(); defer { try? FileManager.default.removeItem(at: w.dir) }
        let r = try await w.retriever.retrieve("explain lattice quantum chromodynamics confinement")
        XCTAssertEqual(r.confidence, .none, "no relevant history => say so; spans: \(r.spans.map { $0.conversationTitle })")
        XCTAssertTrue(r.spans.isEmpty)
    }

    func testSimpleTurnsSkipRetrievalCompletely() async throws {
        let w = try await world(); defer { try? FileManager.default.removeItem(at: w.dir) }
        for q in ["thanks", "ok", "continue"] {
            let r = try await w.retriever.retrieve(q)
            XCTAssertNotNil(r.diagnostics.skipped, q)
            XCTAssertTrue(r.spans.isEmpty)
        }
    }

    func testSimilarPeopleAreNotMixedUp() async throws {
        let w = try await world(); defer { try? FileManager.default.removeItem(at: w.dir) }
        let r = try await w.retriever.retrieve("what did my brother Alex ask me to do")
        XCTAssertEqual(r.plan.entityIDs, [w.ids["brother"]!])
        XCTAssertTrue(r.spans.first?.messages.contains { $0.id == w.ids["alex-bro-0"] } ?? false)
        XCTAssertFalse(r.spans.prefix(1).contains { $0.messages.contains { $0.id == w.ids["alex-work-0"] } }, "coworker Alex must not outrank brother Alex")
    }

    func testMemoryBackedEvidenceAndStandingInstructions() async throws {
        let w = try await world(); defer { try? FileManager.default.removeItem(at: w.dir) }
        let o = try w.memory.propose(CandidateMemory(kind: .constraint, epistemic: .stated, text: "The user is allergic to cashews", value: "cashews",
                                                     standing: true, evidence: [CandidateEvidence(messageID: w.ids["health-0"]!, quote: "I'm allergic to cashews")], createdBy: "rule"))
        guard case .created = o else { return XCTFail("\(o)") }
        let p = pipe(w); p.memoryVectors = w.retriever.memoryVectors
        _ = try await p.embedMemoriesStep()
        let r = try await w.retriever.retrieve("what should I cook tonight, I want something with nuts")
        XCTAssertEqual(r.standing.first?.text, "The user is allergic to cashews", "standing constraints ride along even when the query shares no words")
        // NOTE: paraphrase ("allergies" vs "allergic") needs a neural embedder; the hashing test double only proves the plumbing, so use a lexical overlap here.
        let r2 = try await w.retriever.retrieve("which food am I allergic to")
        XCTAssertTrue(r2.memories.contains { $0.memory.text.contains("cashews") })
        XCTAssertTrue(r2.spans.contains { $0.messages.contains { $0.id == w.ids["health-0"] } }, "the memory's evidence is surfaced as the original message")
    }

    func testNeedleNearBeginningOfAThousandMessageConversation() async throws {
        let (db, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveStore(db: db)
        let src = try store.upsertSource(kind: "generic", name: "t", externalID: "t")
        let (c, _) = try store.upsertConversation(sourceID: src, externalID: "long", title: "Long project chat", createdAt: 0, updatedAt: 0)
        var msgs: [NewMessage] = []
        for i in 0..<1500 {
            let text = i == 17 ? "Constraint: the API must stay backwards compatible with v2 clients until the Kestrel migration finishes." : "message number \(i) about the build pipeline and unrelated chatter \(i % 13)"
            msgs.append(NewMessage(role: i % 2 == 0 ? .user : .assistant, text: text, createdAt: Double(i) * 30, externalID: "m\(i)"))
        }
        try store.appendMessages(conversationID: c, msgs)
        let mem = MemoryStore(archive: store); let ents = EntityStore(db: db)
        let r = HybridRetriever(archive: store, vectors: nil, embedder: nil, memory: mem, entities: ents)
        // the visible tail is the last 40 messages: the constraint is far outside it, so it must be *retrieved*, not assumed
        let res = try await r.retrieve("is the Kestrel migration constraint still in force? what was it exactly", context: RetrievalContext(currentConversationID: c, visibleTailStartSeq: 1460))
        XCTAssertTrue(res.spans.first?.messages.contains { $0.seq == 17 } ?? false)
        XCTAssertTrue(res.spans.allSatisfy { $0.lastSeq < 1460 }, "never duplicates what is already verbatim in the prompt")
    }

    func testTimeParser() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let p = TimeParser(calendar: cal)
        let now = Date(timeIntervalSince1970: ts("2025-06-15T12:00:00Z"))
        let m = p.parse("what happened in March", now: now)!
        XCTAssertEqual(m.from, ts("2025-03-01T00:00:00Z")); XCTAssertEqual(m.to, ts("2025-04-01T00:00:00Z")); XCTAssertTrue(m.hard)
        let y = p.parse("in November", now: now)!
        XCTAssertEqual(y.from, ts("2024-11-01T00:00:00Z"), "most recent past November")
        let few = p.parse("a few months ago I said", now: now)!
        XCTAssertFalse(few.hard); XCTAssertLessThan(few.from, ts("2025-03-15T00:00:00Z"))
        XCTAssertEqual(p.parse("in 2023", now: now)!.from, ts("2023-01-01T00:00:00Z"))
        XCTAssertEqual(p.parse("yesterday", now: now)!.from, ts("2025-06-14T00:00:00Z"))
        XCTAssertNil(p.parse("I may like that", now: now), "'may' the verb is not May the month")
    }
}
