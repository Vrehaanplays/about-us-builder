import Foundation
import PersonalAICore

/// Vector-search study on REAL embeddings (MiniLM-L6-v2 over ~30k real English passages from Python docstrings/docs; see docs/EVAL.md).
/// Establishes: int8 exact vs float ground truth, IVF recall@10 vs nprobe at several sizes, latency and memory.
/// A second, clearly-labelled LATENCY-ONLY stage extends the vector count with synthetic vectors to measure exact-scan cost at archive scale.
func runVectorBench(file: String, dim: Int, queriesN: Int, scaleSizes: [Int], out: String?) throws {
    let raw = try Data(contentsOf: URL(fileURLWithPath: file))
    let n = raw.count / (dim * 4)
    var all = [[Float]](); all.reserveCapacity(n)
    raw.withUnsafeBytes { p in
        let f = p.bindMemory(to: Float.self)
        for i in 0..<n { all.append(Array(f[(i * dim)..<((i + 1) * dim)])) }
    }
    print("loaded \(n) real vectors of dim \(dim)")
    let queries = Array(all.suffix(queriesN)); let corpus = Array(all.dropLast(queriesN))
    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    var report: [[String: Any]] = []
    let sizes = [2_000, 5_000, 10_000, 20_000, corpus.count].filter { $0 <= corpus.count }
    for size in Array(Set(sizes)).sorted() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vecbench-\(getpid())-\(size)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ArchiveDatabase(path: dir.appendingPathComponent("v.sqlite").path, profile: .phone)
        let idx = try VectorIndex(archive: db, space: 1, name: "chunks", embedderID: "minilm", dim: dim)
        idx.exactLimit = 100        // force the IVF path to be available so we can compare it
        let sub = Array(corpus.prefix(size))
        var t = now()
        for b in stride(from: 0, to: size, by: 2000) { try idx.add((b..<min(b + 2000, size)).map { (Int64($0), sub[$0]) }) }
        let addSecs = now() - t
        // float ground truth
        t = now()
        let truth: [Set<Int64>] = queries.map { q in
            var best: [(Int, Float)] = []
            for (i, v) in sub.enumerated() { best.append((i, VectorMath.dot(q, v))) }
            best.sort { $0.1 > $1.1 }
            return Set(best.prefix(10).map { Int64($0.0) })
        }
        let truthSecs = now() - t
        t = now()
        var exactRecall = 0.0
        for (qi, q) in queries.enumerated() { exactRecall += Double(Set(try idx.searchExact(q, k: 10).map(\.id)).intersection(truth[qi]).count) / 10 }
        let exactMs = (now() - t) * 1000 / Double(queries.count)
        var stage: [String: Any] = ["vectors": size, "dim": dim, "add_seconds": addSecs, "float_bruteforce_ms_per_query": truthSecs * 1000 / Double(queries.count),
                                    "int8_exact_recall_at_10_vs_float": exactRecall / Double(queries.count), "int8_exact_ms_per_query": exactMs,
                                    "int8_bytes": size * (dim + 16)]
        print(String(format: "n=%6d  int8-exact recall@10 vs float = %.4f, %.2f ms/query (float brute force %.2f ms)", size, exactRecall / Double(queries.count), exactMs, truthSecs * 1000 / Double(queries.count)))
        if size >= 2_000 {
            let lists = max(8, Int(Double(size).squareRoot() * 1.5))
            t = now(); try idx.train(lists: lists); stage["train_seconds"] = now() - t; stage["lists"] = lists
            var sweep: [[String: Any]] = []
            for probe in [1, 2, 4, 8, 16, 32, 64] where probe <= lists {
                var rec = 0.0
                t = now()
                for (qi, q) in queries.enumerated() { rec += Double(Set(try idx.search(q, k: 10, nprobe: probe).map(\.id)).intersection(truth[qi]).count) / 10 }
                let ms = (now() - t) * 1000 / Double(queries.count)
                sweep.append(["nprobe": probe, "recall_at_10": rec / Double(queries.count), "ms_per_query": ms])
                print(String(format: "      lists=%d nprobe=%2d  recall@10=%.3f  %.2f ms/query (exact int8 %.2f ms)", lists, probe, rec / Double(queries.count), ms, exactMs))
            }
            stage["ivf_sweep"] = sweep
        }
        report.append(stage)
    }

    // ---- latency-only: exact scan at archive scale, synthetic vectors (content irrelevant to scan cost) ----
    var scale: [[String: Any]] = []
    for size in scaleSizes {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vecscale-\(getpid())-\(size)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ArchiveDatabase(path: dir.appendingPathComponent("v.sqlite").path, profile: .phone)
        let idx = try VectorIndex(archive: db, space: 1, name: "chunks", embedderID: "synthetic", dim: dim)
        idx.exactLimit = Int.max
        var rng = SystemRandomNumberGenerator()
        var t = now()
        for b in stride(from: 0, to: size, by: 4000) {
            let m = min(4000, size - b)
            // each synthetic vector = a real vector plus noise, so the int8 distribution is realistic
            let batch: [(id: Int64, vector: [Float])] = (0..<m).map { j in
                var v = all[Int.random(in: 0..<all.count, using: &rng)]
                for d in 0..<dim { v[d] += Float.random(in: -0.05...0.05, using: &rng) }
                VectorMath.normalize(&v)
                return (Int64(b + j), v)
            }
            try idx.add(batch)
        }
        let addSecs = now() - t
        var lat: [Double] = []
        for q in queries.prefix(20) { t = now(); _ = try idx.searchExact(q, k: 10); lat.append((now() - t) * 1000) }
        lat.sort()
        let bytes = size * (dim + 16)
        scale.append(["vectors": size, "dim": dim, "add_seconds": addSecs, "exact_scan_ms_p50": lat[lat.count / 2], "exact_scan_ms_max": lat.last!, "int8_bytes": bytes, "rss_peak_mb": rssMB(),
                      "note": "latency-only: vectors are real MiniLM vectors + noise, NOT a retrieval-quality measurement"])
        print(String(format: "scale n=%8d  exact int8 scan p50 %.1f ms (max %.1f)  vectors %.0f MB  add %.0fs  rss peak %.0f MB", size, lat[lat.count / 2], lat.last!, Double(bytes) / 1e6, addSecs, rssMB()))
    }
    if let out {
        let full: [String: Any] = ["host": hostInfo(), "embedder": "all-MiniLM-L6-v2 (ONNX, CPU) over real passages", "corpus": "Python docstrings/docs, not chat data", "real_stages": report, "latency_only_stages": scale]
        try JSONSerialization.data(withJSONObject: full, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }
}
