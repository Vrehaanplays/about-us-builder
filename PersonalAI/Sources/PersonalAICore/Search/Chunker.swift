import Foundation

public struct ChunkingPolicy: Sendable {
    public var targetTokens = 256
    public var maxTokens = 480
    public var gapSeconds = 2700.0           // new topic burst after 45 min of silence
    public var sliceBytes = 1500             // slice size for single messages above maxTokens
    public init() {}
}

/// Splits conversations into embedding/retrieval units made of contiguous whole messages.
/// Chunks store only message ranges (never copies of text), so they are tiny and can be rebuilt at will.
public final class Chunker: @unchecked Sendable {
    let store: ArchiveStore
    let counter: TokenCounter
    public let policy: ChunkingPolicy

    public init(store: ArchiveStore, counter: TokenCounter = HeuristicTokenCounter(), policy: ChunkingPolicy = ChunkingPolicy()) {
        self.store = store; self.counter = counter; self.policy = policy
    }

    private struct Pending { var firstMsg: Int64, lastMsg: Int64, firstSeq: Int, lastSeq: Int, t0: Double, t1: Double, tokens: Int }

    /// Chunks every message after the conversation's already-chunked tail. Returns chunks created.
    @discardableResult
    public func chunkNewMessages(conversationID: Int64, holdBack: Int = 0) throws -> Int {
        let db = store.db
        // Live conversations keep their newest messages unchunked so a chunk never straddles a turn that is still being written.
        let maxSeq = Int(try db.read { try $0.scalarInt("SELECT COALESCE(MAX(seq), -1) FROM message WHERE conversation_id=?", [.int(conversationID)]) }) - max(0, holdBack)
        let doneSeq = Int(try db.read { try $0.scalarInt("SELECT COALESCE(MAX(last_seq), -1) FROM chunk WHERE conversation_id=?", [.int(conversationID)]) })
        var created = 0
        var cur: Pending?
        var batch: [Pending] = []
        var slices: [(Int64, Int, Int, Int, Double, Int)] = []   // msg, seq, charStart, charEnd, t, tokens
        func flushRows() throws {
            guard !batch.isEmpty || !slices.isEmpty else { return }
            try db.write { w in
                try w.transaction {
                    for c in batch {
                        try w.run("INSERT INTO chunk(conversation_id,first_msg,last_msg,first_seq,last_seq,t0,t1,tokens) VALUES(?,?,?,?,?,?,?,?)",
                                  [.int(conversationID), .int(c.firstMsg), .int(c.lastMsg), .int(c.firstSeq), .int(c.lastSeq), .double(c.t0), .double(c.t1), .int(c.tokens)])
                    }
                    for s in slices {
                        try w.run("INSERT INTO chunk(conversation_id,first_msg,last_msg,first_seq,last_seq,char_start,char_end,t0,t1,tokens) VALUES(?,?,?,?,?,?,?,?,?,?)",
                                  [.int(conversationID), .int(s.0), .int(s.0), .int(s.1), .int(s.1), .int(s.2), .int(s.3), .double(s.4), .double(s.4), .int(s.5)])
                    }
                }
            }
            created += batch.count + slices.count
            batch.removeAll(keepingCapacity: true); slices.removeAll(keepingCapacity: true)
        }
        func close() { if let c = cur { batch.append(c); cur = nil } }

        // Stream messages in order; memory stays bounded to one message plus pending chunk rows.
        var lastSeqSeen = doneSeq
        while true {
            let rows: [(Int64, Int, Double, String)] = try db.read {
                try $0.query("SELECT id, seq, created_at, text FROM message WHERE conversation_id=? AND seq > ? AND seq <= ? ORDER BY seq LIMIT 500",
                             [.int(conversationID), .int(lastSeqSeen), .int(maxSeq)]) { ($0.int(0), Int($0.int(1)), $0.double(2), $0.text(3)) }
            }
            if rows.isEmpty { break }
            for (id, seq, t, text) in rows {
                lastSeqSeen = seq
                let tokens = counter.count(text) + 4
                if tokens > policy.maxTokens {
                    close()
                    for (a, b) in Self.slice(text, bytes: policy.sliceBytes) {
                        slices.append((id, seq, a, b, t, counter.count(String(decoding: Array(text.utf8)[a..<b], as: UTF8.self)) + 4))
                    }
                    continue
                }
                if var c = cur {
                    if t - c.t1 > policy.gapSeconds || c.tokens + tokens > policy.maxTokens || c.tokens >= policy.targetTokens {
                        close(); cur = Pending(firstMsg: id, lastMsg: id, firstSeq: seq, lastSeq: seq, t0: t, t1: t, tokens: tokens)
                    } else {
                        c.lastMsg = id; c.lastSeq = seq; c.t1 = t; c.tokens += tokens; cur = c
                    }
                } else {
                    cur = Pending(firstMsg: id, lastMsg: id, firstSeq: seq, lastSeq: seq, t0: t, t1: t, tokens: tokens)
                }
            }
            if batch.count + slices.count > 400 { try flushRows() }
        }
        // The trailing chunk stays open-ended only conceptually: closing it is safe because later appends start a new chunk.
        close()
        try flushRows()
        return created
    }

    /// Byte ranges of `text`, each ≤ `bytes`, cut at paragraph/line/sentence/space boundaries when possible.
    static func slice(_ text: String, bytes: Int) -> [(Int, Int)] {
        let u = Array(text.utf8)
        var out: [(Int, Int)] = []
        var start = 0
        while start < u.count {
            var end = min(u.count, start + bytes)
            if end < u.count {
                var cut = end
                let floor = start + bytes / 2
                search: for pass in 0..<3 {
                    var i = end
                    while i > floor {
                        let c = u[i - 1]
                        switch pass {
                        case 0: if c == 0x0A, i >= 2, u[i - 2] == 0x0A { cut = i; break search }
                        case 1: if c == 0x0A || ((c == 0x20) && i >= 2 && (u[i - 2] == 0x2E || u[i - 2] == 0x3F || u[i - 2] == 0x21)) { cut = i; break search }
                        default: if c == 0x20 { cut = i; break search }
                        }
                        i -= 1
                    }
                }
                end = cut
                while end < u.count, end > start, (u[end] & 0xC0) == 0x80 { end -= 1 }   // never split a UTF-8 sequence
                if end <= start { end = min(u.count, start + bytes) }
            }
            out.append((start, end))
            start = end
        }
        return out
    }

    /// Chunks all conversations that have unchunked messages. Cooperative: checks `shouldContinue` between conversations.
    @discardableResult
    public func chunkPending(maxConversations: Int = Int.max, holdBack: Int = 0, shouldContinue: () -> Bool = { true }) throws -> Int {
        var total = 0
        var cursor: Int64 = 0
        var done = 0
        while done < maxConversations, shouldContinue() {
            let ids: [Int64] = try store.db.read {
                try $0.query("""
                    SELECT c.id FROM conversation c WHERE c.id > ? AND c.message_count >
                      COALESCE((SELECT MAX(last_seq) + 1 FROM chunk WHERE conversation_id = c.id), 0)
                    ORDER BY c.id LIMIT 200
                    """, [.int(cursor)]) { $0.int(0) }
            }
            if ids.isEmpty { break }
            for id in ids {
                if !shouldContinue() { return total }
                total += try chunkNewMessages(conversationID: id, holdBack: holdBack)
                cursor = id; done += 1
            }
        }
        return total
    }
}

/// Builds the text that is embedded (and shown as evidence) for a chunk.
public enum ChunkText {
    public static func build(_ chunk: ChunkRecord, store: ArchiveStore, maxChars: Int = 2400) throws -> String {
        let msgs = try store.messages(conversationID: chunk.conversationID, seqFrom: chunk.firstSeq, seqTo: chunk.lastSeq)
        var out = ""
        for m in msgs {
            var t = m.text
            if let a = chunk.charStart, let b = chunk.charEnd {
                let u = Array(t.utf8)
                t = String(decoding: u[min(a, u.count)..<min(b, u.count)], as: UTF8.self)
            }
            let who = m.role == .user ? "User" : (m.role == .assistant ? "Assistant" : m.role.rawValue.capitalized)
            out += "\(who): \(t)\n"
            if out.count >= maxChars { break }
        }
        return out.count > maxChars ? String(out.prefix(maxChars)) : out
    }
}

public struct ChunkRecord: Sendable, Hashable {
    public var id: Int64
    public var conversationID: Int64
    public var firstMsg: Int64, lastMsg: Int64
    public var firstSeq: Int, lastSeq: Int
    public var charStart: Int?, charEnd: Int?
    public var t0: Double, t1: Double
    public var tokens: Int
    static let columns = "id, conversation_id, first_msg, last_msg, first_seq, last_seq, char_start, char_end, t0, t1, tokens"
    init(row r: Row) {
        id = r.int(0); conversationID = r.int(1); firstMsg = r.int(2); lastMsg = r.int(3)
        firstSeq = Int(r.int(4)); lastSeq = Int(r.int(5)); charStart = r.optInt(6).map(Int.init); charEnd = r.optInt(7).map(Int.init)
        t0 = r.double(8); t1 = r.double(9); tokens = Int(r.int(10))
    }
}

extension ArchiveStore {
    public func chunks(ids: [Int64]) throws -> [Int64: ChunkRecord] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: ChunkRecord] = [:]
        for b in stride(from: 0, to: ids.count, by: 500) {
            let part = Array(ids[b..<min(b + 500, ids.count)])
            let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
            for r in try db.read({ try $0.query("SELECT \(ChunkRecord.columns) FROM chunk WHERE id IN (\(marks))", part.map { .int($0) }, ChunkRecord.init(row:)) }) { out[r.id] = r }
        }
        return out
    }
}
