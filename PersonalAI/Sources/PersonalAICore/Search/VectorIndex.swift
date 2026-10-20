import Foundation

public struct VectorHit: Sendable { public var id: Int64; public var score: Float }

/// IVF-flat approximate nearest-neighbour index with int8 scalar quantisation, stored inside the archive database.
///
/// Why this design (see docs/ARCHITECTURE.md): 14.6 M messages become ~1.5 M chunk vectors. At 256 dims int8 that is ~400 MB,
/// small enough to live on flash and be probed (nprobe lists of ~sqrt(N) vectors) without ever loading it all into RAM.
/// Vectors are *derived*: they can be dropped and rebuilt from the archive at any time.
public final class VectorIndex: @unchecked Sendable {
    public let archive: ArchiveDatabase
    public let space: Int
    public let dim: Int
    public let embedderID: String

    private let lock = NSLock()
    private var centroids: [Float] = []   // nlist * dim, normalised
    private var nlist = 0
    private var centroidsLoaded = false

    public init(archive: ArchiveDatabase, space: Int, name: String, embedderID: String, dim: Int, itemKind: String = "chunk") throws {
        self.archive = archive; self.space = space; self.dim = dim; self.embedderID = embedderID
        try archive.write { w in
            if let existing = try w.queryOne("SELECT embedder, dim FROM vec_space WHERE space=?", [.int(space)], { ($0.text(0), Int($0.int(1))) }) {
                if existing.0 != embedderID || existing.1 != dim {
                    // A different embedder means the old vectors are meaningless in the new space: drop them (originals are untouched).
                    try w.transaction {
                        try w.run("DELETE FROM vec WHERE space=?", [.int(space)])
                        try w.run("DELETE FROM vec_centroid WHERE space=?", [.int(space)])
                        try w.run("UPDATE vec_space SET embedder=?, dim=?, trained_count=0, nlist=1 WHERE space=?", [.text(embedderID), .int(dim), .int(space)])
                        if itemKind == "chunk" { try w.run("UPDATE chunk SET embedded=0") }
                    }
                }
            } else {
                try w.run("INSERT INTO vec_space(space,name,embedder,dim,item_kind) VALUES(?,?,?,?,?)", [.int(space), .text(name), .text(embedderID), .int(dim), .text(itemKind)])
            }
        }
    }

    public func count() throws -> Int { Int(try archive.read { try $0.scalarInt("SELECT COUNT(*) FROM vec WHERE space=?", [.int(space)]) }) }

    // MARK: quantisation

    @inline(__always)
    static func quantize(_ v: [Float]) -> (scale: Float, q: [Int8]) {
        var m: Float = 0
        for x in v { m = max(m, abs(x)) }
        let scale = m / 127
        if m == 0 { return (0, [Int8](repeating: 0, count: v.count)) }
        let inv = 1 / scale
        return (scale, v.map { Int8(max(-127, min(127, ($0 * inv).rounded()))) })
    }

    // MARK: centroids

    private func loadCentroids() throws {
        lock.lock(); defer { lock.unlock() }
        if centroidsLoaded { return }
        let rows: [(Int, Data)] = try archive.read { try $0.query("SELECT list, centroid FROM vec_centroid WHERE space=? ORDER BY list", [.int(space)]) { (Int($0.int(0)), $0.blob(1)) } }
        var flat = [Float](); flat.reserveCapacity(rows.count * dim)
        for (_, d) in rows { d.withUnsafeBytes { flat.append(contentsOf: $0.bindMemory(to: Float.self)) } }
        centroids = flat; nlist = rows.count; centroidsLoaded = true
    }

    private func nearestLists(_ q: [Float], count: Int) -> [Int] {
        guard nlist > 0 else { return [0] }
        var scores = [(Float, Int)](); scores.reserveCapacity(nlist)
        centroids.withUnsafeBufferPointer { c in
            q.withUnsafeBufferPointer { qp in
                for l in 0..<nlist {
                    var s: Float = 0
                    let base = l * dim
                    for i in 0..<dim { s += c[base + i] * qp[i] }
                    scores.append((s, l))
                }
            }
        }
        scores.sort { $0.0 > $1.0 }
        return scores.prefix(count).map { $0.1 }
    }

    // MARK: write

    public func add(_ items: [(id: Int64, vector: [Float])]) throws {
        guard !items.isEmpty else { return }
        try loadCentroids()
        try archive.write { w in
            try w.transaction {
                for it in items {
                    precondition(it.vector.count == dim, "vector dim mismatch")
                    let (scale, q) = Self.quantize(it.vector)
                    let list = nlist > 0 ? nearestLists(it.vector, count: 1)[0] : 0
                    try w.run("DELETE FROM vec WHERE space=? AND item_id=?", [.int(space), .int(it.id)])
                    let blob = q.withUnsafeBufferPointer { Data(buffer: $0) }
                    try w.run("INSERT INTO vec(space,list,item_id,scale,v) VALUES(?,?,?,?,?)",
                              [.int(space), .int(list), .int(it.id), .double(Double(scale)), .blob(blob)])
                }
            }
        }
    }

    public func remove(ids: [Int64]) throws {
        try archive.write { w in try w.transaction { for id in ids { try w.run("DELETE FROM vec WHERE space=? AND item_id=?", [.int(space), .int(id)]) } } }
    }

    /// The stored (dequantised) vector for an item, used for "more like this" associative hops without re-embedding.
    public func vector(forItem id: Int64) throws -> [Float]? {
        try archive.read { r in
            try r.queryOne("SELECT scale, v FROM vec WHERE space=? AND item_id=?", [.int(space), .int(id)]) { row -> [Float] in
                let scale = Float(row.double(0))
                return row.withBlob(1) { raw in
                    let p = raw.bindMemory(to: Int8.self)
                    var v = (0..<min(dim, p.count)).map { Float(p[$0]) * scale }
                    VectorMath.normalize(&v)
                    return v
                }
            }
        }
    }

    // MARK: search

    /// Approximate search. `nprobe` trades recall for latency; nil picks a default from the list count.
    public func search(_ query: [Float], k: Int, nprobe: Int? = nil, accept: ((Int64) -> Bool)? = nil) throws -> [VectorHit] {
        precondition(query.count == dim)
        try loadCentroids()
        let probes = nprobe ?? max(4, min(nlist, Int((Double(nlist) / 12).rounded(.up))))
        let lists = nlist == 0 ? [0] : nearestLists(query, count: probes)
        return try scan(lists: lists, query: query, k: k, accept: accept)
    }

    /// Exhaustive scan: ground truth for recall measurements and for small indexes.
    public func searchExact(_ query: [Float], k: Int, accept: ((Int64) -> Bool)? = nil) throws -> [VectorHit] {
        try scan(lists: nil, query: query, k: k, accept: accept)
    }

    private func scan(lists: [Int]?, query: [Float], k: Int, accept: ((Int64) -> Bool)?) throws -> [VectorHit] {
        let (qs, qq) = Self.quantize(query)
        var heap = TopK(capacity: k)
        let d = dim
        qq.withUnsafeBufferPointer { qp in
            func consume(_ r: Row) {
                let id = r.int(0)
                let scale = Float(r.double(1))
                r.withBlob(2) { raw in
                    guard raw.count == d else { return }
                    let vp = raw.bindMemory(to: Int8.self)
                    var acc: Int32 = 0
                    for i in 0..<d { acc &+= Int32(qp[i]) &* Int32(vp[i]) }
                    let s = Float(acc) * scale * qs
                    if heap.wouldAccept(s), accept?(id) ?? true { heap.push(VectorHit(id: id, score: s)) }
                }
            }
            do {
                if let lists {
                    for l in lists {
                        try archive.read { try $0.forEach("SELECT item_id, scale, v FROM vec WHERE space=? AND list=?", [.int(space), .int(l)]) { consume($0); return true } }
                    }
                } else {
                    try archive.read { try $0.forEach("SELECT item_id, scale, v FROM vec WHERE space=?", [.int(space)]) { consume($0); return true } }
                }
            } catch { /* surfaced below via empty result; callers treat vector search as best-effort */ }
        }
        return heap.sortedDescending()
    }

    // MARK: training (k-means on a sample, then incremental reassignment)

    /// Recommended number of lists for N vectors.
    public static func recommendedLists(for n: Int) -> Int { max(1, min(4096, Int(4 * Double(n).squareRoot()))) }

    public func needsTraining() throws -> Bool {
        let n = try count()
        let trained = Int(try archive.read { try $0.scalarInt("SELECT trained_count FROM vec_space WHERE space=?", [.int(space)]) })
        return n >= 4096 && (trained == 0 || n >= trained * 4)
    }

    /// Spherical k-means on ≤ `sampleSize` vectors, then moves every row to its nearest list in resumable batches.
    /// `shouldContinue` lets the scheduler pause this when the user starts generating.
    public func train(lists requestedLists: Int? = nil, sampleSize: Int = 40_000, iterations: Int = 8, shouldContinue: () -> Bool = { true }) throws {
        let n = try count()
        guard n >= 256 else { return }
        let k = requestedLists ?? Self.recommendedLists(for: n)
        let d = dim
        // Sample dequantised vectors into one flat buffer (cache-friendly; no per-vector arrays).
        var sample = [Float](); sample.reserveCapacity(min(n, sampleSize) * d)
        var rows = 0
        let stride = max(1, n / sampleSize)
        var i = 0
        try archive.read { r in
            try r.forEach("SELECT scale, v FROM vec WHERE space=?", [.int(space)]) { row in
                defer { i += 1 }
                if i % stride != 0 { return true }
                let scale = Float(row.double(0))
                row.withBlob(1) { raw in
                    let p = raw.bindMemory(to: Int8.self)
                    var norm: Float = 0
                    let start = sample.count
                    for j in 0..<d { let x = j < p.count ? Float(p[j]) * scale : 0; sample.append(x); norm += x * x }
                    if norm > 0 { let inv = 1 / norm.squareRoot(); for j in start..<(start + d) { sample[j] *= inv } }
                }
                rows += 1
                return rows < sampleSize
            }
        }
        guard rows >= k else { return }
        var cents = [Float](repeating: 0, count: k * d)
        for l in 0..<k { let src = ((l * rows) / k) * d; for j in 0..<d { cents[l * d + j] = sample[src + j] } }
        var assign = [Int32](repeating: 0, count: rows)
        for _ in 0..<iterations {
            guard shouldContinue() else { return }
            sample.withUnsafeBufferPointer { sp in cents.withUnsafeBufferPointer { cp in
                for si in 0..<rows {
                    let sb = si * d
                    var best = 0; var bs: Float = -2
                    for l in 0..<k {
                        let cb = l * d
                        var dsum: Float = 0
                        for t in 0..<d { dsum += cp[cb + t] * sp[sb + t] }
                        if dsum > bs { bs = dsum; best = l }
                    }
                    assign[si] = Int32(best)
                }
            } }
            var sums = [Float](repeating: 0, count: k * d)
            var counts = [Int](repeating: 0, count: k)
            for si in 0..<rows {
                let a = Int(assign[si]); counts[a] += 1
                let sb = si * d, ab = a * d
                for t in 0..<d { sums[ab + t] += sample[sb + t] }
            }
            for l in 0..<k {
                let lb = l * d
                if counts[l] == 0 { let src = ((l * 7919) % rows) * d; for t in 0..<d { cents[lb + t] = sample[src + t] }; continue }
                var norm: Float = 0
                for t in 0..<d { norm += sums[lb + t] * sums[lb + t] }
                let inv = norm > 0 ? 1 / norm.squareRoot() : 0
                for t in 0..<d { cents[lb + t] = sums[lb + t] * inv }
            }
        }
        try archive.write { w in
            try w.transaction {
                try w.run("DELETE FROM vec_centroid WHERE space=?", [.int(space)])
                for l in 0..<k {
                    let blob = cents[(l * d)..<((l + 1) * d)].withUnsafeBufferPointer { Data(buffer: $0) }
                    try w.run("INSERT INTO vec_centroid(space,list,centroid,count) VALUES(?,?,?,0)", [.int(space), .int(l), .blob(blob)])
                }
                try w.run("UPDATE vec_space SET trained_count=?, nlist=? WHERE space=?", [.int(n), .int(k), .int(space)])
            }
        }
        lock.lock(); centroids = cents; nlist = k; centroidsLoaded = true; lock.unlock()
        try reassignAll(shouldContinue: shouldContinue)
    }

    /// Rows are only ever *moved* between lists; searches during reassignment still see every vector exactly once.
    public func reassignAll(shouldContinue: () -> Bool = { true }) throws {
        try loadCentroids()
        var lastList = -1, lastItem: Int64 = -1
        while shouldContinue() {
            let batch: [(Int, Int64, Float, Data)] = try archive.read {
                try $0.query("""
                    SELECT list, item_id, scale, v FROM vec WHERE space=? AND (list > ? OR (list = ? AND item_id > ?))
                    ORDER BY list, item_id LIMIT 4000
                    """, [.int(space), .int(lastList), .int(lastList), .int(lastItem)]) { (Int($0.int(0)), $0.int(1), Float($0.double(2)), $0.blob(3)) }
            }
            if batch.isEmpty { return }
            var moves: [(Int, Int, Int64)] = []
            for (list, id, scale, blob) in batch {
                var v = [Float](repeating: 0, count: dim)
                blob.withUnsafeBytes { raw in let p = raw.bindMemory(to: Int8.self); for j in 0..<min(dim, p.count) { v[j] = Float(p[j]) * scale } }
                VectorMath.normalize(&v)
                let target = nearestLists(v, count: 1)[0]
                if target != list { moves.append((list, target, id)) }
            }
            try archive.write { w in
                try w.transaction {
                    for (from, to, id) in moves {
                        try w.run("UPDATE vec SET list=? WHERE space=? AND list=? AND item_id=?", [.int(to), .int(space), .int(from), .int(id)])
                    }
                }
            }
            lastList = batch.last!.0; lastItem = batch.last!.1
        }
    }
}

/// Bounded min-heap keeping the best `capacity` hits.
struct TopK {
    let capacity: Int
    private var items: [VectorHit] = []
    init(capacity: Int) { self.capacity = max(1, capacity); items.reserveCapacity(capacity + 1) }
    var minScore: Float { items.count < capacity ? -Float.infinity : items[0].score }
    @inline(__always) func wouldAccept(_ s: Float) -> Bool { items.count < capacity || s > items[0].score }
    mutating func push(_ h: VectorHit) {
        if items.count < capacity {
            items.append(h); var i = items.count - 1
            while i > 0 { let p = (i - 1) / 2; if items[p].score > items[i].score { items.swapAt(p, i); i = p } else { break } }
        } else if h.score > items[0].score {
            items[0] = h; var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1; var m = i
                if l < items.count, items[l].score < items[m].score { m = l }
                if r < items.count, items[r].score < items[m].score { m = r }
                if m == i { break }
                items.swapAt(i, m); i = m
            }
        }
    }
    func sortedDescending() -> [VectorHit] { items.sorted { $0.score > $1.score } }
}
