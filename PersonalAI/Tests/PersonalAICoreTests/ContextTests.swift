import XCTest
@testable import PersonalAICore

final class ContextTests: XCTestCase {
    let model = ModelProfile(id: "test-4b", maxContext: 131_072, weightsBytes: 2_300_000_000, kvBytesPerToken: 40_000, measuredPrefillTPS: 400, supportsPrefixCache: true)
    let device = DeviceBudget(availableMemoryBytes: 4_800_000_000)

    func testPlannerRespectsMemoryThermalAndLatency() {
        let p = ContextPlanner()
        let deep = p.plan(model: model, device: device, complexity: .deep, conversationTokens: 50_000)
        let simple = p.plan(model: model, device: device, complexity: .trivial, conversationTokens: 50_000)
        XCTAssertGreaterThan(deep.windowTokens, simple.windowTokens, "a simple question must not pay for a deep one's context")
        XCTAssertLessThanOrEqual(deep.windowTokens, deep.memoryCeilingTokens)
        // tight memory => memory-limited
        let tight = p.plan(model: model, device: DeviceBudget(availableMemoryBytes: 3_600_000_000), complexity: .deep, conversationTokens: 50_000)
        XCTAssertLessThan(tight.windowTokens, deep.windowTokens)
        XCTAssertTrue(tight.notes.contains { $0.contains("memory-limited") })
        // thermal
        let hot = p.plan(model: model, device: DeviceBudget(availableMemoryBytes: 4_800_000_000, thermal: .serious), complexity: .deep, conversationTokens: 50_000)
        XCTAssertLessThanOrEqual(hot.windowTokens, deep.windowTokens / 2)
        let crit = p.plan(model: model, device: DeviceBudget(availableMemoryBytes: 4_800_000_000, thermal: .critical), complexity: .deep, conversationTokens: 50_000)
        XCTAssertEqual(crit.windowTokens, 2048)
        // time-to-first-token budget limits volatile evidence when the model prefills slowly
        var slow = model; slow.measuredPrefillTPS = 60
        let slowPlan = p.plan(model: slow, device: device, complexity: .standard, conversationTokens: 1000)
        XCTAssertLessThan(slowPlan.evidenceBudget, p.plan(model: model, device: device, complexity: .standard, conversationTokens: 1000).evidenceBudget)
    }

    func makeLongConversation(messages n: Int) throws -> (ArchiveStore, HybridRetriever, MemoryStore, Int64, URL) {
        let (db, dir) = try makeTempDB()
        let store = ArchiveStore(db: db)
        let src = try store.upsertSource(kind: "app", name: "app", externalID: "app")
        let (c, _) = try store.upsertConversation(sourceID: src, externalID: "proj", title: "Kestrel project", createdAt: 0, updatedAt: 0, origin: "local")
        var msgs: [NewMessage] = []
        for i in 0..<n {
            let text: String
            switch i {
            case 17: text = "Constraint: the API must stay backwards compatible with v2 clients until the Kestrel migration finishes in October."
            case 40: text = "Decision: we will use SQLite, not Postgres, for the sync layer because it must run on the phone."
            default: text = (i % 2 == 0 ? "User question \(i): how do we handle caching for the build step number \(i % 29)? " : "Assistant answer \(i): consider caching artifacts by hash, step \(i % 29), and invalidate when inputs change. ") + String(repeating: "filler words about pipeline details ", count: 6)
            }
            msgs.append(NewMessage(role: i % 2 == 0 ? .user : .assistant, text: text, createdAt: Double(i) * 45, externalID: "m\(i)", locality: .local))
        }
        try store.appendMessages(conversationID: c, msgs)
        let mem = MemoryStore(archive: store)
        let r = HybridRetriever(archive: store, vectors: nil, embedder: nil, memory: mem, entities: EntityStore(db: db))
        return (store, r, mem, c, dir)
    }

    func testThousandMessageConversationStaysWithinBudgetAndRecoversEarlyConstraint() async throws {
        let (store, retriever, mem, c, dir) = try makeLongConversation(messages: 1500); defer { try? FileManager.default.removeItem(at: dir) }
        let asm = PromptAssembler(archive: store, retriever: retriever, memory: mem, counter: HeuristicTokenCounter())
        let out = try await asm.assemble(conversationID: c, userText: "Remind me exactly what the Kestrel migration constraint was and whether it still applies?", model: model, device: device)
        XCTAssertLessThanOrEqual(out.totalTokens, out.plan.windowTokens - out.plan.replyReserve, "prompt must leave room for the reply")
        XCTAssertLessThan(out.historyMessagesIncluded, 400, "history is windowed, not all 1500 messages")
        let last = out.messages.last!.content
        XCTAssertTrue(last.contains("backwards compatible with v2 clients"), "the constraint from message 18 is retrieved into the prompt")
        XCTAssertTrue(out.citations.contains { $0.id == "E1" })
        XCTAssertTrue(out.messages.first!.content.contains("Earlier in this conversation"), "outline of scrolled-out history is present")
        XCTAssertTrue(last.hasSuffix("still applies?"), "the user's question is last")
    }

    func testScopedDecisionsAreAlwaysOn() async throws {
        let (store, retriever, mem, c, dir) = try makeLongConversation(messages: 300); defer { try? FileManager.default.removeItem(at: dir) }
        let id = try store.db.read { try $0.scalarInt("SELECT id FROM message WHERE conversation_id=? AND seq=40", [.int(c)]) }
        _ = try mem.propose(CandidateMemory(kind: .decision, epistemic: .stated, text: "Use SQLite (not Postgres) for the sync layer", scopeConversation: c,
                                            evidence: [CandidateEvidence(messageID: id, quote: "we will use SQLite, not Postgres")], createdBy: "llm:test"))
        let asm = PromptAssembler(archive: store, retriever: retriever, memory: mem, counter: HeuristicTokenCounter())
        let out = try await asm.assemble(conversationID: c, userText: "ok now write the schema", model: model, device: device)
        XCTAssertTrue(out.messages.first!.content.contains("Use SQLite (not Postgres)"), "decisions made earlier in this conversation survive window eviction")
    }

    func testPrefixStaysCacheableAcrossTurns() async throws {
        let (store, retriever, mem, c, dir) = try makeLongConversation(messages: 600); defer { try? FileManager.default.removeItem(at: dir) }
        let asm = PromptAssembler(archive: store, retriever: retriever, memory: mem, counter: HeuristicTokenCounter())
        var prev = try await asm.assemble(conversationID: c, userText: "continue the build pipeline discussion", model: model, device: device)
        var reused = 0, turns = 0, jumps = 0
        for t in 0..<20 {
            try store.appendMessages(conversationID: c, [
                NewMessage(role: .user, text: "follow up \(t) on the build pipeline caching and hashes", createdAt: 100_000 + Double(t) * 100, externalID: "u\(t)", locality: .local),
                NewMessage(role: .assistant, text: "reply \(t) with a medium length answer about artifacts and cache invalidation. " + String(repeating: "details ", count: 20), createdAt: 100_050 + Double(t) * 100, externalID: "a\(t)", locality: .local)])
            let cur = try await asm.assemble(conversationID: c, userText: "continue the build pipeline discussion \(t)", model: model, device: device)
            let common = cur.commonPrefixCount(with: prev)
            reused += common; turns += 1
            if common < prev.messages.count - 2 { jumps += 1 }
            prev = cur
        }
        print("prefix reuse: \(reused / turns) of ~\(prev.messages.count) messages per turn on average; front jumps: \(jumps)/\(turns)")
        XCTAssertLessThan(jumps, turns / 2, "front-of-history eviction must not invalidate the cache every turn")
        XCTAssertGreaterThan(reused / turns, prev.messages.count / 2)
    }

    func testTrivialTurnIsCheap() async throws {
        let (store, retriever, mem, c, dir) = try makeLongConversation(messages: 200); defer { try? FileManager.default.removeItem(at: dir) }
        let asm = PromptAssembler(archive: store, retriever: retriever, memory: mem, counter: HeuristicTokenCounter())
        let out = try await asm.assemble(conversationID: c, userText: "thanks", model: model, device: device)
        XCTAssertEqual(out.messages.last?.content, "thanks", "no evidence block for a trivial turn")
        XCTAssertLessThanOrEqual(out.plan.windowTokens, 3072)
    }
}
