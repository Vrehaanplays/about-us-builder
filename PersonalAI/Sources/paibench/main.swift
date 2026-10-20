import Foundation
import PersonalAICore

// paibench: repeatable archive-scale benchmark for the platform-neutral core.
// IMPORTANT: numbers from this tool are measurements of THIS machine (see "host" in the JSON), not of an iPhone.
// The same binary logic runs inside the app's Benchmarks screen (App/) to produce device numbers.

struct Args {
    var sizes: [Int] = [100_000, 500_000]
    var dir = FileManager.default.temporaryDirectory.appendingPathComponent("paibench-\(getpid())").path
    var out: String?
    var needles = 150
    var queries = 150
    var keep = false
    var embedDim = 256
}

func parse() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let k = it.next() {
        switch k {
        case "--sizes": a.sizes = (it.next() ?? "").split(separator: ",").compactMap { Int($0) }
        case "--dir": a.dir = it.next() ?? a.dir
        case "--out": a.out = it.next()
        case "--needles": a.needles = Int(it.next() ?? "") ?? a.needles
        case "--queries": a.queries = Int(it.next() ?? "") ?? a.queries
        case "--keep": a.keep = true
        case "--dim": a.embedDim = Int(it.next() ?? "") ?? a.embedDim
        default: print("unknown arg \(k)")
        }
    }
    return a
}

func rssMB() -> Double {
    guard let s = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return 0 }
    for line in s.split(separator: "\n") where line.hasPrefix("VmHWM:") {
        return (Double(line.split(separator: " ").dropFirst().first ?? "0") ?? 0) / 1024
    }
    return 0
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))]
}

func hostInfo() -> [String: Any] {
    var cpu = "unknown"
    if let s = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8), let l = s.split(separator: "\n").first(where: { $0.hasPrefix("model name") }) { cpu = String(l.split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces) }
    return ["cpu": cpu, "cores": ProcessInfo.processInfo.activeProcessorCount, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "note": "Linux x86_64 dev box. NOT an iPhone. Use for relative scaling behaviour only."]
}

let args = parse()
try FileManager.default.createDirectory(atPath: args.dir, withIntermediateDirectories: true)
let dbPath = args.dir + "/archive.sqlite"
let db = try ArchiveDatabase(path: dbPath, profile: .phone)      // phone-sized caches on purpose: measure what the phone profile can do
let store = ArchiveStore(db: db)
let embedder = HashingEmbedder(dim: args.embedDim)
let vectors = try VectorIndex(archive: db, space: 1, name: "chunks", embedderID: embedder.id, dim: embedder.dim)
let chunker = Chunker(store: store)
let pipeline = IndexingPipeline(archive: store, chunker: chunker, vectors: vectors, embedder: embedder)
pipeline.embedBatch = 512
let memory = MemoryStore(archive: store)
let retriever = HybridRetriever(archive: store, vectors: vectors, embedder: embedder, memory: memory, entities: EntityStore(db: db))

var report: [[String: Any]] = []
var totalMessages = 0
var allNeedles: [SyntheticArchive.Needle] = []
var stageSeed: UInt64 = 100

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

for target in args.sizes {
    let add = target - totalMessages
    guard add > 0 else { continue }
    stageSeed += 1
    var stage: [String: Any] = ["target_messages": target]
    print("== stage \(target): generating \(add) messages")

    var t = now()
    let needles = try SyntheticArchive(seed: stageSeed).generate(into: store, messages: add, years: 10, needles: args.needles / args.sizes.count + 1) { n in
        if n % 200_000 < 2000 { FileHandle.standardError.write(Data("  generated \(n)\r".utf8)) }
    }
    allNeedles += needles
    let insertSecs = now() - t
    totalMessages = try store.stats().messages
    stage["insert_seconds"] = insertSecs; stage["insert_msgs_per_sec"] = Double(add) / insertSecs
    print(String(format: "   insert: %.1fs (%.0f msg/s)", insertSecs, Double(add) / insertSecs))

    t = now()
    let chunks = try pipeline.chunkStep(conversations: Int.max)
    stage["chunk_seconds"] = now() - t; stage["chunks_created"] = chunks
    print(String(format: "   chunking: %d chunks in %.1fs", chunks, now() - t))

    t = now()
    var embedded = 0
    while true { let n = try await pipeline.embedStep(); if n == 0 { break }; embedded += n }
    stage["embed_seconds"] = now() - t; stage["embed_chunks_per_sec"] = Double(embedded) / max(0.001, now() - t)
    print(String(format: "   embedding (hashing embedder, CPU): %d chunks in %.1fs", embedded, now() - t))

    t = now()
    if try vectors.needsTraining() { try vectors.train() }
    stage["ivf_train_seconds"] = now() - t
    print(String(format: "   IVF train+reassign: %.1fs", now() - t))

    t = now()
    _ = try db.write { try $0.exec("ANALYZE; PRAGMA wal_checkpoint(TRUNCATE);") }
    stage["analyze_seconds"] = now() - t

    let st = try store.stats()
    stage["messages"] = st.messages; stage["conversations"] = st.conversations; stage["chunks"] = st.chunks; stage["vectors"] = st.vectors
    stage["db_bytes"] = st.dbBytes; stage["db_bytes_per_message"] = Double(st.dbBytes) / Double(max(1, st.messages))
    let textBytes = try db.read { try $0.scalarInt("SELECT COALESCE(SUM(LENGTH(text)),0) FROM (SELECT text FROM message ORDER BY id DESC LIMIT 200000)") }
    stage["avg_text_bytes_per_message_sample"] = Double(textBytes) / Double(min(200_000, st.messages))
    print(String(format: "   db size: %.2f GB (%.0f B/msg), vectors %d, rss peak %.0f MB", Double(st.dbBytes) / 1e9, Double(st.dbBytes) / Double(st.messages), st.vectors, rssMB()))

    // --- query phase: planted needles ---
    let sample = Array(allNeedles.shuffled().prefix(args.queries))
    var lat: [Double] = [], latLex: [Double] = [], latVec: [Double] = []
    var hit1 = 0, hit3 = 0
    for n in sample {
        let t0 = now()
        let r = try await retriever.retrieve(n.query)
        lat.append((now() - t0) * 1000)
        let ranks = r.spans.enumerated().filter { $0.element.messages.contains { $0.text == n.messageText } }.map { $0.offset }
        if let m = ranks.min() { if m == 0 { hit1 += 1 }; if m < 3 { hit3 += 1 } }
        let t1 = now()
        _ = try retriever.lexical.searchMessages(terms: QueryAnalyzer().analyze(n.query).terms, limit: 40)
        latLex.append((now() - t1) * 1000)
        let qv = try await embedder.embed([n.query], kind: .query)[0]
        let t2 = now()
        _ = try vectors.search(qv, k: 40)
        latVec.append((now() - t2) * 1000)
    }
    stage["needle_queries"] = sample.count
    stage["needle_hit_at_1"] = Double(hit1) / Double(max(1, sample.count)); stage["needle_hit_at_3"] = Double(hit3) / Double(max(1, sample.count))
    stage["retrieve_ms_p50"] = percentile(lat, 0.5); stage["retrieve_ms_p95"] = percentile(lat, 0.95)
    stage["lexical_ms_p50"] = percentile(latLex, 0.5); stage["lexical_ms_p95"] = percentile(latLex, 0.95)
    stage["vector_ms_p50"] = percentile(latVec, 0.5); stage["vector_ms_p95"] = percentile(latVec, 0.95)
    print(String(format: "   needle hit@1 %.2f hit@3 %.2f | retrieve p50 %.1f ms p95 %.1f ms | lexical p50 %.1f | vector p50 %.1f ms",
                 Double(hit1) / Double(max(1, sample.count)), Double(hit3) / Double(max(1, sample.count)), percentile(lat, 0.5), percentile(lat, 0.95), percentile(latLex, 0.5), percentile(latVec, 0.5)))

    // --- vector recall vs exact (IVF quality at this scale) ---
    if st.vectors >= 1000 {
        var rec = 0.0, cnt = 0
        for n in sample.prefix(25) {
            let qv = try await embedder.embed([n.query], kind: .query)[0]
            let ex = Set(try vectors.searchExact(qv, k: 10).map(\.id)), ap = Set(try vectors.search(qv, k: 10).map(\.id))
            rec += Double(ex.intersection(ap).count) / Double(max(1, ex.count)); cnt += 1
        }
        stage["ivf_recall_at_10"] = rec / Double(max(1, cnt))
        let t3 = now(); for n in sample.prefix(10) { _ = try vectors.searchExact(try await embedder.embed([n.query], kind: .query)[0], k: 10) }
        stage["exact_scan_ms_avg"] = (now() - t3) * 100
        print(String(format: "   IVF recall@10 %.3f | exact scan avg %.0f ms", rec / Double(max(1, cnt)), (now() - t3) * 100))
    }

    // --- reads while the indexer is writing (does background work hurt the chat?) ---
    let writer = Task.detached {
        for i in 0..<40 {
            if Task.isCancelled { break }
            _ = try? await SyntheticArchive(seed: 9000 + UInt64(i)).generate(into: store, messages: 400, years: 1)
        }
    }
    var latBusy: [Double] = []
    for n in sample.prefix(40) { let t0 = now(); _ = try await retriever.retrieve(n.query); latBusy.append((now() - t0) * 1000) }
    writer.cancel(); _ = await writer.result
    stage["retrieve_ms_p50_during_writes"] = percentile(latBusy, 0.5); stage["retrieve_ms_p95_during_writes"] = percentile(latBusy, 0.95)
    print(String(format: "   retrieve under concurrent writes: p50 %.1f ms p95 %.1f ms", percentile(latBusy, 0.5), percentile(latBusy, 0.95)))
    stage["rss_peak_mb"] = rssMB()
    totalMessages = try store.stats().messages
    report.append(stage)
}

let full: [String: Any] = ["host": hostInfo(), "embedder": embedder.id, "profile": "ArchiveDatabase.Profile.phone", "stages": report, "generated_at": ISO8601DateFormatter().string(from: Date())]
if let out = args.out {
    let data = try JSONSerialization.data(withJSONObject: full, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}
if !args.keep { try? FileManager.default.removeItem(atPath: args.dir) }
