import XCTest
@testable import PersonalAICore

final class MemoryTests: XCTestCase {
    struct Fixture {
        let db: ArchiveDatabase, dir: URL, store: ArchiveStore, mem: MemoryStore, conv: Int64, msgs: [Int64: MessageRecord]
        let day: Double = 86400
    }

    /// conv A: Vim -> Helix (Feb 2025), conv B: Neovim (Mar 2025) and an assistant message claiming something about the user.
    func fixture() throws -> (Fixture, [String: Int64]) {
        let (db, dir) = try makeTempDB()
        let store = ArchiveStore(db: db)
        let src = try store.upsertSource(kind: "generic", name: "t", externalID: "t")
        var ids: [String: Int64] = [:]
        func add(_ convExt: String, _ ext: String, _ role: Role, _ text: String, _ t: Double) throws {
            let (c, _) = try store.upsertConversation(sourceID: src, externalID: convExt, title: convExt, createdAt: t, updatedAt: t)
            try store.appendMessages(conversationID: c, [NewMessage(role: role, text: text, createdAt: t, externalID: ext)])
            ids[ext] = try db.read { try $0.scalarInt("SELECT id FROM message WHERE external_id=? AND conversation_id=?", [.text(ext), .int(c)]) }
            ids["conv:" + convExt] = c
        }
        let feb = ts("2025-02-01T10:00:00Z"), mar = ts("2025-03-01T10:00:00Z")
        try add("A", "a1", .user, "I use Vim for everything, I really like modal editing.", feb)
        try add("A", "a2", .user, "I switched to Helix last week, it's great.", feb + 7 * 86400)
        try add("A", "a3", .assistant, "Since you prefer Emacs keybindings you might like this.", feb + 8 * 86400)
        try add("B", "b1", .user, "Update: I'm back on Neovim now, Helix was missing plugins.", mar)
        try add("B", "b2", .user, "Neovim is still my daily editor, I use it every day.", mar + 3 * 86400)
        return (Fixture(db: db, dir: dir, store: store, mem: MemoryStore(archive: store), conv: ids["conv:A"]!, msgs: [:]), ids)
    }

    func cand(_ text: String, value: String, ev: [(Int64, String)], epistemic: Epistemic = .stated, by: String = "llm:test") -> CandidateMemory {
        CandidateMemory(kind: .preference, epistemic: epistemic, attribute: "editor", text: text, value: value,
                        evidence: ev.map { CandidateEvidence(messageID: $0.0, quote: $0.1) }, createdBy: by)
    }

    func testSupersessionKeepsHistoryAndEvidence() throws {
        let (f, id) = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        let o1 = try f.mem.propose(cand("User uses Vim", value: "Vim", ev: [(id["a1"]!, "I use Vim for everything")]))
        guard case .created(let vim) = o1 else { return XCTFail("\(o1)") }
        let o2 = try f.mem.propose(cand("User switched to Helix", value: "Helix", ev: [(id["a2"]!, "I switched to Helix last week")]))
        guard case .supersededPrevious(let helix, let old) = o2 else { return XCTFail("\(o2)") }
        XCTAssertEqual(old, vim)
        let o3 = try f.mem.propose(cand("User is back on Neovim", value: "Neovim", ev: [(id["b1"]!, "I'm back on Neovim now")]))
        guard case .supersededPrevious(let nvim, let old3) = o3 else { return XCTFail("\(o3)") }
        XCTAssertEqual(old3, helix)

        let hist = try f.mem.history(attribute: "editor")
        XCTAssertEqual(hist.map(\.value), ["vim", "helix", "neovim"], "full timeline is preserved")
        XCTAssertEqual(hist.map(\.status), [.superseded, .superseded, .active])
        XCTAssertNotNil(hist[0].validTo)
        // the superseded Vim memory still points at its original evidence
        XCTAssertEqual(try f.mem.evidence(for: vim).first?.quote, "I use Vim for everything")
        let ex = try f.mem.explain(nvim)!
        XCTAssertEqual(ex.supersededChain.map(\.id), [helix, vim])
        XCTAssertEqual(ex.evidence.first?.message?.text.contains("Neovim"), true)
    }

    func testEvidenceMustBeVerbatimAndUserSpeechOnlyMakesStatedFacts() throws {
        let (f, id) = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        // fabricated quote
        XCTAssertEqual(try f.mem.propose(cand("User uses Emacs", value: "Emacs", ev: [(id["a1"]!, "I use Emacs for everything")])), .rejected("no verifiable evidence quote"))
        // claim about the user that only the assistant said => cannot be 'stated'
        let o = try f.mem.propose(cand("User prefers Emacs keybindings", value: "Emacs keybindings", ev: [(id["a3"]!, "you prefer Emacs keybindings")]))
        guard case .created(let m) = o else { return XCTFail("\(o)") }
        let rec = try f.mem.memory(m)!
        XCTAssertEqual(rec.epistemic, .inferred)
        XCTAssertLessThanOrEqual(rec.confidence, 0.65)
    }

    func testRepeatedClaimsDoNotInflateButCorroborationDoes() throws {
        let (f, id) = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        // two mentions in different conversations on different days
        guard case .created(let m) = try f.mem.propose(cand("Uses Neovim", value: "Neovim", ev: [(id["b1"]!, "back on Neovim now")])) else { return XCTFail() }
        let c1 = try f.mem.memory(m)!.confidence
        // same-day second message in the same conversation: reinforcement adds evidence but not confidence
        guard case .reinforced = try f.mem.propose(cand("Uses Neovim", value: "Neovim", ev: [(id["b2"]!, "Neovim is still my daily editor")])) else { return XCTFail() }
        let c2 = try f.mem.memory(m)!.confidence
        XCTAssertGreaterThan(c2, c1 - 1e-9)           // different day => small day bonus
        XCTAssertLessThan(c2 - c1, 0.05)
        XCTAssertEqual(try f.mem.evidence(for: m).count, 2)
        // a memory with evidence from another conversation gets the larger corroboration bonus
        guard case .reinforced = try f.mem.propose(cand("Uses Neovim", value: "Neovim", ev: [(id["a2"]!, "it's great")])) else { return XCTFail() }
    }

    func testLateArrivingOlderStatementBecomesHistoryNotCurrent() throws {
        let (f, id) = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        _ = try f.mem.propose(cand("Uses Neovim", value: "Neovim", ev: [(id["b1"]!, "back on Neovim now")]))
        let o = try f.mem.propose(cand("Used Vim", value: "Vim", ev: [(id["a1"]!, "I use Vim for everything")]))
        guard case .recordedAsHistory(let h) = o else { return XCTFail("\(o)") }
        XCTAssertEqual(try f.mem.memory(h)?.status, .superseded)
        XCTAssertEqual(try f.mem.list(statuses: [.active]).first?.value, "neovim")
    }

    func testWeakInferenceCannotOverturnStatedFact() throws {
        let (f, id) = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        _ = try f.mem.propose(cand("Uses Vim", value: "Vim", ev: [(id["a1"]!, "I use Vim for everything")]))
        let o = try f.mem.propose(cand("Maybe uses Emacs", value: "Emacs", ev: [(id["a3"]!, "you prefer Emacs keybindings")], epistemic: .inferred))
        guard case .disputed(_, let existing) = o else { return XCTFail("\(o)") }
        XCTAssertEqual(try f.mem.memory(existing)?.status, .active, "the stated fact stays current")
    }

    func testUserCorrectionRejectionAndDeletionLeaveOriginalsIntact() throws {
        let (f, id) = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        guard case .created(let m) = try f.mem.propose(cand("Uses Vim", value: "Vim", ev: [(id["a1"]!, "I use Vim for everything")])) else { return XCTFail() }
        let fixed = try f.mem.correct(m, newText: "Uses Vim only for quick edits", newValue: "vim for quick edits")
        XCTAssertEqual(try f.mem.memory(m)?.status, .superseded)
        XCTAssertEqual(try f.mem.memory(fixed)?.confidence ?? 0, 0.99, accuracy: 0.001)
        XCTAssertEqual(try f.mem.memory(fixed)?.createdBy, "user")

        guard case .disputed(let w, _) = try f.mem.propose(cand("Uses Emacs", value: "Emacs", ev: [(id["a3"]!, "you prefer Emacs keybindings")], epistemic: .inferred)) else { return XCTFail("weak inference should be held as disputed, not become fact") }
        try f.mem.reject(w)
        // the extractor must not resurrect a claim the user rejected
        XCTAssertEqual(try f.mem.propose(cand("Uses Emacs", value: "Emacs", ev: [(id["a3"]!, "you prefer Emacs keybindings")], epistemic: .inferred)), .rejected("previously rejected by the user"))

        try f.mem.delete(fixed)
        XCTAssertNil(try f.mem.memory(fixed))
        XCTAssertNotNil(try f.store.message(id["a1"]!), "deleting a derived memory never deletes its source message")
    }

    func testErasingSourceRemovesOrWeakensDependentMemories() throws {
        let (f, id) = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        guard case .created(let only) = try f.mem.propose(cand("Uses Vim", value: "Vim", ev: [(id["a1"]!, "I use Vim for everything")])) else { return XCTFail() }
        guard case .supersededPrevious(let multi, _) = try f.mem.propose(cand("Uses Helix", value: "Helix", ev: [(id["a2"]!, "I switched to Helix last week")])) else { return XCTFail() }
        _ = try f.mem.propose(cand("Uses Helix", value: "Helix", ev: [(id["b1"]!, "Helix was missing plugins")]))
        let impact = try f.store.eraseConversation(id["conv:A"]!)
        XCTAssertGreaterThan(impact.memoriesRemoved + impact.memoriesWeakened, 0)
        XCTAssertNil(try f.mem.memory(only), "memory whose only evidence was erased is removed")
        XCTAssertNotNil(try f.mem.memory(multi), "memory with evidence in another conversation survives, weakened")
    }

    func testEntityAmbiguityIsNeverGuessed() throws {
        let (db, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let ents = EntityStore(db: db)
        let coworker = try ents.create(kind: "person", name: "Alex", description: "coworker", aliases: ["alex"])
        let brother = try ents.create(kind: "person", name: "Alex", description: "brother", aliases: ["alex", "my brother"])
        XCTAssertEqual(try ents.resolve(name: "Alex"), .ambiguous([coworker, brother]))
        XCTAssertEqual(try ents.resolve(name: "my brother"), .found(brother))
        // an earlier mention in this conversation disambiguates
        let store = ArchiveStore(db: db)
        let s = try store.upsertSource(kind: "generic", name: "t", externalID: "t")
        let (c, _) = try store.upsertConversation(sourceID: s, externalID: "c", title: "t", createdAt: 1, updatedAt: 1)
        try store.appendMessages(conversationID: c, [NewMessage(role: .user, text: "Alex from work called", createdAt: 1, externalID: "x")])
        let mid = try db.read { try $0.scalarInt("SELECT id FROM message") }
        try ents.recordMention(entity: coworker, messageID: mid, conversationID: c, at: 1)
        XCTAssertEqual(try ents.resolve(name: "Alex", conversationID: c), .found(coworker))
        XCTAssertEqual(try ents.findMentions(in: "what did my brother say"), [brother])
        XCTAssertEqual(try ents.findMentions(in: "what did Alex say"), [], "ambiguous alias is not linked")
    }
}
