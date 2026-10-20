import Foundation

public struct VectorHit: Sendable { public var id: Int64; public var score: Float }

public struct IndexQuality: Sendable {
    public var vectors: Int
    public var lists: Int
    public var nprobe: Int?
    public var measuredRecall: Double?
    public var exact: Bool            // true when searches are exhaustive (no approximation at all)
}

/// Vector index stored inside the archive database as contiguous int8 blocks, optionally clustered (IVF-flat).
///
/// Design notes (measured in docs/PERFORMANCE.md):
///  * One SQLite row holds ~128 vectors. Per-row overhead (~1 µs/row) would otherwise dominate the dot product.
///  * Up to `exactLimit` vectors the scan is exhaustive: 100% recall, and cheap enough on modern phones to need no approximation.
///  * Beyond that, vectors are clustered and only `nprobe` lists are scanned. `nprobe` is *calibrated against exact search* on this
///    very index (`calibrate`), because recall depends on how clustered the embedder's output really is.
///  * Vectors are derived data: dropping the table and re-embedding from the archive is always possible.
public final class VectorIndex: @unchecked Sendable {
    public let archive: ArchiveDatabase
    public let space: Int
    public let dim: Int
    public let embedderID: String
    /// Exhaustive scan is used up to this many vectors. Measured on the dev box (docs/EVAL.md): 640k 256-d vectors scan in ~150 ms,
    /// 500k 384-d in ~137 ms; a decade of heavy chat is ~0.5M chunks, so exact search is adequate and has no recall risk. Scales with dimension.
    public var exactLimit: Int
    /// Approximate search is only used when calibration proved at least this recall on this very index.
    public var minApproxRecall = 0.9
    private let pdim: Int                 // dim padded to a multiple of 16 for SIMD
    private let blockCap: Int

    private let lock = NSLock()
    private var centroids: [Float] = []   // nlist * dim, unit length
    private var nlist = 0
    private var centroidsLoaded = false
    private var storedNprobe: Int?
    private var storedRecall: Double?

    public init(archive: ArchiveDatabase, space: Int, name: String, embedderID: String, dim: Int, itemKind: String = "chunk") throws {
        self.archive = archive; self.space = space; self.dim = dim; self.embedderID = embedderID
        exactLimit = max(100_000, 384_000_000 / max(dim, 1))
        pdim = (dim + 15) / 16 * 16
        blockCap = max(16, 32_768 / (dim + 16))
        try archive.write { w in
            if let existing = try w.queryOne("SELECT embedder, dim FROM vec_space WHERE space=?", [.int(space)], { ($0.text(0), Int($0.int(1))) }) {
                if existing.0 != embedderID || existing.1 != dim {
                    // A different embedder means the old vectors are meaningless in the new space: drop them (originals are untouched).
                    try w.transaction {
                        try w.run("DELETE FROM vec_block WHERE space=?", [.int(space)])
                        try w.run("DELETE FROM vec_centroid WHERE space=?", [.int(space)])
                        try w.run("UPDATE vec_space SET embedder=?, dim=?, trained_count=0, nlist=1, nprobe=NULL, measured_recall=NULL WHERE space=?", [.text(embedderID), .int(dim), .int(space)])
                        if itemKind == "chunk" { try w.run("UPDATE chunk SET embedded=0") }
                        if itemKind == "memory" { try w.run("UPDATE memory SET embedded=0") }
                    }
                }
            } else {
                try w.run("INSERT INTO vec_space(space,name,embedder,dim,item_kind) VALUES(?,?,?,?,?)", [.int(space), .text(name), .text(embedderID), .int(dim), .text(itemKind)])
            }
        }
    }

    public func count() throws -> Int { Int(try archive.read { try $0.scalarInt("SELECT COALESCE(SUM(n),0) FROM vec_block WHERE space=?", [.int(space)]) }) }

    public func quality() throws -> IndexQuality {
        let n = try count()
        let row = try archive.read { try $0.queryOne("SELECT nlist, nprobe, measured_recall FROM vec_space WHERE space=?", [.int(space)]) { (Int($0.int(0)), $0.optInt(1).map(Int.init), $0.optDouble(2)) } }
        return IndexQuality(vectors: n, lists: row?.0 ?? 1, nprobe: row?.1, measuredRecall: row?.2, exact: n <= exactLimit || (row?.0 ?? 1) <= 1 || !((row?.1 ?? Int.max) < (row?.0 ?? 1) && (row?.2 ?? 0) >= minApproxRecall))
    }

    // MARK: quantisation + kernels

    /// Symmetric per-vector int8: v ≈ scale * q. Padded with zeros to `pdim`.
    @inline(__always)
    func quantize(_ v: [Float]) -> (scale: Float, q: [Int8]) {
        var m: Float = 0
        for x in v { m = max(m, abs(x)) }
        var q = [Int8](repeating: 0, count: pdim)
        if m == 0 { return (0, q) }
        let inv = 127 / m
        for i in 0..<min(v.count, dim) { q[i] = Int8(max(-127, min(127, (v[i] * inv).rounded()))) }
        return (m / 127, q)
    }

    @inline(__always)
    static func dotInt8(_ a: UnsafePointer<Int8>, _ b: UnsafePointer<Int8>, _ n: Int) -> Int32 {
        var acc = SIMD16<Int32>(repeating: 0)
        var i = 0
        let ra = UnsafeRawPointer(a), rb = UnsafeRawPointer(b)
        while i < n {
            let x = SIMD16<Int16>(truncatingIfNeeded: ra.loadUnaligned(fromByteOffset: i, as: SIMD16<Int8>.self))
            let y = SIMD16<Int16>(truncatingIfNeeded: rb.loadUnaligned(fromByteOffset: i, as: SIMD16<Int8>.self))
            acc &+= SIMD16<Int32>(truncatingIfNeeded: x &* y)
            i += 16
        }
        return acc.wrappedSum()
    }

    // MARK: centroids

    private func loadCentroids() throws {
        lock.lock(); defer { lock.unlock() }
        if centroidsLoaded { return }
        let rows: [Data] = try archive.read { try $0.query("SELECT centroid FROM vec_centroid WHERE space=? ORDER BY list", [.int(space)]) { $0.blob(0) } }
        var flat = [Float](); flat.reserveCapacity(rows.count * dim)
        for d in rows { d.withUnsafeBytes { flat.append(contentsOf: $0.bindMemory(to: Float.self)) } }
        centroids = flat; nlist = rows.count; centroidsLoaded = true
        let st = try archive.read { try $0.queryOne("SELECT nprobe, measured_recall FROM vec_space WHERE space=?", [.int(space)]) { ($0.optInt(0).map(Int.init), $0.optDouble(1)) } }
        storedNprobe = st?.0; storedRecall = st?.1
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

    /// Adds vectors for new items. Callers replace an item by `remove` + `add` (indexing only ever adds new chunk ids).
    public func add(_ items: [(id: Int64, vector: [Float])]) throws {
        guard !items.isEmpty else { return }
        try loadCentroids()
        var byList: [Int: [(Int64, Float, [Int8])]] = [:]
        for it in items {
            precondition(it.vector.count == dim, "vector dim mismatch")
            let (scale, q) = quantize(it.vector)
            byList[nlist > 0 ? nearestLists(it.vector, count: 1)[0] : 0, default: []].append((it.id, scale, q))
        }
        try archive.write { w in
            try w.transaction {
                for (list, group) in byList { try appendToList(w, list: list, group: group) }
            }
        }
    }

    private func appendToList(_ w: SQLiteDatabase, list: Int, group: [(Int64, Float, [Int8])]) throws {
        var rest = group[...]
        var last = try w.queryOne("SELECT block, n, ids, scales, v FROM vec_block WHERE space=? AND list=? ORDER BY block DESC LIMIT 1", [.int(space), .int(list)]) {
            (Int($0.int(0)), Int($0.int(1)), $0.blob(2), $0.blob(3), $0.blob(4))
        }
        while !rest.isEmpty {
            var (block, n, ids, scales, v) = last ?? (-1, 0, Data(), Data(), Data())
            let isNew = last == nil || n >= blockCap
            if isNew { block += 1; n = 0; ids = Data(); scales = Data(); v = Data() }
            let take = min(blockCap - n, rest.count)
            for (id, sc, q) in rest.prefix(take) {
                withUnsafeBytes(of: id) { ids.append(contentsOf: $0) }
                withUnsafeBytes(of: sc) { scales.append(contentsOf: $0) }
                q.withUnsafeBufferPointer { v.append(Data(buffer: $0)) }
            }
            n += take
            if isNew {
                try w.run("INSERT INTO vec_block(space,list,block,n,ids,scales,v) VALUES(?,?,?,?,?,?,?)", [.int(space), .int(list), .int(block), .int(n), .blob(ids), .blob(scales), .blob(v)])
            } else {
                try w.run("UPDATE vec_block SET n=?, ids=?, scales=?, v=? WHERE space=? AND list=? AND block=?", [.int(n), .blob(ids), .blob(scales), .blob(v), .int(space), .int(list), .int(block)])
            }
            rest = rest.dropFirst(take)
            last = (block, n, ids, scales, v)
        }
    }

    /// Physically removes vectors (compacting the blocks that held them).
    public func remove(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        let blocks: [(Int, Int, Int)] = try archive.read { r in
            var hit: [(Int, Int, Int)] = []
            try r.forEach("SELECT list, block, n, ids FROM vec_block WHERE space=?", [.int(space)]) { row in
                let n = Int(row.int(2))
                let found = row.withBlob(3) { raw -> Bool in
                    let p = raw.bindMemory(to: Int64.self)
                    for i in 0..<min(n, p.count) where gone.contains(p[i]) { return true }
                    return false
                }
                if found { hit.append((Int(row.int(0)), Int(row.int(1)), n)) }
                return true
            }
            return hit
        }
        try archive.write { w in
            try w.transaction {
                for (list, block, _) in blocks {
                    guard let (n, idsD, scD, vD) = try w.queryOne("SELECT n, ids, scales, v FROM vec_block WHERE space=? AND list=? AND block=?", [.int(space), .int(list), .int(block)], { (Int($0.int(0)), $0.blob(1), $0.blob(2), $0.blob(3)) }) else { continue }
                    var nids = Data(), nsc = Data(), nv = Data(); var kept = 0
                    idsD.withUnsafeBytes { ib in scD.withUnsafeBytes { sb in vD.withUnsafeBytes { vb in
                        let ip = ib.bindMemory(to: Int64.self), sp = sb.bindMemory(to: Float.self)
                        for i in 0..<n where !gone.contains(ip[i]) {
                            nids.append(Data(bytes: ip.baseAddress! + i, count: 8)); nsc.append(Data(bytes: sp.baseAddress! + i, count: 4))
                            nv.append(vb.baseAddress!.advanced(by: i * pdim).assumingMemoryBound(to: UInt8.self), count: pdim); kept += 1
                        }
                    } } }
                    if kept == 0 { try w.run("DELETE FROM vec_block WHERE space=? AND list=? AND block=?", [.int(space), .int(list), .int(block)]) }
                    else { try w.run("UPDATE vec_block SET n=?, ids=?, scales=?, v=? WHERE space=? AND list=? AND block=?", [.int(kept), .blob(nids), .blob(nsc), .blob(nv), .int(space), .int(list), .int(block)]) }
                }
            }
        }
    }

    /// Applies queued erasures (see `ArchiveStore.erase*`): no embedding of erased text stays on disk.
    @discardableResult
    public func applyPurges() throws -> Int {
        let ids: [Int64] = try archive.read { try $0.query("SELECT item_id FROM vec_purge WHERE space=?", [.int(space)]) { $0.int(0) } }
        guard !ids.isEmpty else { return 0 }
        try remove(ids: ids)
        try archive.write { try $0.run("DELETE FROM vec_purge WHERE space=?", [.int(space)]) }
        return ids.count
    }

    /// The stored (dequantised) vector for one item. Scans blocks: intended for small spaces (memories), not the chunk space.
    public func vector(forItem id: Int64) throws -> [Float]? {
        var out: [Float]?
        try archive.read { r in
            try r.forEach("SELECT n, ids, scales, v FROM vec_block WHERE space=?", [.int(space)]) { row in
                let n = Int(row.int(0))
                let idx: Int? = row.withBlob(1) { raw in let p = raw.bindMemory(to: Int64.self); for i in 0..<min(n, p.count) where p[i] == id { return i }; return nil }
                guard let i = idx else { return true }
                let scale = row.withBlob(2) { $0.bindMemory(to: Float.self)[i] }
                row.withBlob(3) { raw in
                    let p = raw.bindMemory(to: Int8.self)
                    var v = (0..<dim).map { Float(p[i * pdim + $0]) * scale }
                    VectorMath.normalize(&v); out = v
                }
                return false
            }
        }
        return out
    }

    // MARK: search

    /// Nearest neighbours. Exhaustive while the index is small; otherwise `nprobe` (calibrated) clusters are scanned.
    public func search(_ query: [Float], k: Int, nprobe: Int? = nil, accept: ((Int64) -> Bool)? = nil) throws -> [VectorHit] {
        precondition(query.count == dim)
        try loadCentroids()
        let total = try count()
        if nlist <= 1 || total <= exactLimit { return try scan(lists: nil, query: query, k: k, accept: accept) }
        // Beyond the exact limit: approximate only when calibration proved it is good enough here (or the caller insists); otherwise stay exact and correct.
        let proven = (storedNprobe.map { $0 < nlist } ?? false) && (storedRecall ?? 0) >= minApproxRecall
        if nprobe == nil && !proven { return try scan(lists: nil, query: query, k: k, accept: accept) }
        let probes = nprobe ?? storedNprobe ?? max(8, nlist / 8)
        return try scan(lists: nearestLists(query, count: min(nlist, probes)), query: query, k: k, accept: accept)
    }

    public func searchExact(_ query: [Float], k: Int, accept: ((Int64) -> Bool)? = nil) throws -> [VectorHit] {
        try scan(lists: nil, query: query, k: k, accept: accept)
    }

    /// Search with an explicit probe count even on a small index (used by calibration and tests).
    public func searchIVF(_ query: [Float], k: Int, nprobe: Int) throws -> [VectorHit] {
        try loadCentroids()
        return try scan(lists: nearestLists(query, count: min(max(nlist, 1), nprobe)), query: query, k: k, accept: nil)
    }

    private func scan(lists: [Int]?, query: [Float], k: Int, accept: ((Int64) -> Bool)?) throws -> [VectorHit] {
        let (qs, qq) = quantize(query)
        var heap = TopK(capacity: k)
        let n16 = pdim
        try qq.withUnsafeBufferPointer { qp in
            func consume(_ row: Row) {
                let n = Int(row.int(0))
                row.withBlob(1) { idsRaw in row.withBlob(2) { scRaw in row.withBlob(3) { vRaw in
                    guard idsRaw.count >= n * 8, scRaw.count >= n * 4, vRaw.count >= n * n16 else { return }
                    let ids = idsRaw.bindMemory(to: Int64.self), sc = scRaw.bindMemory(to: Float.self)
                    let vp = vRaw.bindMemory(to: Int8.self).baseAddress!
                    for i in 0..<n {
                        let s = Float(Self.dotInt8(qp.baseAddress!, vp + i * n16, n16)) * sc[i] * qs
                        if heap.wouldAccept(s), accept?(ids[i]) ?? true { heap.push(VectorHit(id: ids[i], score: s)) }
                    }
                } } }
            }
            if let lists {
                for l in lists { try archive.read { try $0.forEach("SELECT n, ids, scales, v FROM vec_block WHERE space=? AND list=?", [.int(space), .int(l)]) { consume($0); return true } } }
            } else {
                try archive.read { try $0.forEach("SELECT n, ids, scales, v FROM vec_block WHERE space=?", [.int(space)]) { consume($0); return true } }
            }
        }
        return heap.sortedDescending()
    }

    // MARK: clustering

    public static func recommendedLists(for n: Int) -> Int { max(1, min(4096, Int(4 * Double(n).squareRoot()))) }

    public func needsTraining() throws -> Bool {
        let n = try count()
        let trained = Int(try archive.read { try $0.scalarInt("SELECT trained_count FROM vec_space WHERE space=?", [.int(space)]) })
        return n > exactLimit && (trained == 0 || n >= trained * 3)
    }

    /// Spherical k-means on a sample, then a bounded-memory rebuild of all blocks grouped by nearest centroid.
    public func train(lists requestedLists: Int? = nil, sampleSize: Int = 40_000, iterations: Int = 8, shouldContinue: () -> Bool = { true }) throws {
        let n = try count()
        guard n >= 256 else { return }
        let k = requestedLists ?? Self.recommendedLists(for: n)
        let d = dim
        var sample = [Float](); sample.reserveCapacity(min(n, sampleSize) * d)
        var rows = 0
        let stride = max(1, n / sampleSize)
        var seen = 0
        try archive.read { r in
            try r.forEach("SELECT n, scales, v FROM vec_block WHERE space=?", [.int(space)]) { row in
                let cnt = Int(row.int(0))
                row.withBlob(1) { scRaw in row.withBlob(2) { vRaw in
                    let sc = scRaw.bindMemory(to: Float.self), vp = vRaw.bindMemory(to: Int8.self)
                    for i in 0..<cnt {
                        defer { seen += 1 }
                        if seen % stride != 0 || rows >= sampleSize { continue }
                        var norm: Float = 0
                        let start = sample.count
                        for j in 0..<d { let x = Float(vp[i * pdim + j]) * sc[i]; sample.append(x); norm += x * x }
                        if norm > 0 { let inv = 1 / norm.squareRoot(); for j in start..<(start + d) { sample[j] *= inv } }
                        rows += 1
                    }
                } }
                return true
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
        try rebuild(centroids: cents, lists: k, total: n, shouldContinue: shouldContinue)
    }

    /// Streams the old blocks into per-list buffers (memory capped at ~24 MB), flushing full blocks into a staging table,
    /// then swaps the staging rows in atomically. Searches keep working on the old blocks until the swap.
    private func rebuild(centroids cents: [Float], lists k: Int, total: Int, shouldContinue: () -> Bool) throws {
        lock.lock(); centroids = cents; nlist = k; centroidsLoaded = true; lock.unlock()
        try archive.write { w in
            try w.exec("DROP TABLE IF EXISTS temp.vec_stage")
            try w.exec("CREATE TEMP TABLE vec_stage(list INTEGER, block INTEGER, n INTEGER, ids BLOB, scales BLOB, v BLOB, PRIMARY KEY(list, block)) WITHOUT ROWID")
        }
        struct Buf { var ids = Data(); var sc = Data(); var v = Data(); var n = 0 }
        var bufs: [Int: Buf] = [:]
        var nextBlock: [Int: Int] = [:]
        var bufBytes = 0
        let cap = blockCap
        let limit = 24 * 1024 * 1024
        func flush(_ list: Int, _ b: Buf, _ w: SQLiteDatabase) throws {
            let blk = nextBlock[list, default: 0]; nextBlock[list] = blk + 1
            try w.run("INSERT INTO temp.vec_stage(list,block,n,ids,scales,v) VALUES(?,?,?,?,?,?)", [.int(list), .int(blk), .int(b.n), .blob(b.ids), .blob(b.sc), .blob(b.v)])
        }
        var cancelled = false
        try archive.write { w in
            try w.transaction {
                // reading and writing on the single writer connection keeps this one consistent snapshot of the old blocks
                try w.forEach("SELECT n, ids, scales, v FROM vec_block WHERE space=? ORDER BY list, block", [.int(space)]) { row in
                    if !shouldContinue() { cancelled = true; return false }
                    let cnt = Int(row.int(0))
                    row.withBlob(1) { idRaw in row.withBlob(2) { scRaw in row.withBlob(3) { vRaw in
                        let ids = idRaw.bindMemory(to: Int64.self), sc = scRaw.bindMemory(to: Float.self), vp = vRaw.bindMemory(to: Int8.self)
                        var f = [Float](repeating: 0, count: dim)
                        for i in 0..<cnt {
                            var norm: Float = 0
                            for j in 0..<dim { f[j] = Float(vp[i * pdim + j]) * sc[i]; norm += f[j] * f[j] }
                            if norm > 0 { let inv = 1 / norm.squareRoot(); for j in 0..<dim { f[j] *= inv } }
                            let target = nearestLists(f, count: 1)[0]
                            var b = bufs[target] ?? Buf()
                            withUnsafeBytes(of: ids[i]) { b.ids.append(contentsOf: $0) }
                            withUnsafeBytes(of: sc[i]) { b.sc.append(contentsOf: $0) }
                            b.v.append(Data(bytes: vp.baseAddress! + i * pdim, count: pdim)); b.n += 1
                            bufBytes += pdim + 12
                            if b.n >= cap { try? flush(target, b, w); bufBytes -= b.n * (pdim + 12); b = Buf() }
                            bufs[target] = b
                        }
                        if bufBytes > limit {   // memory cap: flush partially filled buffers, largest first
                            for (l, b) in bufs.sorted(by: { $0.value.n > $1.value.n }) where b.n > 0 && bufBytes > limit / 2 {
                                try? flush(l, b, w); bufBytes -= b.n * (pdim + 12); bufs[l] = Buf()
                            }
                        }
                    } } }
                    return true
                }
                if cancelled { throw CancellationError() }
                for (l, b) in bufs where b.n > 0 { try flush(l, b, w) }
                try w.run("DELETE FROM vec_block WHERE space=?", [.int(space)])
                try w.run("INSERT INTO vec_block(space,list,block,n,ids,scales,v) SELECT ?, list, block, n, ids, scales, v FROM temp.vec_stage", [.int(space)])
                try w.exec("DROP TABLE temp.vec_stage")
                try w.run("DELETE FROM vec_centroid WHERE space=?", [.int(space)])
                for l in 0..<k {
                    let blob = cents[(l * dim)..<((l + 1) * dim)].withUnsafeBufferPointer { Data(buffer: $0) }
                    try w.run("INSERT INTO vec_centroid(space,list,centroid,count) VALUES(?,?,?,0)", [.int(space), .int(l), .blob(blob)])
                }
                try w.run("UPDATE vec_space SET trained_count=?, nlist=?, nprobe=NULL, measured_recall=NULL WHERE space=?", [.int(total), .int(k), .int(space)])
            }
        }
    }

    /// Finds the smallest `nprobe` whose recall@k against exact search on this index reaches `target`, and stores it.
    /// Uses stored vectors as queries (excluding themselves). Reports honestly when no probe count below a full scan gets there.
    @discardableResult
    public func calibrate(target: Double = 0.92, k: Int = 10, queries: Int = 48) throws -> IndexQuality {
        try loadCentroids()
        guard nlist > 1 else { return try quality() }
        var qvs: [[Float]] = []
        let n = try count()
        let stride = max(1, n / queries)
        var seen = 0
        try archive.read { r in
            try r.forEach("SELECT n, scales, v FROM vec_block WHERE space=?", [.int(space)]) { row in
                let cnt = Int(row.int(0))
                row.withBlob(1) { scRaw in row.withBlob(2) { vRaw in
                    let sc = scRaw.bindMemory(to: Float.self), vp = vRaw.bindMemory(to: Int8.self)
                    for i in 0..<cnt { defer { seen += 1 }
                        if seen % stride == 0, qvs.count < queries { var f = (0..<dim).map { Float(vp[i * pdim + $0]) * sc[i] }; VectorMath.normalize(&f); qvs.append(f) } }
                } }
                return qvs.count < queries
            }
        }
        let truth = try qvs.map { Set(try searchExact($0, k: k + 1).dropFirst().map(\.id)) }
        var chosen: Int?, recall = 0.0
        var probe = 4
        while probe <= nlist {
            var hit = 0.0
            for (q, t) in zip(qvs, truth) {
                let approx = Set(try searchIVF(q, k: k + 1, nprobe: probe).dropFirst().map(\.id))   // top hit is the query vector itself
                hit += Double(approx.intersection(t).count) / Double(max(1, t.count))
            }
            recall = hit / Double(max(1, qvs.count))
            if recall >= target { chosen = probe; break }
            if probe == nlist { break }
            probe = min(nlist, probe * 2)
        }
        let used = chosen ?? nlist
        try archive.write { try $0.run("UPDATE vec_space SET nprobe=?, measured_recall=? WHERE space=?", [.int(used), .double(recall), .int(space)]) }
        lock.lock(); storedNprobe = used; storedRecall = recall; lock.unlock()
        return try quality()
    }
}

/// Bounded min-heap keeping the best `capacity` hits.
struct TopK {
    let capacity: Int
    private var items: [VectorHit] = []
    init(capacity: Int) { self.capacity = max(1, capacity); items.reserveCapacity(capacity + 1) }
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
