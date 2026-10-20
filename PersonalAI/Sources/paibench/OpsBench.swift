import Foundation
import PersonalAICore
#if canImport(Glibc)
import Glibc
#endif

/// Operational benchmarks beyond raw search: incremental import, duplicate import, assets (photo/file metadata), deletion,
/// full index rebuild, and recovery after the indexer is killed mid-write (a real SIGKILL of a child process).
/// Linux x86 dev box numbers on synthetic text; see docs/PERFORMANCE.md for what they do and do not mean.
func runOpsBench(baseMessages: Int, incrementalMessages: Int, assets: Int, dir: String, out: String?) async throws {
    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    try? FileManager.default.removeItem(atPath: dir)
    let svc = try PersonalAIServices(directory: URL(fileURLWithPath: dir), embedder: HashingEmbedder(dim: 256))
    var rep: [String: Any] = ["host": hostInfo(), "baseMessages": baseMessages]
    func log(_ s: String) { print(s); fflush(nil) }

    // 0. base archive, indexed
    var t = now()
    _ = try SyntheticArchive(seed: 77).generate(into: svc.archive, messages: baseMessages, years: 10)
    rep["base_insert_seconds"] = now() - t
    t = now(); _ = try svc.pipeline.chunkStep(conversations: Int.max)
    while try await svc.pipeline.embedStep() > 0 {}
    let baseIndex = now() - t
    rep["base_index_seconds"] = baseIndex
    let st0 = try svc.archive.stats()
    rep["base_chunks"] = st0.chunks; rep["base_db_bytes"] = st0.dbBytes
    log("base: \(st0.messages) messages, \(st0.chunks) chunks, index \(String(format: "%.1f", baseIndex)) s, db \(st0.dbBytes / 1_000_000) MB")

    // 1. incremental import through the real importer (ChatGPT JSON), then duplicate re-import
    let scratch = try PersonalAIServices(directory: URL(fileURLWithPath: dir + "-scratch"), embedder: HashingEmbedder(dim: 256))
    defer { try? FileManager.default.removeItem(atPath: dir + "-scratch") }
    _ = try SyntheticArchive(seed: 78).generate(into: scratch.archive, messages: incrementalMessages, years: 1)
    var convs: [EvalCorpus.Conv] = []
    var off = 0
    while true {
        let cs = try scratch.archive.conversations(limit: 500, offset: off); if cs.isEmpty { break }; off += cs.count
        for c in cs {
            let ms = try scratch.archive.messages(conversationID: c.id, seqFrom: 0, seqTo: 100_000)
            let start = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: c.createdAt))
            convs.append(EvalCorpus.Conv(name: "inc-\(c.id)", title: c.title, start: start, lines: ms.map { EvalCorpus.Line(role: $0.role, text: $0.text, key: nil) }))
        }
    }
    let exportDir = URL(fileURLWithPath: dir + "-export"); try? FileManager.default.removeItem(at: exportDir)
    try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: exportDir) }
    try EvalSuite.chatGPTExport(EvalCorpus(conversations: convs, cases: [])).write(to: exportDir.appendingPathComponent("conversations.json"))
    let jsonBytes = (try? FileManager.default.attributesOfItem(atPath: exportDir.appendingPathComponent("conversations.json").path)[.size] as? Int) ?? 0
    t = now(); let r1 = try svc.importer.importItem(at: exportDir); let impSecs = now() - t
    rep["incremental_import"] = ["messages_inserted": r1.messagesInserted, "seconds": impSecs, "msgs_per_sec": Double(r1.messagesInserted) / impSecs, "json_mb": Double(jsonBytes) / 1e6]
    log("incremental import into \(baseMessages) existing: \(r1.messagesInserted) msgs in \(String(format: "%.2f", impSecs)) s (\(Int(Double(r1.messagesInserted) / impSecs)) msg/s)")
    t = now(); let r2 = try svc.importer.importItem(at: exportDir); let dupSecs = now() - t
    rep["duplicate_import"] = ["messages_inserted": r2.messagesInserted, "duplicates": r2.messagesDuplicate, "seconds": dupSecs]
    log("duplicate import: inserted \(r2.messagesInserted), skipped \(r2.messagesDuplicate) in \(String(format: "%.2f", dupSecs)) s")
    t = now(); _ = try svc.pipeline.chunkStep(conversations: Int.max); var emb = 0
    while true { let n = try await svc.pipeline.embedStep(); if n == 0 { break }; emb += n }
    rep["incremental_index_seconds"] = now() - t; rep["incremental_chunks_embedded"] = emb
    log("incremental index: \(emb) new chunks in \(String(format: "%.2f", now() - t)) s (only new work was done)")

    // 2. photo / file metadata
    let asrc = try svc.archive.upsertSource(kind: "photos", name: "bench", externalID: "bench-photos")
    t = now()
    let labels = ["beach", "dog", "receipt", "whiteboard", "passport", "sunset", "invoice", "kitchen", "garden", "train ticket"]
    var batch: [NewAsset] = []
    for i in 0..<assets {
        var a = NewAsset(kind: i % 3 == 0 ? "document" : "photo", externalID: "id-\(i)", name: "IMG_\(i).jpg", createdAt: 1_500_000_000 + Double(i) * 3000)
        a.labels = labels[i % labels.count]; a.text = i % 5 == 0 ? "total \(i) euro invoice number \(i * 7)" : nil; a.latitude = 38.7; a.longitude = -9.1
        batch.append(a)
    }
    try svc.assets.upsertMany(sourceID: asrc, batch)
    let assetInsert = now() - t
    var lat: [Double] = []
    for q in ["invoice", "passport", "beach", "receipt euro", "whiteboard"] { let t0 = now(); _ = try svc.retriever.lexical.searchAssets(terms: [q], limit: 20); lat.append((now() - t0) * 1000) }
    rep["assets"] = ["count": assets, "insert_seconds": assetInsert, "inserts_per_sec": Double(assets) / assetInsert, "search_ms_max": lat.max() ?? 0]
    log("assets: \(assets) rows in \(String(format: "%.2f", assetInsert)) s, search max \(String(format: "%.1f", lat.max() ?? 0)) ms")

    // 3. deletion with vector purge
    let victims = try svc.archive.conversations(limit: 200)
    t = now(); var removedMsgs = 0, removedVecs = 0
    for c in victims { let e = try svc.archive.eraseConversation(c.id); removedMsgs += e.messages; removedVecs += e.vectors }
    let eraseSecs = now() - t
    t = now(); let purged = try svc.vectors.applyPurges(); let purgeSecs = now() - t
    rep["delete_200_conversations"] = ["messages": removedMsgs, "vectors_queued": removedVecs, "erase_seconds": eraseSecs, "purged": purged, "purge_seconds": purgeSecs]
    log("deleted 200 conversations (\(removedMsgs) msgs): \(String(format: "%.2f", eraseSecs)) s + purge \(purged) vectors \(String(format: "%.2f", purgeSecs)) s")

    // 4. interruption: SIGKILL a child indexer mid-embedding, then verify and resume
    try svc.rebuildDerived()                       // everything needs re-indexing
    t = now(); _ = try svc.pipeline.chunkStep(conversations: Int.max); let rechunk = now() - t
    let chunksTotal = try svc.archive.stats().chunks
    let exe = CommandLine.arguments[0]
    let child = Process()
    child.executableURL = URL(fileURLWithPath: exe)
    child.arguments = ["--child-embed", dir]
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run()
    // wait until it has embedded a meaningful fraction, then kill -9
    var killedAt = 0
    let svc2 = try PersonalAIServices(directory: URL(fileURLWithPath: dir), embedder: HashingEmbedder(dim: 256))
    while child.isRunning {
        try await Task.sleep(nanoseconds: 100_000_000)
        killedAt = chunksTotal - (try svc2.archive.stats().chunksPending)
        if killedAt >= chunksTotal / 3 { break }
    }
    let wasRunning = child.isRunning
    if wasRunning { kill(child.processIdentifier, SIGKILL) }
    child.waitUntilExit()
    let integrity = try svc.db.read { try $0.queryOne("PRAGMA integrity_check") { $0.text(0) } } ?? "?"
    let st1 = try svc.archive.stats()
    let consistent = st1.vectors + st1.chunksPending == st1.chunks
    t = now(); while try await svc.pipeline.embedStep() > 0 {}; let resume = now() - t
    let st2 = try svc.archive.stats()
    rep["kill9_recovery"] = ["child_killed_while_running": wasRunning, "chunks_total": chunksTotal, "embedded_at_kill": killedAt, "integrity_check": integrity,
                             "vectors_plus_pending_equals_chunks": consistent, "resume_seconds": resume, "final_vectors": st2.vectors, "final_pending": st2.chunksPending]
    log("kill -9 during indexing: killed=\(wasRunning) at \(killedAt)/\(chunksTotal), integrity=\(integrity), consistent=\(consistent), resumed in \(String(format: "%.1f", resume)) s, final \(st2.vectors)/\(st2.chunks) pending \(st2.chunksPending)")

    // 5. full rebuild of derived data from the archive
    t = now(); try svc.rebuildDerived(); _ = try svc.pipeline.chunkStep(conversations: Int.max)
    while try await svc.pipeline.embedStep() > 0 {}
    rep["full_rebuild_seconds"] = now() - t; rep["rechunk_seconds"] = rechunk
    log("full derived-data rebuild: \(String(format: "%.1f", now() - t)) s for \(try svc.archive.stats().messages) messages")

    if let out { try JSONSerialization.data(withJSONObject: rep, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out)); log("wrote \(out)") }
}

/// Child process for the kill -9 test: index until killed (or done).
func runChildEmbed(dir: String) async throws {
    let svc = try PersonalAIServices(directory: URL(fileURLWithPath: dir), embedder: HashingEmbedder(dim: 256))
    svc.pipeline.embedBatch = 128
    while try await svc.pipeline.embedStep() > 0 { try await Task.sleep(nanoseconds: 2_000_000) }
}
