import XCTest
@testable import PersonalAICore

final class VectorTests: XCTestCase {
    /// Clustered synthetic vectors (like topics in a real archive). Measures IVF recall against exact scan.
    func testIVFRecallAgainstExact() throws {
        let (db, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let dim = 32, n = 6_000, topics = 40
        var rng = SeededRNG(seed: 42)
        let centers: [[Float]] = (0..<topics).map { _ in (0..<dim).map { _ in Float.random(in: -1...1, using: &rng) } }
        var vecs: [[Float]] = []
        for i in 0..<n {
            var v = centers[i % topics].map { $0 + Float.random(in: -0.35...0.35, using: &rng) }
            VectorMath.normalize(&v); vecs.append(v)
        }
        let idx = try VectorIndex(archive: db, space: 1, name: "t", embedderID: "test", dim: dim)
        for b in stride(from: 0, to: n, by: 2000) {
            try idx.add((b..<min(b + 2000, n)).map { (Int64($0), vecs[$0]) })
        }
        XCTAssertEqual(try idx.count(), n)
        idx.exactLimit = 1000
        XCTAssertTrue(try idx.needsTraining())
        try idx.train(lists: 48)
        XCTAssertEqual(try idx.count(), n, "reassignment must not lose or duplicate vectors")

        var hits = 0, total = 0
        for qi in stride(from: 5, to: n, by: 300) {
            var q = vecs[qi]; for j in 0..<dim { q[j] += Float.random(in: -0.1...0.1, using: &rng) }; VectorMath.normalize(&q)
            let exact = Set(try idx.searchExact(q, k: 10).map(\.id))
            let approx = Set(try idx.search(q, k: 10).map(\.id))
            hits += exact.intersection(approx).count; total += exact.count
        }
        let recall = Double(hits) / Double(total)
        print("IVF recall@10 = \(recall)")
        XCTAssertGreaterThan(recall, 0.85)

        // calibration finds a probe count that meets the recall target on this very index, and reports what it achieved
        let q = try idx.calibrate(target: 0.9)
        XCTAssertFalse(q.exact)
        XCTAssertNotNil(q.nprobe); XCTAssertGreaterThanOrEqual(q.measuredRecall ?? 0, 0.9)
        print("calibrated nprobe=\(q.nprobe ?? 0) of \(q.lists), recall \(q.measuredRecall ?? 0)")

        // physical removal
        try idx.remove(ids: [123, 124, 125])
        XCTAssertEqual(try idx.count(), n - 3)
        XCTAssertFalse(try idx.searchExact(vecs[123], k: 5).contains { $0.id == 123 })

        // exact int8 result agrees with float ground truth at the top
        XCTAssertEqual(try idx.searchExact(vecs[200], k: 1).first?.id, 200)
    }

    func testErasedChunkVectorsArePhysicallyPurged() async throws {
        let (db, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveStore(db: db)
        let s = try store.upsertSource(kind: "generic", name: "t", externalID: "t")
        let (c, _) = try store.upsertConversation(sourceID: s, externalID: "c", title: "t", createdAt: 0, updatedAt: 0)
        try store.appendMessages(conversationID: c, [NewMessage(role: .user, text: "my secret plan involves zebras", createdAt: 1, externalID: "a")])
        let idx = try VectorIndex(archive: db, space: 1, name: "chunks", embedderID: "h", dim: 64)
        let h = HashingEmbedder(dim: 64)
        let pipe = IndexingPipeline(archive: store, chunker: Chunker(store: store), vectors: idx, embedder: h)
        try pipe.chunkStep(conversations: 10)
        let embedded = try await pipe.embedStep()
        XCTAssertEqual(embedded, 1)
        XCTAssertEqual(try idx.count(), 1)
        let impact = try store.eraseConversation(c)
        XCTAssertEqual(impact.vectors, 1)
        XCTAssertEqual(try idx.count(), 1, "queued, not yet removed")
        XCTAssertEqual(try idx.applyPurges(), 1)
        XCTAssertEqual(try idx.count(), 0, "after purge no embedding of the erased text remains")
    }

    func testChangingEmbedderInvalidatesOldVectors() throws {
        let (db, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try VectorIndex(archive: db, space: 1, name: "t", embedderID: "A", dim: 8)
        try a.add([(1, [1, 0, 0, 0, 0, 0, 0, 0])])
        XCTAssertEqual(try a.count(), 1)
        let b = try VectorIndex(archive: db, space: 1, name: "t", embedderID: "B", dim: 8)
        XCTAssertEqual(try b.count(), 0, "vectors from another embedder are meaningless and must be rebuilt")
    }

    func testChunkerBoundsAndLongMessageSlicing() throws {
        let (db, dir) = try makeTempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveStore(db: db)
        let s = try store.upsertSource(kind: "generic", name: "t", externalID: "t")
        let (c, _) = try store.upsertConversation(sourceID: s, externalID: "c", title: "t", createdAt: 0, updatedAt: 0)
        var msgs: [NewMessage] = []
        for i in 0..<40 { msgs.append(NewMessage(role: i % 2 == 0 ? .user : .assistant, text: String(repeating: "word\(i) ", count: 40), createdAt: Double(i * 10), externalID: "m\(i)")) }
        msgs.append(NewMessage(role: .assistant, text: String(repeating: "A long paragraph about gardens. ", count: 400), createdAt: 1000, externalID: "long"))
        msgs.append(NewMessage(role: .user, text: "after gap", createdAt: 1000 + 10_000, externalID: "late"))
        try store.appendMessages(conversationID: c, msgs)
        let chunker = Chunker(store: store)
        let n = try chunker.chunkNewMessages(conversationID: c, holdBack: 0)
        XCTAssertGreaterThan(n, 5)
        // every message is covered by exactly one chunk range (long message may be covered by several slices)
        let covered = try db.read { try $0.query("SELECT first_seq, last_seq, char_start FROM chunk WHERE conversation_id=? ORDER BY id", [.int(c)]) { (Int($0.int(0)), Int($0.int(1)), $0.optInt(2)) } }
        var seen = Set<Int>()
        for (a, b, cs) in covered where cs == nil { for s in a...b { XCTAssertTrue(seen.insert(s).inserted, "seq \(s) in two chunks") } }
        XCTAssertGreaterThan(covered.filter { $0.2 != nil }.count, 3, "oversized message becomes several slices")
        // idempotent
        XCTAssertEqual(try chunker.chunkNewMessages(conversationID: c), 0)
        // slices reconstruct the original text exactly
        let longMsg = try store.tail(conversationID: c, limit: 2).first!
        let chunkRows = try db.read { try $0.query("SELECT \(ChunkRecord.columns) FROM chunk WHERE first_msg=? AND char_start IS NOT NULL ORDER BY char_start", [.int(longMsg.id)], ChunkRecord.init(row:)) }
        let rebuilt = chunkRows.map { r -> String in let u = Array(longMsg.text.utf8); return String(decoding: u[r.charStart!..<r.charEnd!], as: UTF8.self) }.joined()
        XCTAssertEqual(rebuilt, longMsg.text)
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
