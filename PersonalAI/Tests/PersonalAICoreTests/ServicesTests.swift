import XCTest
@testable import PersonalAICore

final class ServicesTests: XCTestCase {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pai-svc-\(UUID().uuidString)") }

    func testImportIndexChatExportEraseLifecycle() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try PersonalAIServices(directory: dir)
        // import through the real importer
        let export = dir.appendingPathComponent("exp"); try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try EvalSuite.chatGPTExport(EvalCorpus.standard).write(to: export.appendingPathComponent("conversations.json"))
        let r = try s.importer.importItem(at: export)
        XCTAssertGreaterThan(r.messagesInserted, 1500)
        let dup = try s.importer.importItem(at: export)
        XCTAssertEqual(dup.messagesInserted, 0, "duplicate import adds nothing")

        _ = try s.pipeline.chunkStep(conversations: 10_000)
        while try await s.pipeline.embedStep() > 0 {}
        XCTAssertEqual(try s.archive.stats().chunksPending, 0)

        let engine = ScriptedEngine { m in "ok" }
        let chat = s.makeChatController(engine: engine, profile: { ModelProfile(id: "t", maxContext: 8192, weightsBytes: 1_000_000_000, kvBytesPerToken: 20_000) }, device: { DeviceBudget(availableMemoryBytes: 4_000_000_000) })
        var it = chat.send(conversationID: nil, text: "what did the supplier quote for the oak herringbone floor").makeAsyncIterator()
        var prepared: PreparedTurn?
        while let ev = try await it.next() { if case .prepared(let p) = ev { prepared = p } }
        XCTAssertFalse(prepared?.citations.isEmpty ?? true)

        // export contains everything, including the new chat
        let ex = try ArchiveExporter.export(from: s, to: dir)
        XCTAssertEqual(ex.messages, try s.archive.stats().messages)
        let text = try String(contentsOf: ex.url.appendingPathComponent("conversations.jsonl"), encoding: .utf8)
        XCTAssertTrue(text.contains("4,200 pounds"))

        // rebuild keeps originals, drops derived
        try s.rebuildDerived()
        XCTAssertEqual(try s.archive.stats().chunks, 0)
        XCTAssertEqual(try s.archive.stats().vectors, 0)
        XCTAssertGreaterThan(try s.archive.stats().messages, 1500)
        _ = try s.pipeline.chunkStep(conversations: 10_000)
        while try await s.pipeline.embedStep() > 0 {}
        XCTAssertGreaterThan(try s.archive.stats().vectors, 0)

        try s.eraseEverything()
        let st = try s.archive.stats()
        XCTAssertEqual(st.messages, 0); XCTAssertEqual(st.conversations, 0); XCTAssertEqual(st.vectors, 0); XCTAssertEqual(st.chunks, 0)
        let hits = try s.retriever.lexical.searchMessages(terms: ["herringbone"], limit: 5)
        XCTAssertTrue(hits.isEmpty, "full-text index is empty after erase")
    }

    func testSwitchingEmbedderRequeuesChunks() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try PersonalAIServices(directory: dir)
        let src = try s.archive.upsertSource(kind: "generic", name: "t", externalID: "t")
        let (c, _) = try s.archive.upsertConversation(sourceID: src, externalID: "c", title: "t", createdAt: 1, updatedAt: 1)
        _ = try s.archive.appendMessages(conversationID: c, [NewMessage(role: .user, text: "hello there general", createdAt: 1)])
        _ = try s.pipeline.chunkStep(conversations: 10)
        while try await s.pipeline.embedStep() > 0 {}
        XCTAssertEqual(try s.vectors.count(), 1)
        try s.setEmbedder(HashingEmbedder(dim: 128))
        XCTAssertEqual(try s.vectors.count(), 0, "old-space vectors are discarded")
        XCTAssertEqual(try s.archive.stats().chunksPending, 1)
        while try await s.pipeline.embedStep() > 0 {}
        XCTAssertEqual(try s.vectors.count(), 1)
    }
}
