import XCTest
@testable import PersonalAICore

final class ArchiveTests: XCTestCase {
    func testAppendDedupeAndImmutability() throws {
        let (db, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveStore(db: db)
        let src = try store.upsertSource(kind: "generic", name: "t", externalID: "t1")
        let (cid, isNew) = try store.upsertConversation(sourceID: src, externalID: "c1", title: "Trip to Lisbon", createdAt: 1000, updatedAt: 1000)
        XCTAssertTrue(isNew)
        let msgs = [
            NewMessage(role: .user, text: "I'm planning a trip to Lisbon in March", createdAt: 1000, externalID: "m1"),
            NewMessage(role: .assistant, text: "Great! Lisbon in March is mild.", createdAt: 1001, externalID: "m2"),
            NewMessage(role: .user, text: "ok", createdAt: 1002),
            NewMessage(role: .user, text: "ok", createdAt: 1003),   // same text, different time => distinct
        ]
        let r1 = try store.appendMessages(conversationID: cid, msgs)
        XCTAssertEqual(r1.inserted, 4)
        let r2 = try store.appendMessages(conversationID: cid, msgs)   // idempotent re-import
        XCTAssertEqual(r2.inserted, 0); XCTAssertEqual(r2.duplicates, 4)
        XCTAssertEqual(try store.messageCount(conversationID: cid), 4)

        // originals cannot be rewritten
        XCTAssertThrowsError(try db.write { try $0.run("UPDATE message SET text='tampered' WHERE seq=0") })
        XCTAssertEqual(try store.tail(conversationID: cid, limit: 10).first?.text, "I'm planning a trip to Lisbon in March")
    }

    func testFTSAndPhraseSearchAndErase() throws {
        let (db, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveStore(db: db)
        let src = try store.upsertSource(kind: "generic", name: "t", externalID: "t1")
        let (cid, _) = try store.upsertConversation(sourceID: src, externalID: "c1", title: "x", createdAt: 1, updatedAt: 1)
        try store.appendMessages(conversationID: cid, [
            NewMessage(role: .user, text: "My favourite editor is Neovim", createdAt: 10, externalID: "a"),
            NewMessage(role: .user, text: "Something else entirely", createdAt: 11, externalID: "b"),
        ])
        let hits = try db.read { try $0.query("SELECT rowid FROM message_fts WHERE message_fts MATCH ?", [.text("\"favourite editor\"")]) { $0.int(0) } }
        XCTAssertEqual(hits.count, 1)
        let impact = try store.eraseConversation(cid)
        XCTAssertEqual(impact.messages, 2)
        let after = try db.read { try $0.query("SELECT rowid FROM message_fts WHERE message_fts MATCH ?", [.text("neovim")]) { $0.int(0) } }
        XCTAssertTrue(after.isEmpty, "erasing originals must also remove them from the search index")
    }
}
