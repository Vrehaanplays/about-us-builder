import Foundation

/// The system of record. Messages are append-only; derived data never replaces them.
public final class ArchiveStore: @unchecked Sendable {
    public let db: ArchiveDatabase
    public init(db: ArchiveDatabase) { self.db = db }

    // MARK: sources / conversations

    @discardableResult
    public func upsertSource(kind: String, name: String, externalID: String?, fingerprint: String? = nil, meta: String? = nil) throws -> Int64 {
        try db.write { w in
            if let ext = externalID,
               let id = try w.queryOne("SELECT id FROM source WHERE kind=? AND external_id=?", [.text(kind), .text(ext)], { $0.int(0) }) {
                if let fp = fingerprint { try w.run("UPDATE source SET fingerprint=?, name=? WHERE id=?", [.text(fp), .text(name), .int(id)]) }
                return id
            }
            try w.run("INSERT INTO source(kind,name,external_id,imported_at,fingerprint,meta) VALUES(?,?,?,?,?,?)",
                      [.text(kind), .text(name), .opt(externalID), .double(Clock.now()), .opt(fingerprint), .opt(meta)])
            return w.lastInsertRowID
        }
    }

    public func upsertConversation(sourceID: Int64, externalID: String?, title: String?, createdAt: Double?, updatedAt: Double?,
                                   origin: String = "imported", meta: String? = nil) throws -> (id: Int64, isNew: Bool) {
        try db.write { w in
            if let ext = externalID,
               let id = try w.queryOne("SELECT id FROM conversation WHERE source_id=? AND external_id=?", [.int(sourceID), .text(ext)], { $0.int(0) }) {
                // Titles/updated_at are mutable metadata; message bodies are not.
                try w.run("UPDATE conversation SET updated_at=MAX(COALESCE(updated_at,0), ?) WHERE id=?", [.opt(updatedAt), .int(id)])
                return (id, false)
            }
            try w.run("INSERT INTO conversation(source_id,external_id,title,created_at,updated_at,origin,meta) VALUES(?,?,?,?,?,?,?)",
                      [.int(sourceID), .opt(externalID), .opt(title), .opt(createdAt), .opt(updatedAt), .text(origin), .opt(meta)])
            return (w.lastInsertRowID, true)
        }
    }

    public func conversation(_ id: Int64) throws -> ConversationRecord? {
        try db.read { try $0.queryOne("SELECT \(ConversationRecord.columns) FROM conversation WHERE id=?", [.int(id)], ConversationRecord.init(row:)) }
    }

    public func conversations(limit: Int = 200, offset: Int = 0) throws -> [ConversationRecord] {
        try db.read { try $0.query("SELECT \(ConversationRecord.columns) FROM conversation ORDER BY COALESCE(updated_at, created_at, 0) DESC LIMIT ? OFFSET ?",
                                   [.int(limit), .int(offset)], ConversationRecord.init(row:)) }
    }

    public func renameConversation(_ id: Int64, to title: String) throws {
        try db.write { w in
            // title lives in an external-content FTS table: delete old entry, update, insert new
            try w.transaction {
                if let old = try w.queryOne("SELECT COALESCE(title,'') FROM conversation WHERE id=?", [.int(id)], { $0.text(0) }) {
                    try w.run("INSERT INTO conversation_fts(conversation_fts, rowid, title) VALUES('delete', ?, ?)", [.int(id), .text(old)])
                    try w.run("UPDATE conversation SET title=? WHERE id=?", [.text(title), .int(id)])
                    try w.run("INSERT INTO conversation_fts(rowid, title) VALUES(?, ?)", [.int(id), .text(title)])
                }
            }
        }
    }

    // MARK: messages

    /// Appends messages after the conversation's current tail. Idempotent: re-importing the same export inserts nothing.
    /// Dedupe key = `external_id` when present; otherwise (role, timestamp, text hash). Identical text sent at different
    /// times is preserved as distinct messages.
    @discardableResult
    public func appendMessages(conversationID: Int64, _ messages: [NewMessage]) throws -> AppendResult {
        guard !messages.isEmpty else { return AppendResult(inserted: 0, duplicates: 0) }
        return try db.write { w in
            try w.transaction {
                var seq = Int(try w.scalarInt("SELECT COALESCE(MAX(seq), -1) FROM message WHERE conversation_id=?", [.int(conversationID)]))
                var inserted = 0, dup = 0
                var first: Int64?, last: Int64?
                var newest = 0.0
                for m in messages {
                    let hash = Hash64.int64(TextNorm.collapse(m.text))
                    if let ext = m.externalID {
                        if try w.queryOne("SELECT 1 FROM message WHERE conversation_id=? AND external_id=?", [.int(conversationID), .text(ext)], { _ in 1 }) != nil { dup += 1; continue }
                    } else {
                        let exists = try w.queryOne("SELECT 1 FROM message WHERE conversation_id=? AND content_hash=? AND created_at=? AND role=?",
                                                    [.int(conversationID), .int(hash), .double(m.createdAt), .text(m.role.rawValue)], { _ in 1 })
                        if exists != nil { dup += 1; continue }
                    }
                    seq += 1
                    try w.run("""
                        INSERT INTO message(conversation_id,seq,role,text,created_at,external_id,content_hash,model,locality,meta)
                        VALUES(?,?,?,?,?,?,?,?,?,?)
                        """, [.int(conversationID), .int(seq), .text(m.role.rawValue), .text(m.text), .double(m.createdAt),
                              .opt(m.externalID), .int(hash), .opt(m.model), .text(m.locality.rawValue), .opt(m.meta)])
                    let id = w.lastInsertRowID
                    if first == nil { first = id }
                    last = id; inserted += 1; newest = max(newest, m.createdAt)
                }
                if inserted > 0 {
                    try w.run("""
                        UPDATE conversation SET message_count = message_count + ?, updated_at = MAX(COALESCE(updated_at,0), ?),
                          created_at = COALESCE(created_at, ?) WHERE id=?
                        """, [.int(inserted), .double(newest), .double(messages.first!.createdAt), .int(conversationID)])
                }
                return AppendResult(inserted: inserted, duplicates: dup, firstMessageID: first, lastMessageID: last)
            }
        }
    }

    public func message(_ id: Int64) throws -> MessageRecord? {
        try db.read { try $0.queryOne("SELECT \(MessageRecord.columns) FROM message WHERE id=?", [.int(id)], MessageRecord.init(row:)) }
    }

    public func messages(ids: [Int64]) throws -> [Int64: MessageRecord] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: MessageRecord] = [:]
        for batch in stride(from: 0, to: ids.count, by: 500) {
            let part = Array(ids[batch..<min(batch + 500, ids.count)])
            let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
            let rows = try db.read { try $0.query("SELECT \(MessageRecord.columns) FROM message WHERE id IN (\(marks))", part.map { .int($0) }, MessageRecord.init(row:)) }
            for r in rows { out[r.id] = r }
        }
        return out
    }

    public func messages(conversationID: Int64, seqFrom: Int, seqTo: Int) throws -> [MessageRecord] {
        try db.read { try $0.query("SELECT \(MessageRecord.columns) FROM message WHERE conversation_id=? AND seq BETWEEN ? AND ? ORDER BY seq",
                                   [.int(conversationID), .int(seqFrom), .int(seqTo)], MessageRecord.init(row:)) }
    }

    /// Last `limit` messages in chronological order.
    public func tail(conversationID: Int64, limit: Int, beforeSeq: Int? = nil) throws -> [MessageRecord] {
        let rows = try db.read {
            try $0.query("SELECT \(MessageRecord.columns) FROM message WHERE conversation_id=? AND seq < ? ORDER BY seq DESC LIMIT ?",
                         [.int(conversationID), .int(beforeSeq ?? Int.max), .int(limit)], MessageRecord.init(row:))
        }
        return rows.reversed()
    }

    public func messageCount(conversationID: Int64) throws -> Int {
        Int(try db.read { try $0.scalarInt("SELECT message_count FROM conversation WHERE id=?", [.int(conversationID)]) })
    }

    /// A message with surrounding context, for evidence inspection and "open original".
    public func window(around messageID: Int64, before: Int, after: Int) throws -> [MessageRecord] {
        guard let m = try message(messageID) else { return [] }
        return try messages(conversationID: m.conversationID, seqFrom: max(0, m.seq - before), seqTo: m.seq + after)
    }

    // MARK: erase (explicit user action; cascades to everything derived from the erased originals)

    public struct EraseImpact: Sendable {
        public var messages = 0, chunks = 0, vectors = 0, evidenceLinks = 0, memoriesRemoved = 0, memoriesWeakened = 0, summaries = 0
    }

    @discardableResult
    public func eraseConversation(_ id: Int64) throws -> EraseImpact {
        try erase(whereClause: "conversation_id = ?", params: [.int(id)], deleteConversationID: id)
    }

    @discardableResult
    public func eraseSource(_ id: Int64) throws -> EraseImpact {
        try db.write { w in
            var total = EraseImpact()
            let convs = try w.query("SELECT id FROM conversation WHERE source_id=?", [.int(id)]) { $0.int(0) }
            for c in convs {
                let i = try erase(whereClause: "conversation_id = ?", params: [.int(c)], deleteConversationID: c)
                total.messages += i.messages; total.chunks += i.chunks; total.vectors += i.vectors
                total.evidenceLinks += i.evidenceLinks; total.memoriesRemoved += i.memoriesRemoved
                total.memoriesWeakened += i.memoriesWeakened; total.summaries += i.summaries
            }
            try w.run("DELETE FROM asset WHERE source_id=?", [.int(id)])
            try w.run("DELETE FROM source WHERE id=?", [.int(id)])
            return total
        }
    }

    private func erase(whereClause: String, params: [SQLiteValue], deleteConversationID: Int64?) throws -> EraseImpact {
        try db.write { w in
            try w.transaction {
                var impact = EraseImpact()
                // Memories that cite these messages: weaken or remove once their evidence is gone.
                let affected = try w.query("""
                    SELECT DISTINCT memory_id FROM memory_evidence WHERE message_id IN (SELECT id FROM message WHERE \(whereClause))
                    """, params) { $0.int(0) }
                impact.evidenceLinks = Int(try w.scalarInt("SELECT COUNT(*) FROM memory_evidence WHERE message_id IN (SELECT id FROM message WHERE \(whereClause))", params))
                impact.vectors = try w.run("DELETE FROM vec WHERE space IN (SELECT space FROM vec_space WHERE item_kind='chunk') AND item_id IN (SELECT id FROM chunk WHERE \(whereClause))", params)
                impact.chunks = try w.run("DELETE FROM chunk WHERE \(whereClause)", params)
                impact.summaries = try w.run("DELETE FROM summary WHERE \(whereClause)", params)
                impact.messages = try w.run("DELETE FROM message WHERE \(whereClause)", params)   // cascades evidence / mentions / asset links
                for m in affected {
                    let remaining = try w.scalarInt("SELECT COUNT(*) FROM memory_evidence WHERE memory_id=? AND role='supports'", [.int(m)])
                    let createdBy = try w.queryOne("SELECT created_by FROM memory WHERE id=?", [.int(m)]) { $0.text(0) } ?? ""
                    if remaining == 0 && createdBy != "user" {
                        try w.run("DELETE FROM memory WHERE id=?", [.int(m)])
                        try w.run("INSERT INTO memory_event(memory_id,at,action,actor,detail) VALUES(?,?,?,?,?)",
                                  [.int(m), .double(Clock.now()), .text("source_erased"), .text("user"), .text("all supporting evidence erased")])
                        impact.memoriesRemoved += 1
                    } else {
                        try w.run("UPDATE memory SET confidence = confidence * 0.7, updated_at=? WHERE id=?", [.double(Clock.now()), .int(m)])
                        impact.memoriesWeakened += 1
                    }
                }
                if let c = deleteConversationID { try w.run("DELETE FROM conversation WHERE id=?", [.int(c)]) }
                return impact
            }
        }
    }

    // MARK: stats

    public func stats() throws -> StorageStats {
        try db.read { r in
            StorageStats(
                conversations: Int(try r.scalarInt("SELECT COUNT(*) FROM conversation")),
                messages: Int(try r.scalarInt("SELECT COALESCE(SUM(message_count),0) FROM conversation")),
                chunks: Int(try r.scalarInt("SELECT COUNT(*) FROM chunk")),
                chunksPending: Int(try r.scalarInt("SELECT COUNT(*) FROM chunk WHERE embedded=0")),
                vectors: Int(try r.scalarInt("SELECT COUNT(*) FROM vec")),
                memories: Int(try r.scalarInt("SELECT COUNT(*) FROM memory WHERE status IN ('active','disputed')")),
                assets: Int(try r.scalarInt("SELECT COUNT(*) FROM asset")),
                dbBytes: db.fileSize())
        }
    }
}
