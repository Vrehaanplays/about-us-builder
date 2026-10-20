import Foundation

public struct EntityRecord: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var kind: String
    public var name: String
    public var description: String?
    public var firstSeen: Double?, lastSeen: Double?
}

public enum EntityResolution: Sendable, Equatable {
    case found(Int64)
    case ambiguous([Int64])
    case none
}

public final class EntityStore: @unchecked Sendable {
    let db: ArchiveDatabase
    public init(db: ArchiveDatabase) { self.db = db }

    @discardableResult
    public func create(kind: String, name: String, description: String? = nil, aliases: [String] = [], createdBy: String = "extractor") throws -> Int64 {
        try db.write { w in
            try w.transaction {
                try w.run("INSERT INTO entity(kind,name,description,created_by) VALUES(?,?,?,?)", [.text(kind), .text(name), .opt(description), .text(createdBy)])
                let id = w.lastInsertRowID
                for a in Set(([name] + aliases).map { $0.lowercased() }) where !a.isEmpty {
                    try w.run("INSERT OR IGNORE INTO entity_alias(entity_id,alias) VALUES(?,?)", [.int(id), .text(a)])
                }
                return id
            }
        }
    }

    public func addAlias(_ entity: Int64, _ alias: String) throws {
        try db.write { try $0.run("INSERT OR IGNORE INTO entity_alias(entity_id,alias) VALUES(?,?)", [.int(entity), .text(alias.lowercased())]) }
    }

    public func entity(_ id: Int64) throws -> EntityRecord? {
        try db.read { try $0.queryOne("SELECT id, kind, name, description, first_seen, last_seen FROM entity WHERE id=? AND merged_into IS NULL", [.int(id)]) {
            EntityRecord(id: $0.int(0), kind: $0.text(1), name: $0.text(2), description: $0.optText(3), firstSeen: $0.optDouble(4), lastSeen: $0.optDouble(5)) } }
    }

    /// Resolution never guesses between same-named entities (two different "Alex"es): with several candidates it only picks one
    /// when the current conversation has mentioned exactly one of them; otherwise it reports `.ambiguous` and the caller must not link.
    public func resolve(name: String, kind: String? = nil, conversationID: Int64? = nil) throws -> EntityResolution {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        var ids = try db.read { try $0.query("""
            SELECT DISTINCT a.entity_id FROM entity_alias a JOIN entity e ON e.id = a.entity_id
            WHERE a.alias=? AND e.merged_into IS NULL \(kind != nil ? "AND e.kind=?" : "")
            """, kind != nil ? [.text(key), .text(kind!)] : [.text(key)]) { $0.int(0) } }
        ids.sort()
        if ids.isEmpty { return .none }
        if ids.count == 1 { return .found(ids[0]) }
        if let conv = conversationID {
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let present = try db.read { try $0.query("SELECT DISTINCT entity_id FROM entity_mention WHERE conversation_id=? AND entity_id IN (\(marks))",
                                                      [.int(conv)] + ids.map { .int($0) }) { $0.int(0) } }
            if present.count == 1 { return .found(present[0]) }
        }
        return .ambiguous(ids)
    }

    /// Entities whose aliases appear in free text (used by query analysis). Longest alias wins; ambiguous aliases are skipped.
    public func findMentions(in text: String, maxNGram: Int = 4) throws -> [Int64] {
        let words = TextNorm.words(text)
        guard !words.isEmpty else { return [] }
        var found: [Int64] = []
        var i = 0
        while i < words.count {
            var matched = false
            for n in stride(from: min(maxNGram, words.count - i), through: 1, by: -1) {
                let phrase = words[i..<(i + n)].joined(separator: " ")
                let ids = try db.read { try $0.query("SELECT DISTINCT entity_id FROM entity_alias WHERE alias=?", [.text(phrase)]) { $0.int(0) } }
                if ids.count == 1 { found.append(ids[0]); i += n; matched = true; break }
                if ids.count > 1 { i += n; matched = true; break }
            }
            if !matched { i += 1 }
        }
        return Array(Set(found))
    }

    public func recordMention(entity: Int64, messageID: Int64, conversationID: Int64, at time: Double) throws {
        try db.write { w in
            try w.run("INSERT OR IGNORE INTO entity_mention(entity_id,message_id,conversation_id) VALUES(?,?,?)", [.int(entity), .int(messageID), .int(conversationID)])
            try w.run("UPDATE entity SET first_seen=MIN(COALESCE(first_seen,?),?), last_seen=MAX(COALESCE(last_seen,?),?) WHERE id=?",
                      [.double(time), .double(time), .double(time), .double(time), .int(entity)])
        }
    }

    public func conversations(mentioning entity: Int64, limit: Int = 50) throws -> [(conversationID: Int64, mentions: Int)] {
        try db.read { try $0.query("SELECT conversation_id, COUNT(*) c FROM entity_mention WHERE entity_id=? GROUP BY conversation_id ORDER BY c DESC LIMIT ?",
                                   [.int(entity), .int(limit)]) { (conversationID: $0.int(0), mentions: Int($0.int(1))) } }
    }

    /// Merging is a user decision; the absorbed entity keeps a pointer so old references still resolve.
    public func merge(_ source: Int64, into target: Int64) throws {
        try db.write { w in
            try w.transaction {
                try w.run("UPDATE OR IGNORE entity_alias SET entity_id=? WHERE entity_id=?", [.int(target), .int(source)])
                try w.run("UPDATE OR IGNORE entity_mention SET entity_id=? WHERE entity_id=?", [.int(target), .int(source)])
                try w.run("UPDATE memory SET subject=? WHERE subject=?", [.int(target), .int(source)])
                try w.run("UPDATE entity SET merged_into=? WHERE id=?", [.int(target), .int(source)])
            }
        }
    }

    public func all(limit: Int = 500) throws -> [EntityRecord] {
        try db.read { try $0.query("SELECT id, kind, name, description, first_seen, last_seen FROM entity WHERE merged_into IS NULL ORDER BY last_seen DESC LIMIT ?", [.int(limit)]) {
            EntityRecord(id: $0.int(0), kind: $0.text(1), name: $0.text(2), description: $0.optText(3), firstSeen: $0.optDouble(4), lastSeen: $0.optDouble(5)) } }
    }
}
