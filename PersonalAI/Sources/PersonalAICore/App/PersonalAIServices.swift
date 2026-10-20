import Foundation

/// Composition root for everything platform-neutral. The iOS app owns one of these; tests and the Linux harness build the same graph.
/// Embedders and engines are swappable at runtime: changing the embedder rebuilds the vector spaces (the archive itself is untouched).
public final class PersonalAIServices: @unchecked Sendable {
    public let directory: URL
    public let db: ArchiveDatabase
    public let archive: ArchiveStore
    public let memory: MemoryStore
    public let entities: EntityStore
    public let assets: AssetStore
    public let importer: ImportCoordinator
    public private(set) var embedder: any TextEmbedder
    public private(set) var vectors: VectorIndex
    public private(set) var memoryVectors: VectorIndex
    public private(set) var retriever: HybridRetriever
    public private(set) var assembler: PromptAssembler
    public private(set) var pipeline: IndexingPipeline
    public let counter: TokenCounter

    public init(directory: URL, embedder: any TextEmbedder = HashingEmbedder(dim: 256), profile: ArchiveDatabase.Profile = .phone, counter: TokenCounter = HeuristicTokenCounter()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        db = try ArchiveDatabase(path: directory.appendingPathComponent("archive.sqlite").path, profile: profile)
        archive = ArchiveStore(db: db); memory = MemoryStore(archive: archive); entities = EntityStore(db: db); assets = AssetStore(db: db)
        importer = ImportCoordinator(store: archive)
        self.embedder = embedder; self.counter = counter
        vectors = try VectorIndex(archive: db, space: 1, name: "chunks", embedderID: embedder.id, dim: embedder.dim)
        memoryVectors = try VectorIndex(archive: db, space: 3, name: "memories", embedderID: embedder.id, dim: embedder.dim, itemKind: "memory")
        retriever = HybridRetriever(archive: archive, vectors: vectors, embedder: embedder, memory: memory, entities: entities)
        retriever.memoryVectors = memoryVectors
        assembler = PromptAssembler(archive: archive, retriever: retriever, memory: memory, counter: counter)
        pipeline = IndexingPipeline(archive: archive, chunker: Chunker(store: archive), vectors: vectors, embedder: embedder)
        pipeline.memoryVectors = memoryVectors
    }

    /// Switches embedding model. Old vectors are discarded (they live in a different space) and chunks are re-queued; nothing else changes.
    public func setEmbedder(_ e: any TextEmbedder) throws {
        guard e.id != embedder.id else { return }
        embedder = e
        vectors = try VectorIndex(archive: db, space: 1, name: "chunks", embedderID: e.id, dim: e.dim)
        memoryVectors = try VectorIndex(archive: db, space: 3, name: "memories", embedderID: e.id, dim: e.dim, itemKind: "memory")
        retriever = HybridRetriever(archive: archive, vectors: vectors, embedder: e, memory: memory, entities: entities)
        retriever.memoryVectors = memoryVectors
        assembler = PromptAssembler(archive: archive, retriever: retriever, memory: memory, counter: counter)
        pipeline = IndexingPipeline(archive: archive, chunker: Chunker(store: archive), vectors: vectors, embedder: e)
        pipeline.memoryVectors = memoryVectors
    }

    public func makeChatController(engine: any InferenceEngine, profile: @escaping @Sendable () -> ModelProfile, device: @escaping @Sendable () -> DeviceBudget) -> ChatController {
        ChatController(archive: archive, assembler: assembler, engine: engine, profile: profile, device: device)
    }

    /// Throws away every derived structure (chunks, vectors, memories, entities, summaries) and re-queues indexing. Originals stay.
    public func rebuildDerived(keepUserEditedMemories: Bool = true) throws {
        try db.write { w in
            try w.transaction {
                try w.run("DELETE FROM vec_block"); try w.run("DELETE FROM vec_centroid"); try w.run("DELETE FROM vec_purge")
                try w.run("UPDATE vec_space SET trained_count=0, nlist=1, nprobe=NULL, measured_recall=NULL")
                try w.run("DELETE FROM chunk"); try w.run("DELETE FROM summary")
                try w.run("DELETE FROM kv WHERE key LIKE 'chunk.%' OR key LIKE 'extract.%'")
                if !keepUserEditedMemories {
                    try w.run("UPDATE memory SET supersedes=NULL"); try w.run("DELETE FROM memory_evidence"); try w.run("DELETE FROM memory")
                } else {
                    try w.run("UPDATE memory SET embedded=0")
                }
            }
        }
    }

    /// Deletes everything the app stores: archive, derived data, vectors, memories, assets metadata.
    public func eraseEverything() throws {
        try db.write { w in
            try w.exec("PRAGMA foreign_keys=OFF")
            for t in ["asset_link", "asset", "memory_evidence", "memory_event", "memory", "relation", "entity_mention", "entity_alias", "entity", "summary",
                      "vec_block", "vec_centroid", "vec_purge", "chunk", "message", "conversation", "source", "index_job", "kv"] {
                try w.run("DELETE FROM \(t)")
            }
            try w.exec("PRAGMA foreign_keys=ON")
        }
        _ = try? db.write { try $0.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        _ = try? db.write { try $0.exec("VACUUM") }
    }
}

/// Complete, human-readable export: nothing is held back and nothing is hidden behind the app.
public enum ArchiveExporter {
    public struct Result: Sendable { public var conversations: Int; public var messages: Int; public var memories: Int; public var url: URL }

    /// Writes `<dir>/personal-ai-export/{conversations.jsonl, memories.json, README.txt}`.
    public static func export(from s: PersonalAIServices, to dir: URL) throws -> Result {
        let out = dir.appendingPathComponent("personal-ai-export", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let convPath = out.appendingPathComponent("conversations.jsonl")
        FileManager.default.createFile(atPath: convPath.path, contents: nil)
        let h = try FileHandle(forWritingTo: convPath); defer { try? h.close() }
        var nConv = 0, nMsg = 0
        var offset = 0
        while true {
            let convs = try s.archive.conversations(limit: 200, offset: offset)
            if convs.isEmpty { break }
            offset += convs.count
            for c in convs {
                var msgs: [[String: Any]] = []
                var from = 0
                while true {
                    let batch = try s.archive.messages(conversationID: c.id, seqFrom: from, seqTo: from + 499)
                    if batch.isEmpty { break }
                    for m in batch {
                        msgs.append(["role": m.role.rawValue, "text": m.text, "time": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: m.createdAt)),
                                     "locality": m.locality.rawValue, "model": m.model as Any? ?? NSNull()])
                    }
                    from += 500
                }
                nMsg += msgs.count; nConv += 1
                let obj: [String: Any] = ["id": c.id, "title": c.title, "created": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: c.createdAt)), "origin": c.origin, "messages": msgs]
                try h.write(contentsOf: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) + Data([10]))
            }
        }
        let mems = try s.memory.list(statuses: [.active, .disputed, .superseded], limit: 100_000)
        let memJSON: [[String: Any]] = try mems.map { m in
            let ev = try s.memory.evidence(for: m.id).map { ["message_id": $0.messageID, "quote": $0.quote, "speaker": $0.speaker, "role": $0.role] as [String: Any] }
            return ["id": m.id, "text": m.text, "kind": m.kind.rawValue, "how_we_know": m.epistemic.rawValue, "status": m.status.rawValue, "confidence": m.confidence,
                    "valid_from": m.validFrom as Any? ?? NSNull(), "valid_to": m.validTo as Any? ?? NSNull(), "user_state": m.userState.rawValue, "evidence": ev]
        }
        try JSONSerialization.data(withJSONObject: memJSON, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("memories.json"))
        try """
        Personal AI export
        conversations.jsonl : one conversation per line with every message (original wording, timestamps, which model wrote assistant messages, local/cloud/imported).
        memories.json       : derived memories with the verbatim quotes and message ids that support them, including superseded and disputed ones.
        Derived data (search indexes, vectors) is not exported: it is rebuilt from conversations.jsonl.
        """.write(to: out.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        return Result(conversations: nConv, messages: nMsg, memories: mems.count, url: out)
    }
}
