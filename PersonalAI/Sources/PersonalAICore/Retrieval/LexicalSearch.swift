import Foundation

public struct SearchFilters: Sendable {
    public var conversationIDs: [Int64]?
    public var roles: [Role]?
    public var timeRange: ClosedRange<Double>?
    public var excludeConversation: Int64?
    public init(conversationIDs: [Int64]? = nil, roles: [Role]? = nil, timeRange: ClosedRange<Double>? = nil, excludeConversation: Int64? = nil) {
        self.conversationIDs = conversationIDs; self.roles = roles; self.timeRange = timeRange; self.excludeConversation = excludeConversation
    }
}

public struct LexicalHit: Sendable {
    public var messageID: Int64
    public var conversationID: Int64
    public var seq: Int
    public var createdAt: Double
    public var role: Role
    public var score: Double          // higher is better (negated bm25)
}

/// Exact keyword / phrase search over the original messages (FTS5 + BM25).
/// Natural-language queries are turned into an OR of the *rarest* informative terms: rarity comes from the index itself
/// (fts5vocab document frequencies), so no hand-maintained stopword list is needed and common words never blow up latency.
public final class LexicalSearch: @unchecked Sendable {
    let db: ArchiveDatabase
    private var dfCache: [String: Int] = [:]
    private let lock = NSLock()
    public init(db: ArchiveDatabase) { self.db = db }

    public func documentFrequency(_ term: String) -> Int {
        lock.lock(); if let v = dfCache[term] { lock.unlock(); return v }; lock.unlock()
        let v = Int((try? db.read { try $0.queryOne("SELECT doc FROM message_vocab WHERE term=?", [.text(term)]) { $0.int(0) } }) ?? 0)
        lock.lock(); if dfCache.count > 20_000 { dfCache.removeAll() }; dfCache[term] = v; lock.unlock()
        return v
    }

    public func invalidateStats() { lock.lock(); dfCache.removeAll(); lock.unlock() }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: " ") + "\"" }

    /// Terms ordered rarest-first, dropping terms absent from the archive and terms too common to be informative.
    public func informativeTerms(_ terms: [String], total: Int, max: Int = 6) -> [(term: String, df: Int)] {
        let ceiling = Swift.max(2000, Int(Double(total) * 0.04))
        return terms.map { ($0, documentFrequency($0)) }.filter { $0.1 > 0 && $0.1 <= ceiling }.sorted { $0.1 < $1.1 }.prefix(max).map { $0 }
    }

    public func searchMessages(phrases: [String] = [], terms: [String] = [], filters: SearchFilters = SearchFilters(), limit: Int = 40,
                               totalMessages: Int? = nil, prefixLastTerm: Bool = false) throws -> [LexicalHit] {
        var clauses: [String] = []
        let total: Int = try totalMessages ?? Int(db.read { try $0.scalarInt("SELECT COALESCE(SUM(message_count),0) FROM conversation") })
        for p in phrases { clauses.append(Self.quote(p)) }
        let mustPhrases = clauses.isEmpty ? "" : "(" + clauses.joined(separator: " AND ") + ")"
        let info = informativeTerms(terms, total: total)
        var orPart = info.map { Self.quote($0.term) }.joined(separator: " OR ")
        if prefixLastTerm, let last = terms.last, last.count >= 3, !info.contains(where: { $0.term == last }) {
            orPart += (orPart.isEmpty ? "" : " OR ") + Self.quote(last) + "*"
        }
        var expr: String
        if !mustPhrases.isEmpty { expr = orPart.isEmpty ? mustPhrases : "\(mustPhrases) AND (\(orPart))" }
        else { expr = orPart }
        if expr.isEmpty { return [] }

        var sql = """
            SELECT m.id, m.conversation_id, m.seq, m.created_at, m.role, bm25(message_fts) AS s
            FROM message_fts JOIN message m ON m.id = message_fts.rowid WHERE message_fts MATCH ?
            """
        var params: [SQLiteValue] = [.text(expr)]
        if let c = filters.conversationIDs, !c.isEmpty { sql += " AND m.conversation_id IN (\(c.map(String.init).joined(separator: ",")))" }
        if let x = filters.excludeConversation { sql += " AND m.conversation_id != ?"; params.append(.int(x)) }
        if let r = filters.roles { sql += " AND m.role IN (\(r.map { "'\($0.rawValue)'" }.joined(separator: ",")))" }
        if let t = filters.timeRange { sql += " AND m.created_at BETWEEN ? AND ?"; params += [.double(t.lowerBound), .double(t.upperBound)] }
        sql += " ORDER BY s LIMIT ?"; params.append(.int(limit))
        var hits = try db.read { try $0.query(sql, params) {
            LexicalHit(messageID: $0.int(0), conversationID: $0.int(1), seq: Int($0.int(2)), createdAt: $0.double(3), role: Role(rawValue: $0.text(4)) ?? .user, score: -$0.double(5)) } }
        // A phrase-only miss with extra terms falls back to terms alone so a slightly wrong quote still finds the message.
        if hits.isEmpty, !mustPhrases.isEmpty, !orPart.isEmpty, phrases.count >= 1 {
            return try searchMessages(phrases: [], terms: terms + phrases.flatMap { TextNorm.words($0) }, filters: filters, limit: limit, totalMessages: total, prefixLastTerm: prefixLastTerm)
        }
        hits.sort { $0.score > $1.score }
        return hits
    }

    public func searchAssets(terms: [String], timeRange: ClosedRange<Double>? = nil, kinds: [String]? = nil, limit: Int = 20) throws -> [(id: Int64, score: Double)] {
        let expr = terms.filter { $0.count > 1 }.prefix(8).map { Self.quote($0) }.joined(separator: " OR ")
        var sql = "SELECT a.id, bm25(asset_fts) FROM asset_fts JOIN asset a ON a.id = asset_fts.rowid WHERE asset_fts MATCH ? AND a.status != 'removed'"
        var params: [SQLiteValue] = [.text(expr)]
        if let t = timeRange { sql += " AND a.created_at BETWEEN ? AND ?"; params += [.double(t.lowerBound), .double(t.upperBound)] }
        if let k = kinds { sql += " AND a.kind IN (\(k.map { "'\($0)'" }.joined(separator: ",")))" }
        sql += " ORDER BY bm25(asset_fts) LIMIT ?"; params.append(.int(limit))
        if expr.isEmpty { return [] }
        return try db.read { try $0.query(sql, params) { ($0.int(0), -$0.double(1)) } }
    }

    public func searchConversationTitles(terms: [String], limit: Int = 10) throws -> [(id: Int64, score: Double)] {
        let expr = terms.prefix(6).map { Self.quote($0) }.joined(separator: " OR ")
        guard !expr.isEmpty else { return [] }
        return try db.read { try $0.query("SELECT rowid, bm25(conversation_fts) FROM conversation_fts WHERE conversation_fts MATCH ? ORDER BY bm25(conversation_fts) LIMIT ?", [.text(expr), .int(limit)]) { ($0.int(0), -$0.double(1)) } }
    }
}
