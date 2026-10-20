import XCTest
@testable import PersonalAICore

final class ChatControllerTests: XCTestCase {
    func makeController(engine: ScriptedEngine, dir: URL) throws -> (ChatController, ArchiveStore, ArchiveDatabase) {
        let db = try ArchiveDatabase(path: dir.appendingPathComponent("a.sqlite").path, profile: .phone)
        let store = ArchiveStore(db: db)
        let ents = EntityStore(db: db), mem = MemoryStore(archive: store)
        let retriever = HybridRetriever(archive: store, vectors: nil, embedder: nil, memory: mem, entities: ents)
        let assembler = PromptAssembler(archive: store, retriever: retriever, memory: mem, counter: HeuristicTokenCounter())
        let c = ChatController(archive: store, assembler: assembler, engine: engine,
                               profile: { ModelProfile(id: "t", maxContext: 8192, weightsBytes: 1_000_000_000, kvBytesPerToken: 20_000) },
                               device: { DeviceBudget(availableMemoryBytes: 4_000_000_000) })
        return (c, store, db)
    }
    func collect(_ s: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] { var out: [ChatEvent] = []; for try await e in s { out.append(e) }; return out }

    func testTwoTurnsArePersistedAndSecondTurnSeesFirst() async throws {
        let (db, dir) = try makeTempDB(); _ = db; defer { try? FileManager.default.removeItem(at: dir) }
        let engine = ScriptedEngine { m in "ack: \(m.last!.content.suffix(30))" }
        let (c, store, _) = try makeController(engine: engine, dir: dir)
        let ev1 = try await collect(c.send(conversationID: nil, text: "Remember that my locker code is 4417."))
        guard case .conversation(let cid) = ev1.first! else { return XCTFail("first event must announce the new conversation") }
        _ = try await collect(c.send(conversationID: cid, text: "What did I just tell you?"))
        let msgs = try store.tail(conversationID: cid, limit: 10)
        XCTAssertEqual(msgs.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(msgs[0].locality, .local)
        XCTAssertEqual(msgs[1].model, "scripted")
        XCTAssertTrue(engine.lastMessages.contains { $0.content.contains("locker code is 4417") }, "turn 2 prompt must contain turn 1 from history")
        XCTAssertEqual(engine.lastMessages.filter { $0.content.contains("What did I just tell you?") }.count, 1, "the new question appears exactly once, not duplicated into history")
    }

    func testCloudEngineIsRefusedUntilExplicitlyAllowedAndNothingIsStoredOrSent() async throws {
        let (_, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = ScriptedEngine(); engine.locality = .cloud
        let (c, store, _) = try makeController(engine: engine, dir: dir)
        do { _ = try await collect(c.send(conversationID: nil, text: "private thought")); XCTFail("must throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Remote processing is switched off")) }
        XCTAssertEqual(engine.calls, 0, "the engine was never invoked")
        XCTAssertEqual(try store.stats().messages, 0)
        c.remoteAllowed = { true }
        let ev = try await collect(c.send(conversationID: nil, text: "now allowed"))
        XCTAssertEqual(engine.calls, 1)
        if case .finished(let m, _) = ev.last! { XCTAssertEqual(m.locality, .cloud, "cloud output is labelled as cloud in the archive") } else { XCTFail() }
    }

    func testFailureMidStreamKeepsUserMessageAndPartialReplyFlagged() async throws {
        let (_, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = ScriptedEngine { _ in "one two three four five six" }; engine.failAfterTokens = 3
        let (c, store, _) = try makeController(engine: engine, dir: dir)
        let ev = try await collect(c.send(conversationID: nil, text: "count for me"))
        guard case .interrupted(let saved, _) = ev.last! else { return XCTFail("expected interruption") }
        XCTAssertEqual(saved?.text, "one two three")
        XCTAssertTrue(saved?.meta?.contains("interrupted") ?? false)
        XCTAssertEqual(try store.stats().messages, 2)
    }

    func testPastConversationIsRetrievedIntoANewChatAndAnswerIsGrounded() async throws {
        let (_, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        // the "model" can only answer from what the prompt contains
        let engine = ScriptedEngine { m in
            let last = m.last!.content
            if let r = last.range(of: "Casa do Largo") { return "From your history: " + String(last[r.lowerBound...].prefix(40)) }
            return "I don't have that."
        }
        let (c, store, db) = try makeController(engine: engine, dir: dir)
        let src = try store.upsertSource(kind: "chatgpt", name: "old", externalID: "o")
        let (old, _) = try store.upsertConversation(sourceID: src, externalID: "trip", title: "Lisbon trip", createdAt: 1_700_000_000, updatedAt: 1_700_000_000)
        _ = try store.appendMessages(conversationID: old, [NewMessage(role: .user, text: "I booked the guesthouse Casa do Largo for 95 euros a night.", createdAt: 1_700_000_000)])
        let pipe = IndexingPipeline(archive: store, chunker: Chunker(store: store), vectors: nil, embedder: nil)
        _ = try pipe.chunkStep(conversations: 10)
        _ = db
        let ev = try await collect(c.send(conversationID: nil, text: "Which guesthouse did I book for the trip?"))
        let prepared = ev.compactMap { e -> PreparedTurn? in if case .prepared(let p) = e { return p } else { return nil } }.first!
        XCTAssertFalse(prepared.citations.isEmpty, "evidence from the old chat must be cited")
        guard case .finished(let m, _) = ev.last! else { return XCTFail() }
        XCTAssertTrue(m.text.contains("Casa do Largo"))
        let cited = try store.messages(ids: prepared.citations.flatMap(\.messageIDs))
        XCTAssertTrue(cited.values.contains { $0.text.contains("Casa do Largo") }, "citation resolves to the original archived message")
    }
}
