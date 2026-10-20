import Foundation

/// The steps that turn archived messages into searchable derived data. Each call does a *small, bounded* amount of work
/// so a scheduler can interleave it with an active conversation and cancel between calls.
public final class IndexingPipeline: @unchecked Sendable {
    public let archive: ArchiveStore
    public let chunker: Chunker
    public let vectors: VectorIndex?
    public let embedder: (any TextEmbedder)?
    public var memoryVectors: VectorIndex?
    public var embedBatch = 32

    public init(archive: ArchiveStore, chunker: Chunker, vectors: VectorIndex?, embedder: (any TextEmbedder)?) {
        self.archive = archive; self.chunker = chunker; self.vectors = vectors; self.embedder = embedder
    }

    /// Cheap (no model). Safe to run even while the model is generating.
    @discardableResult
    public func chunkStep(conversations: Int = 20, holdBack: Int = 0) throws -> Int {
        try chunker.chunkPending(maxConversations: conversations, holdBack: holdBack)
    }

    public func pendingChunkCount() throws -> Int { Int(try archive.db.read { try $0.scalarInt("SELECT COUNT(*) FROM chunk WHERE embedded=0") }) }

    /// Embeds one batch of un-embedded chunks (newest first, so recent history is searchable before old history).
    @discardableResult
    public func embedStep() async throws -> Int {
        guard let vectors, let embedder else { return 0 }
        let ids: [Int64] = try archive.db.read { try $0.query("SELECT id FROM chunk WHERE embedded=0 ORDER BY id DESC LIMIT ?", [.int(embedBatch)]) { $0.int(0) } }
        if ids.isEmpty { return 0 }
        let chunks = try archive.chunks(ids: ids)
        var texts: [String] = [], order: [Int64] = []
        let maxChars = Int(Double(embedder.maxInputTokens) * 3.2)
        for id in ids {
            guard let c = chunks[id] else { continue }
            texts.append(try ChunkText.build(c, store: archive, maxChars: maxChars)); order.append(id)
        }
        let vecs = try await embedder.embed(texts, kind: .document)
        try vectors.add(zip(order, vecs).map { (id: $0, vector: $1) })
        try archive.db.write { w in try w.transaction { for id in order { try w.run("UPDATE chunk SET embedded=1 WHERE id=?", [.int(id)]) } } }
        return order.count
    }

    /// Memories are embedded too (tiny: hundreds to thousands of rows) so recall works by meaning, not just shared words.
    @discardableResult
    public func embedMemoriesStep(limit: Int = 64) async throws -> Int {
        guard let memoryVectors, let embedder else { return 0 }
        let rows: [(Int64, String)] = try archive.db.read { try $0.query("SELECT id, text FROM memory WHERE embedded=0 AND status != 'retracted' LIMIT ?", [.int(limit)]) { ($0.int(0), $0.text(1)) } }
        if rows.isEmpty { return 0 }
        let vecs = try await embedder.embed(rows.map(\.1), kind: .document)
        try memoryVectors.remove(ids: rows.map(\.0))
        try memoryVectors.add(zip(rows.map(\.0), vecs).map { (id: $0, vector: $1) })
        try archive.db.write { w in try w.transaction { for r in rows { try w.run("UPDATE memory SET embedded=1 WHERE id=?", [.int(r.0)]) } } }
        return rows.count
    }

    public func trainStepIfNeeded(shouldContinue: () -> Bool) throws -> Bool {
        guard let vectors, try vectors.needsTraining() else { return false }
        try vectors.train(shouldContinue: shouldContinue)
        return true
    }
}

/// What the device is allowed to spend on background work right now. The app computes this from
/// generation state, thermal state, Low Power Mode, charging and foreground/background.
public enum WorkLevel: Int, Sendable, Comparable {
    case none = 0        // user is generating / device hot: do nothing
    case light = 1       // bookkeeping only (chunking, SQLite maintenance)
    case full = 2        // embeddings, clustering, model-assisted extraction
    public static func < (a: WorkLevel, b: WorkLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct IndexStatus: Sendable {
    public var pendingChunks: Int
    public var embeddedVectors: Int
    public var level: WorkLevel
    public var activity: String
}

/// Cooperative background indexer. Priorities: (1) never starve the chat, (2) newest data first, (3) always resumable
/// (all progress lives in SQLite: `chunk.embedded`, kv watermarks), so killing the app at any instant loses at most one batch.
public actor IndexScheduler {
    private let pipeline: IndexingPipeline
    private let level: @Sendable () -> WorkLevel
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<IndexStatus>.Continuation?
    public nonisolated let statusUpdates: AsyncStream<IndexStatus>
    public var extractor: (@Sendable () async -> Bool)?       // optional model-assisted step, returns true if it did work
    public var idleSleep: Duration = .seconds(2)

    public init(pipeline: IndexingPipeline, level: @escaping @Sendable () -> WorkLevel) {
        self.pipeline = pipeline; self.level = level
        var c: AsyncStream<IndexStatus>.Continuation!
        statusUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        continuation = c
    }

    public func setExtractor(_ e: @escaping @Sendable () async -> Bool) { extractor = e }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }
    public func stop() { task?.cancel(); task = nil }

    private func publish(_ activity: String, _ lvl: WorkLevel) {
        let pending = (try? pipeline.pendingChunkCount()) ?? 0
        let n = (try? pipeline.vectors?.count()) ?? 0
        continuation?.yield(IndexStatus(pendingChunks: pending, embeddedVectors: n ?? 0, level: lvl, activity: activity))
    }

    private func loop() async {
        while !Task.isCancelled {
            let lvl = level()
            if lvl == .none { publish("paused", lvl); try? await Task.sleep(for: .milliseconds(500)); continue }
            var didWork = false
            // 1. chunking: cheap, always allowed at `light`
            if let n = try? pipeline.chunkStep(conversations: 10, holdBack: 4), n > 0 { didWork = true; publish("chunking", lvl) }
            if lvl >= .full {
                // 2. embeddings: the dominant cost; one small batch, then re-check the gate
                if let n = try? await pipeline.embedMemoriesStep(), n > 0 { didWork = true; publish("embedding memories", lvl) }
                else if let n = try? await pipeline.embedStep(), n > 0 { didWork = true; publish("embedding", lvl) }
                else if (try? pipeline.trainStepIfNeeded(shouldContinue: { [level] in level() >= .full })) == true { didWork = true; publish("clustering", lvl) }
                else if let e = extractor, await e() { didWork = true; publish("learning from conversations", lvl) }
            }
            if !didWork { publish("idle", lvl); try? await Task.sleep(for: idleSleep) }
            else { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }   // let the UI/inference thread breathe between batches
        }
    }
}
