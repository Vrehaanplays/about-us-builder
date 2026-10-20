import XCTest
@testable import PersonalAICore

final class ImportTests: XCTestCase {
    func testStreamerHandlesTrickyStrings() throws {
        let json = #"[ {"a":"x]}, \"quoted\" [brace"}, [1,2,{"b":[3]}], "plain, string", 42, {"c":{}} ]"#
        var got: [String] = []
        try JSONArrayStreamer.forEachElement(in: Data(json.utf8)) { got.append(String(decoding: $0, as: UTF8.self)); return true }
        XCTAssertEqual(got.count, 5)
        XCTAssertEqual(got[0], #"{"a":"x]}, \"quoted\" [brace"}"#)
        XCTAssertEqual(got[2], "\"plain, string\"")
        XCTAssertEqual(got[4], #"{"c":{}}"#)
    }

    func chatGPTFixture() -> String {
        // root -> sys(hidden) -> u1 -> a1 -> u2 -> a2(current)   and an alternate regeneration a1' under u1
        #"""
        [{"id":"conv-1","title":"Garden planning","create_time":1700000000,"update_time":1700000500,"current_node":"a2",
          "mapping":{
            "root":{"id":"root","parent":null,"children":["sys"],"message":null},
            "sys":{"id":"sys","parent":"root","children":["u1"],"message":{"id":"sys","author":{"role":"system"},"create_time":1700000000,"content":{"content_type":"text","parts":["hidden"]},"metadata":{"is_visually_hidden_from_conversation":true}}},
            "u1":{"id":"u1","parent":"sys","children":["a1","a1b"],"message":{"id":"u1","author":{"role":"user"},"create_time":1700000010,"content":{"content_type":"text","parts":["Which tomatoes grow best in shade?"]},"metadata":{}}},
            "a1":{"id":"a1","parent":"u1","children":["u2"],"message":{"id":"a1","author":{"role":"assistant"},"create_time":1700000020,"content":{"content_type":"text","parts":["Try Black Krim or Cherokee Purple."]},"metadata":{"model_slug":"gpt-4o"}}},
            "a1b":{"id":"a1b","parent":"u1","children":[],"message":{"id":"a1b","author":{"role":"assistant"},"create_time":1700000025,"content":{"content_type":"text","parts":["Alternate answer about tomatoes."]},"metadata":{}}},
            "u2":{"id":"u2","parent":"a1","children":["a2"],"message":{"id":"u2","author":{"role":"user"},"create_time":1700000100,"content":{"content_type":"multimodal_text","parts":[{"content_type":"image_asset_pointer","asset_pointer":"file-service://file-AbC123"},"Here is my balcony"]},"metadata":{"attachments":[{"id":"file-AbC123","name":"balcony.png","mime_type":"image/png","size":1234}]}}},
            "a2":{"id":"a2","parent":"u2","children":[],"message":{"id":"a2","author":{"role":"assistant"},"create_time":1700000110,"content":{"content_type":"text","parts":["Nice balcony, it gets about four hours of sun."]},"metadata":{}}}
          }}]
        """#
    }

    func testChatGPTImportLinearisesBranchesAndAttachments() throws {
        let (db, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let export = dir.appendingPathComponent("export"); try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try chatGPTFixture().write(to: export.appendingPathComponent("conversations.json"), atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: export.appendingPathComponent("file-AbC123-balcony.png"))
        let store = ArchiveStore(db: db)
        let coordinator = ImportCoordinator(store: store)
        let r = try coordinator.importItem(at: export)
        XCTAssertEqual(r.conversationsSeen, 1)
        XCTAssertEqual(r.conversationsNew, 2, "main thread + one alternate branch")
        XCTAssertEqual(r.messagesInserted, 5, "4 visible main-thread messages + 1 divergent branch message; hidden system message skipped")

        let main = try store.conversations().first { $0.externalID == "conv-1" }!
        let msgs = try store.tail(conversationID: main.id, limit: 10)
        XCTAssertEqual(msgs.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(msgs[0].text, "Which tomatoes grow best in shade?")
        XCTAssertEqual(msgs[1].model, "gpt-4o")
        XCTAssertEqual(msgs[2].text, "Here is my balcony")

        // attachment found in the export folder and linked to the message that carried it
        let linked = try coordinator.assets.assets(linkedTo: [msgs[2].id])
        XCTAssertFalse(linked.isEmpty)
        XCTAssertTrue(linked.contains { $0.status == "indexed" && $0.kind == "image" })

        // re-import is a no-op
        let again = try coordinator.importItem(at: export)
        XCTAssertEqual(again.messagesInserted, 0)
        XCTAssertEqual(again.messagesDuplicate, 5)
    }

    func testClaudeImportAndIncrementalUpdate() throws {
        let (db, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        func export(_ extra: Bool) -> String {
            var msgs = #"""
            {"uuid":"m1","sender":"human","text":"hi","content":[{"type":"text","text":"I switched from Vim to Helix last week"}],"created_at":"2025-02-01T10:00:00.123456Z","attachments":[{"file_name":"notes.txt","file_type":"text/plain","file_size":10,"extracted_content":"remember the milk"}]},
            {"uuid":"m2","sender":"assistant","text":"Helix is great.","created_at":"2025-02-01T10:00:05.000Z"}
            """#
            if extra { msgs += #",{"uuid":"m3","sender":"human","text":"Update: I went back to Neovim","created_at":"2025-03-01T09:00:00Z"}"# }
            return #"[{"uuid":"c1","name":"Editor talk","created_at":"2025-02-01T10:00:00Z","updated_at":"2025-03-01T09:00:00Z","chat_messages":[\#(msgs)]}]"#
        }
        let f = dir.appendingPathComponent("conversations.json")
        try export(false).write(to: f, atomically: true, encoding: .utf8)
        let store = ArchiveStore(db: db); let c = ImportCoordinator(store: store)
        var r = try c.importItem(at: f)
        XCTAssertEqual(r.messagesInserted, 2)
        try export(true).write(to: f, atomically: true, encoding: .utf8)
        r = try c.importItem(at: f)
        XCTAssertEqual(r.messagesInserted, 1, "incremental update adds only the new message")
        XCTAssertEqual(r.messagesDuplicate, 2)
        let conv = try store.conversations().first!
        XCTAssertEqual(conv.messageCount, 3)
        let doc = try db.read { try $0.queryOne("SELECT text FROM asset WHERE kind='document'") { $0.text(0) } }
        XCTAssertEqual(doc, "remember the milk")
        XCTAssertNotNil(ISODate.parse("2025-02-01T10:00:00.123456Z"))
    }
}
