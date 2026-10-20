import Foundation

/// Derived, evidence-backed memory. Invariants enforced here (not in the extractor, so they hold for any producer):
///  * Every non-user memory has ≥1 supporting quote that is a verbatim substring of an archived message.
///  * `stated` requires a quote from a *user* message; assistant text can never make something a stated user fact.
///  * Repeating a claim inside one conversation/day does not raise confidence; independent corroboration does.
///  * New information about a single-valued attribute supersedes the old value but never deletes it.
public final class MemoryStore: @unchecked Sendable {
    let db: ArchiveDatabase
    let archive: ArchiveStore
    public init(archive: ArchiveStore) { self.archive = archive; self.db = archive.db }

    // MARK: confidence

    public struct Policy: Sendable {
        public var base: [Epistemic: Double] = [.stated: 0.80, .observed: 0.60, .inferred: 0.35]
        public var cap: [Epistemic: Double] = [.stated: 0.97, .observed: 0.88, .inferred: 0.65]
        public var perExtraConversation = 0.05, conversationBonusCap = 0.15
        public var perExtraDay = 0.03, dayBonusCap = 0.06
        public var contradictionFactor = 0.85
        public init() {}
    }
    public var policy = Policy()

    static func normalizeForQuote(_ s: String) -> String {
        TextNorm.collapse(s).lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    static func normalizeValue(_ s: String?) -> String { TextNorm.words(s ?? "").joined(separator: " ") }

    private func recomputeConfidence(_ w: SQLiteDatabase, memoryID: Int64) throws {
        guard let (epi, user): (Epistemic, String) = try w.queryOne("SELECT epistemic, user_state FROM memory WHERE id=?", [.int(memoryID)], { (Epistemic(rawValue: $0.text(0)) ?? .inferred, $0.text(1)) }) else { return }
        if user == "confirmed" || user == "corrected" { try w.run("UPDATE memory SET confidence=0.99, updated_at=? WHERE id=?", [.double(Clock.now()), .int(memoryID)]); return }
        let rows = try w.query("""
            SELECT e.role, m.conversation_id, CAST(m.created_at / 86400 AS INTEGER) FROM memory_evidence e JOIN message m ON m.id = e.message_id WHERE e.memory_id=?
            """, [.int(memoryID)]) { ($0.text(0), $0.int(1), $0.int(2)) }
        let supports = rows.filter { $0.0 != "contradicts" }
        let contradicts = rows.filter { $0.0 == "contradicts" }.count
        let convs = Set(supports.map { $0.1 }).count, days = Set(supports.map { $0.2 }).count
        var c = policy.base[epi]!
        c += min(policy.conversationBonusCap, Double(max(0, convs - 1)) * policy.perExtraConversation)
        c += min(policy.dayBonusCap, Double(max(0, days - 1)) * policy.perExtraDay)
        c *= pow(policy.contradictionFactor, Double(contradicts))
        c = min(c, policy.cap[epi]!)
        try w.run("UPDATE memory SET confidence=?, updated_at=? WHERE id=?", [.double(c), .double(Clock.now()), .int(memoryID)])
    }

    /// Confidence as of `now`: state-like facts age. The stored confidence is evidence strength; this is how much we'd bet it's still true.
    public func effectiveConfidence(_ m: MemoryRecord, now: Double = Clock.now()) -> Double {
        let ageYears = max(0, now - (m.validFrom ?? m.createdAt)) / (365.25 * 86400)
        let halfLife: Double
        switch m.kind {
        case .preference, .observation, .hypothesis: halfLife = 2
        case .goal, .commitment, .openThread: halfLife = 0.75
        case .constraint, .decision: halfLife = 3
        case .fact: halfLife = 6
        case .event: halfLife = .infinity
        }
        if m.userState == .confirmed || m.userState == .corrected { return max(m.confidence * pow(0.5, ageYears / (halfLife * 2)), 0.5) }
        return m.confidence * pow(0.5, ageYears / halfLife)
    }

    // MARK: propose + reconcile

    @discardableResult
    public func propose(_ c: CandidateMemory) throws -> ProposalOutcome {
        // 1. verify evidence against the archive
        var verified: [(msg: MessageRecord, quote: String, contradicts: Bool)] = []
        let msgs = try archive.messages(ids: c.evidence.map(\.messageID))
        for ev in c.evidence {
            guard let m = msgs[ev.messageID] else { continue }
            let q = Self.normalizeForQuote(ev.quote)
            guard q.count >= 4 || Self.normalizeForQuote(m.text) == q, Self.normalizeForQuote(m.text).contains(q) else { continue }
            verified.append((m, ev.quote, ev.contradicts))
        }
        let supporting = verified.filter { !$0.contradicts }
        if c.createdBy != "user" && supporting.isEmpty { return .rejected("no verifiable evidence quote") }
        if c.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 { return .rejected("empty memory") }

        // 2. epistemic honesty
        var epistemic = c.epistemic
        if epistemic == .stated, !supporting.contains(where: { $0.msg.role == .user }) {
            epistemic = supporting.isEmpty ? .inferred : .inferred   // assistant text can't establish a user's own statement
        }
        if epistemic != .stated, c.kind == .hypothesis { epistemic = .inferred }

        let times = supporting.map(\.msg.createdAt)
        let firstEvidence = times.min() ?? Clock.now(), lastEvidence = times.max() ?? Clock.now()
        let validFrom = c.validFrom ?? firstEvidence

        // 3. respect past rejections: the user said this is wrong, don't resurrect it
        if let attr = c.attribute, let v = c.value {
            let rejected = try db.read { try $0.scalarInt("SELECT COUNT(*) FROM memory WHERE user_state='rejected' AND attribute=? AND IFNULL(subject,0)=? AND value=?",
                                                          [.text(attr), .int(c.subject ?? 0), .text(Self.normalizeValue(v))]) }
            if rejected > 0 { return .rejected("previously rejected by the user") }
        }

        return try db.write { w in
            try w.transaction {
                // 4. reconcile against what we already believe
                var existing: [MemoryRecord] = []
                if let attr = c.attribute {
                    existing = try w.query("SELECT \(MemoryRecord.columns) FROM memory WHERE attribute=? AND IFNULL(subject,0)=? AND status IN ('active','disputed') AND IFNULL(scope_conversation,0)=?",
                                           [.text(attr), .int(c.subject ?? 0), .int(c.scopeConversation ?? 0)], MemoryRecord.init(row:))
                } else {
                    existing = try w.query("SELECT \(MemoryRecord.columns) FROM memory WHERE kind=? AND IFNULL(subject,0)=? AND status IN ('active','disputed') AND IFNULL(scope_conversation,0)=? ORDER BY updated_at DESC LIMIT 200",
                                           [.text(c.kind.rawValue), .int(c.subject ?? 0), .int(c.scopeConversation ?? 0)], MemoryRecord.init(row:))
                }
                let newValueKey = Self.normalizeValue(c.value ?? c.text)
                let same = existing.first { e in
                    let ev = Self.normalizeValue(e.value ?? e.text)
                    return ev == newValueKey || TextNorm.jaccard(ev, newValueKey) >= (c.attribute != nil ? 0.8 : 0.85)
                }

                if let s = same {
                    var added = 0
                    for e in verified {
                        added += try w.run("INSERT OR IGNORE INTO memory_evidence(memory_id,message_id,role,speaker,quote,created_at) VALUES(?,?,?,?,?,?)",
                                           [.int(s.id), .int(e.msg.id), .text(e.contradicts ? "contradicts" : "supports"), .text(e.msg.role.rawValue), .text(e.quote), .double(Clock.now())])
                    }
                    if epistemic > s.epistemic { try w.run("UPDATE memory SET epistemic=? WHERE id=?", [.text(epistemic.rawValue), .int(s.id)]) }
                    try recomputeConfidence(w, memoryID: s.id)
                    if added > 0 { try event(w, s.id, "reinforced", c.createdBy, "+\(added) evidence") }
                    return .reinforced(s.id)
                }

                // a different value for the same attribute
                var supersededID: Int64?
                var status: MemoryStatus = .active
                var disputedWith: Int64?
                var validTo: Double?
                if c.cardinality == .single, let old = existing.first(where: { $0.cardinality == .single }) {
                    let oldLatest: Double = (try w.queryOne("SELECT MAX(m.created_at) FROM memory_evidence e JOIN message m ON m.id=e.message_id WHERE e.memory_id=? AND e.role!='contradicts'", [.int(old.id)]) { $0.optDouble(0) }).flatMap { $0 } ?? old.createdAt
                    let oldFrom = old.validFrom ?? old.createdAt
                    if lastEvidence < oldFrom, c.createdBy != "user" {
                        // an older statement arriving late (e.g. importing a past export): fill the timeline, don't override the present
                        status = .superseded; validTo = oldFrom
                    } else if epistemic < old.epistemic, c.createdBy != "user" {
                        // weaker evidence never overturns stronger evidence, however recent: keep both visible for review
                        status = .disputed; disputedWith = old.id
                    } else if firstEvidence > oldLatest || c.createdBy == "user" {
                        supersededID = old.id
                    } else {
                        status = .disputed; disputedWith = old.id
                        try w.run("UPDATE memory SET status='disputed', updated_at=? WHERE id=?", [.double(Clock.now()), .int(old.id)])
                        try event(w, old.id, "disputed", c.createdBy, "conflicting claim at the same time")
                    }
                }

                try w.run("""
                    INSERT INTO memory(kind,epistemic,attribute,cardinality,subject,text,value,confidence,status,valid_from,valid_to,scope_conversation,standing,user_state,supersedes,created_by,created_at,updated_at)
                    VALUES(?,?,?,?,?,?,?,0.5,?,?,?,?,?,'none',?,?,?,?)
                    """, [.text(c.kind.rawValue), .text(epistemic.rawValue), .opt(c.attribute), .text(c.cardinality.rawValue), .opt(c.subject), .text(c.text),
                          .opt(c.value.map { Self.normalizeValue($0) }), .text(status.rawValue), .double(validFrom), .opt(validTo), .opt(c.scopeConversation),
                          .bool(c.standing), .opt(supersededID), .text(c.createdBy), .double(Clock.now()), .double(Clock.now())])
                let id = w.lastInsertRowID
                for e in verified {
                    try w.run("INSERT OR IGNORE INTO memory_evidence(memory_id,message_id,role,speaker,quote,created_at) VALUES(?,?,?,?,?,?)",
                              [.int(id), .int(e.msg.id), .text(e.contradicts ? "contradicts" : "supports"), .text(e.msg.role.rawValue), .text(e.quote), .double(Clock.now())])
                }
                try recomputeConfidence(w, memoryID: id)
                try event(w, id, "created", c.createdBy, nil)
                if let old = supersededID {
                    try w.run("UPDATE memory SET status='superseded', valid_to=?, updated_at=? WHERE id=?", [.double(validFrom), .double(Clock.now()), .int(old)])
                    try event(w, old, "superseded", c.createdBy, "by #\(id)")
                    return .supersededPrevious(new: id, old: old)
                }
                if let other = disputedWith { return .disputed(new: id, existing: other) }
                if status == .superseded { return .recordedAsHistory(id) }
                return .created(id)
            }
        }
    }

    private func event(_ w: SQLiteDatabase, _ id: Int64, _ action: String, _ actor: String, _ detail: String?) throws {
        try w.run("INSERT INTO memory_event(memory_id,at,action,actor,detail) VALUES(?,?,?,?,?)", [.int(id), .double(Clock.now()), .text(action), .text(actor), .opt(detail)])
    }

    // MARK: user control: confirm / correct / reject / delete (none of these touch archived messages)

    public func confirm(_ id: Int64) throws {
        try db.write { w in try w.transaction {
            try w.run("UPDATE memory SET user_state='confirmed', epistemic='stated', status='active' WHERE id=?", [.int(id)])
            try recomputeConfidence(w, memoryID: id); try event(w, id, "confirmed", "user", nil) } }
    }

    /// The old claim stays in history (superseded, user_state=corrected); the corrected statement is user-authored.
    @discardableResult
    public func correct(_ id: Int64, newText: String, newValue: String? = nil) throws -> Int64 {
        try db.write { w in try w.transaction {
            guard let old = try w.queryOne("SELECT \(MemoryRecord.columns) FROM memory WHERE id=?", [.int(id)], MemoryRecord.init(row:)) else { throw SQLiteError.misuse("memory \(id) not found") }
            let now = Clock.now()
            try w.run("UPDATE memory SET status='superseded', valid_to=?, user_state='corrected', updated_at=? WHERE id=?", [.double(now), .double(now), .int(id)])
            try w.run("""
                INSERT INTO memory(kind,epistemic,attribute,cardinality,subject,text,value,confidence,status,valid_from,scope_conversation,standing,user_state,supersedes,created_by,created_at,updated_at)
                VALUES(?,?,?,?,?,?,?,0.99,'active',?,?,?,'corrected',?,'user',?,?)
                """, [.text(old.kind.rawValue), .text("stated"), .opt(old.attribute), .text(old.cardinality.rawValue), .opt(old.subject), .text(newText),
                      .opt(newValue.map { Self.normalizeValue($0) }), .opt(old.validFrom ?? now), .opt(old.scopeConversation), .bool(old.standing), .int(id), .double(now), .double(now)])
            let nid = w.lastInsertRowID
            try event(w, id, "corrected", "user", "replaced by #\(nid)"); try event(w, nid, "created", "user", "correction of #\(id)")
            return nid } }
    }

    /// Rejected memories stay as tombstones so the extractor does not re-learn the same wrong claim from the same chats.
    public func reject(_ id: Int64) throws {
        try db.write { w in try w.transaction {
            try w.run("UPDATE memory SET status='retracted', user_state='rejected', updated_at=? WHERE id=?", [.double(Clock.now()), .int(id)])
            try event(w, id, "rejected", "user", nil) } }
    }

    /// Hard-deletes a derived memory and its evidence links. The original messages are not affected.
    public func delete(_ id: Int64) throws {
        try db.write { w in try w.transaction {
            try w.run("UPDATE memory SET supersedes=NULL WHERE supersedes=?", [.int(id)])
            try w.run("DELETE FROM memory WHERE id=?", [.int(id)]); try event(w, id, "deleted", "user", "derived memory deleted; source messages kept") } }
    }

    public func deleteAllDerived() throws {
        try db.write { w in try w.transaction {
            try w.run("UPDATE memory SET supersedes=NULL"); try w.run("DELETE FROM memory"); try w.run("DELETE FROM summary"); try w.run("DELETE FROM entity_mention"); try w.run("DELETE FROM relation")
            try w.run("DELETE FROM entity_alias"); try w.run("DELETE FROM entity") } }
    }

    // MARK: reads

    public func memory(_ id: Int64) throws -> MemoryRecord? {
        try db.read { try $0.queryOne("SELECT \(MemoryRecord.columns) FROM memory WHERE id=?", [.int(id)], MemoryRecord.init(row:)) }
    }

    public func list(statuses: [MemoryStatus] = [.active, .disputed], kinds: [MemoryKind]? = nil, limit: Int = 200, offset: Int = 0) throws -> [MemoryRecord] {
        let sm = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let km = kinds.map { " AND kind IN (\($0.map { "'\($0.rawValue)'" }.joined(separator: ",")))" } ?? ""
        return try db.read { try $0.query("SELECT \(MemoryRecord.columns) FROM memory WHERE status IN (\(sm))\(km) ORDER BY updated_at DESC LIMIT ? OFFSET ?", [.int(limit), .int(offset)], MemoryRecord.init(row:)) }
    }

    public func evidence(for id: Int64) throws -> [EvidenceLink] {
        try db.read { try $0.query("SELECT memory_id, message_id, role, speaker, quote FROM memory_evidence WHERE memory_id=? ORDER BY message_id", [.int(id)]) {
            EvidenceLink(memoryID: $0.int(0), messageID: $0.int(1), role: $0.text(2), speaker: $0.text(3), quote: $0.text(4)) } }
    }

    public func explain(_ id: Int64) throws -> MemoryExplanation? {
        guard let m = try memory(id) else { return nil }
        let links = try evidence(for: id)
        let msgs = try archive.messages(ids: links.map(\.messageID))
        let events = try db.read { try $0.query("SELECT memory_id, at, action, actor, detail FROM memory_event WHERE memory_id=? ORDER BY at, id", [.int(id)]) {
            MemoryEventRecord(memoryID: $0.int(0), at: $0.double(1), action: $0.text(2), actor: $0.text(3), detail: $0.optText(4)) } }
        var chain: [MemoryRecord] = []
        var cur = m.supersedes
        while let p = cur, chain.count < 20, let prev = try memory(p) { chain.append(prev); cur = prev.supersedes }
        return MemoryExplanation(memory: m, evidence: links.map { ($0, msgs[$0.messageID]) }, events: events, supersededChain: chain)
    }

    /// Everything we have ever believed about one attribute, oldest first: powers "what changed between my earlier and later views".
    public func history(attribute: String, subject: Int64? = nil) throws -> [MemoryRecord] {
        try db.read { try $0.query("SELECT \(MemoryRecord.columns) FROM memory WHERE attribute=? AND IFNULL(subject,0)=? AND user_state!='rejected' ORDER BY COALESCE(valid_from, created_at)",
                                   [.text(attribute), .int(subject ?? 0)], MemoryRecord.init(row:)) }
    }

    public func standing(limit: Int = 12) throws -> [MemoryRecord] {
        try db.read { try $0.query("SELECT \(MemoryRecord.columns) FROM memory WHERE standing=1 AND status='active' ORDER BY confidence DESC LIMIT ?", [.int(limit)], MemoryRecord.init(row:)) }
    }

    public func scoped(toConversation id: Int64, limit: Int = 30) throws -> [MemoryRecord] {
        try db.read { try $0.query("SELECT \(MemoryRecord.columns) FROM memory WHERE scope_conversation=? AND status IN ('active','disputed') ORDER BY updated_at DESC LIMIT ?", [.int(id), .int(limit)], MemoryRecord.init(row:)) }
    }

    public func about(entities: [Int64], limit: Int = 20) throws -> [MemoryRecord] {
        guard !entities.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: entities.count).joined(separator: ",")
        return try db.read { try $0.query("SELECT \(MemoryRecord.columns) FROM memory WHERE subject IN (\(marks)) AND status IN ('active','disputed') ORDER BY confidence DESC LIMIT ?",
                                          entities.map { .int($0) } + [.int(limit)], MemoryRecord.init(row:)) }
    }

    /// Lexical search over memory text. Returns (memory, bm25-ish rank score where higher is better).
    public func search(terms: [String], limit: Int = 20, statuses: [MemoryStatus] = [.active, .disputed]) throws -> [(MemoryRecord, Double)] {
        let q = terms.filter { !$0.isEmpty }.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " OR ")
        guard !q.isEmpty else { return [] }
        let sm = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
        return try db.read { try $0.query("""
            SELECT \(MemoryRecord.columns.split(separator: ",").map { "m." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")), bm25(memory_fts)
            FROM memory_fts JOIN memory m ON m.id = memory_fts.rowid WHERE memory_fts MATCH ? AND m.status IN (\(sm)) ORDER BY bm25(memory_fts) LIMIT ?
            """, [.text(q), .int(limit)]) { (MemoryRecord(row: $0), -$0.double(19)) } }
    }
}
