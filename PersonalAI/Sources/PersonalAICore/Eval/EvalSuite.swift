import Foundation

/// Stand-in for the language model in automated tests: it can only *quote* retrieved evidence, never invent. That makes
/// "the answer is supported by the evidence" a checkable property rather than a hope. It does NOT measure LLM answer quality.
public struct GroundedAnswer: Sendable {
    public var text: String
    public var abstained: Bool
    public var support: [(tag: String, sentence: String)]
}

public struct ExtractiveAnswerer: Sendable {
    public let embedder: any TextEmbedder
    public var minSimilarity: Float = 0.30
    public var relativeCutoff: Float = 0.80
    /// Two candidates this similar are treated as the same fact stated at different times: the newer wins.
    public var sameFactSimilarity: Float = 0.50
    public init(embedder: any TextEmbedder) { self.embedder = embedder }

    struct Candidate { var sentence: String; var tag: String; var date: Double; var sim: Float; var vec: [Float]; var isMemory: Bool }

    public func answer(question: String, prompt: AssembledPrompt) async throws -> GroundedAnswer {
        guard let r = prompt.retrieval, r.confidence != .none, !prompt.citations.isEmpty else {
            return GroundedAnswer(text: "I don't have anything in your history about that.", abstained: true, support: [])
        }
        var raw: [(String, String, Double, Bool)] = []
        for c in prompt.citations {
            if let mid = c.memoryID, let rm = r.memories.first(where: { $0.memory.id == mid }) {
                raw.append((rm.memory.text, c.id, rm.memory.validFrom ?? 0, true))
            } else if c.id.hasPrefix("E"), let span = r.spans.first(where: { $0.anchorMessageIDs == c.messageIDs && $0.conversationID == c.conversationID }) {
                for m in span.messages where m.role == .user && span.outdated == nil {
                    for s in (m.text.count <= 220 ? [m.text] : Self.sentences(m.text)) { raw.append((s, c.id, m.createdAt, false)) }
                }
            }
        }
        guard !raw.isEmpty else { return GroundedAnswer(text: "I don't have anything in your history about that.", abstained: true, support: []) }
        let qv = try await embedder.embed([question], kind: .query)[0]
        let dv = try await embedder.embed(raw.map { $0.0 }, kind: .document)
        var cands = raw.enumerated().map { Candidate(sentence: $1.0, tag: $1.1, date: $1.2, sim: VectorMath.dot(qv, dv[$0]), vec: dv[$0], isMemory: $1.3) }
        cands.sort { $0.sim > $1.sim }
        guard let best = cands.first, best.sim >= (r.confidence == .weak ? minSimilarity + 0.15 : minSimilarity) else {
            return GroundedAnswer(text: "I don't have anything in your history about that.", abstained: true, support: [])
        }
        var chosen: [Candidate] = []
        for c in cands where c.sim >= max(minSimilarity, best.sim * relativeCutoff) {
            if let i = chosen.firstIndex(where: { VectorMath.dot($0.vec, c.vec) >= sameFactSimilarity }) {
                if c.date > chosen[i].date { chosen[i] = c }           // newer statement of the same thing supersedes
                continue
            }
            chosen.append(c)
        }
        // a newer statement of the same thing beats an older one even when it matched the question a little less well
        for i in chosen.indices {
            for d in cands where d.sim >= minSimilarity && d.date > chosen[i].date && VectorMath.dot(d.vec, chosen[i].vec) >= sameFactSimilarity { chosen[i] = d }
        }
        var seen = Set<String>(); chosen = chosen.filter { seen.insert($0.sentence).inserted }
        chosen.sort { $0.date < $1.date }
        let text = chosen.map { "\($0.sentence) [\($0.tag)]" }.joined(separator: " ")
        return GroundedAnswer(text: text, abstained: false, support: chosen.map { ($0.tag, $0.sentence) })
    }

    static func sentences(_ t: String) -> [String] {
        var out: [String] = []; var cur = ""
        for ch in t {
            cur.append(ch)
            if ".!?\n".contains(ch) { let s = cur.trimmingCharacters(in: .whitespacesAndNewlines); if s.count > 8 { out.append(s) }; cur = "" }
        }
        let s = cur.trimmingCharacters(in: .whitespacesAndNewlines); if s.count > 8 { out.append(s) }
        return out.isEmpty ? [t] : out
    }
}

public struct EvalCaseResult: Sendable, Codable {
    public var id: String, category: String, query: String
    public var goldRank: Int?                // 1-based rank of the first span containing a gold message
    public var allGoldFound: Bool
    public var windowRespected: Bool
    public var answerSupported: Bool         // contains expected facts, none of the forbidden ones
    public var citationsValid: Bool          // every quoted sentence really occurs in the cited archive message / memory, and in the prompt
    public var abstainedCorrectly: Bool?
    public var confidence: String
    public var retrievalMillis: Double
    public var answer: String
    public var passed: Bool
}

public struct EvalReport: Sendable, Codable {
    public var embedder: String
    public var realEmbedder: Bool
    public var noiseMessages: Int
    public var totalMessages: Int
    public var cases: [EvalCaseResult]
    public var importSeconds: Double, indexSeconds: Double
    public var hitAt1: Double, hitAt3: Double, mrr: Double, allGoldRate: Double, answerRate: Double, abstainRate: Double
    public var byCategory: [String: Double]
    /// Pass rate on the cases written after tuning stopped (ids starting with "h-").
    public var heldOutPassRate: Double
    public var tunedPassRate: Double
    public var heldOut2PassRate: Double
}

public enum EvalSuite {
    /// Serialises the corpus as a ChatGPT-style export so the *real importer* is on the evaluated path.
    public static func chatGPTExport(_ corpus: EvalCorpus) -> Data {
        var convs: [[String: Any]] = []
        for c in corpus.conversations {
            let t0 = EvalCorpus.ts(c.start)
            var mapping: [String: Any] = ["root": ["id": "root", "parent": NSNull(), "children": ["n0"], "message": NSNull()]]
            for (i, l) in c.lines.enumerated() {
                let id = "n\(i)"
                mapping[id] = ["id": id, "parent": i == 0 ? "root" : "n\(i - 1)", "children": i + 1 < c.lines.count ? ["n\(i + 1)"] : [],
                               "message": ["id": id, "author": ["role": l.role.rawValue], "create_time": t0 + Double(i) * 1200,
                                           "content": ["content_type": "text", "parts": [l.text]], "metadata": [:]]]
            }
            convs.append(["id": c.name, "title": c.title, "create_time": t0, "update_time": t0 + Double(c.lines.count) * 1200,
                          "current_node": "n\(c.lines.count - 1)", "mapping": mapping])
        }
        return try! JSONSerialization.data(withJSONObject: convs)
    }

    public static func run(corpus: EvalCorpus = .standard, embedder: any TextEmbedder, realEmbedder: Bool, noiseMessages: Int, dir: URL,
                           reranker: Reranker? = nil, config: RetrievalConfig = RetrievalConfig(), chunkTokens: Int = 256, only: String? = nil, log: (String) -> Void = { _ in }) async throws -> EvalReport {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try ArchiveDatabase(path: dir.appendingPathComponent("eval.sqlite").path, profile: .phone)
        let store = ArchiveStore(db: db)
        let t0 = Date()
        // 1. import through the real importer
        let export = dir.appendingPathComponent("export"); try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try chatGPTExport(corpus).write(to: export.appendingPathComponent("conversations.json"))
        _ = try ImportCoordinator(store: store).importItem(at: export)
        if noiseMessages > 0 {
            try SyntheticArchive(seed: 11).generate(into: store, messages: noiseMessages, avgConversationLength: 20, years: 2, end: corpus.now)
        }
        let importSeconds = Date().timeIntervalSince(t0)

        // 2. keys → ids
        var keyToID: [String: Int64] = [:]
        var convByName: [String: Int64] = [:]
        for c in corpus.conversations {
            let cid = try db.read { try $0.scalarInt("SELECT id FROM conversation WHERE external_id=?", [.text(c.name)]) }
            convByName[c.name] = cid
            for (i, l) in c.lines.enumerated() { if let k = l.key { keyToID[k] = try db.read { try $0.scalarInt("SELECT id FROM message WHERE conversation_id=? AND seq=?", [.int(cid), .int(i)]) } } }
        }

        // 3. index
        let t1 = Date()
        let vectors = try VectorIndex(archive: db, space: 1, name: "chunks", embedderID: embedder.id, dim: embedder.dim)
        let pipe = IndexingPipeline(archive: store, chunker: Chunker(store: store, policy: { var p = ChunkingPolicy(); p.targetTokens = chunkTokens; p.maxTokens = max(chunkTokens * 2, 120); return p }()), vectors: vectors, embedder: embedder)
        pipe.embedBatch = 64
        _ = try pipe.chunkStep(conversations: 1_000_000)
        while try await pipe.embedStep() > 0 {}
        let memory = MemoryStore(archive: store), ents = EntityStore(db: db)
        // entities: seeded by hand here (an LLM extractor would propose them on device)
        func seedEntity(_ name: String, _ desc: String, aliases: [String], key: String) throws {
            let e = try ents.create(kind: "person", name: name, description: desc, aliases: aliases)
            if let mid = keyToID[key], let m = try store.messages(ids: [mid])[mid] { try ents.recordMention(entity: e, messageID: mid, conversationID: m.conversationID, at: m.createdAt) }
        }
        try seedEntity("Alex", "coworker", aliases: ["alex from work"], key: "alex#work")
        try seedEntity("Alex", "brother", aliases: ["my brother alex", "brother alex"], key: "alex#bro")
        try seedEntity("Priya", "book club friend", aliases: [], key: "book#priya")
        // memories: deterministic rule extractor over every real conversation (same code path as the app's free extraction tier)
        let extractor = MemoryExtractor(archive: store, memory: memory, entities: ents, generator: nil)
        for c in corpus.conversations.sorted(by: { $0.start < $1.start }) { _ = try await extractor.extract(conversationID: convByName[c.name]!, maxWindows: 200) }
        let mv = try VectorIndex(archive: db, space: 3, name: "memories", embedderID: embedder.id, dim: embedder.dim, itemKind: "memory")
        pipe.memoryVectors = mv
        while try await pipe.embedMemoriesStep() > 0 {}
        let indexSeconds = Date().timeIntervalSince(t1)

        let retriever = HybridRetriever(archive: store, vectors: vectors, embedder: embedder, memory: memory, entities: ents)
        retriever.memoryVectors = mv; retriever.reranker = reranker; retriever.config = config
        let assembler = PromptAssembler(archive: store, retriever: retriever, memory: memory, counter: HeuristicTokenCounter())
        let model = ModelProfile(id: "eval", maxContext: 8192, weightsBytes: 2_000_000_000, kvBytesPerToken: 20_000)
        let device = DeviceBudget(availableMemoryBytes: 4_000_000_000)
        let answerer = ExtractiveAnswerer(embedder: embedder)

        // 4. questions
        var results: [EvalCaseResult] = []
        for cs in corpus.cases where only == nil || cs.id == only {
            let now = Date(timeIntervalSince1970: EvalCorpus.ts(cs.now))
            let started = Date()
            let prompt = try await assembler.assemble(conversationID: cs.inConversation.flatMap { convByName[$0] }, userText: cs.query, model: model, device: device, now: now)
            let ms = Date().timeIntervalSince(started) * 1000
            let r = prompt.retrieval
            let goldIDs = Set(cs.gold.compactMap { keyToID[$0] })
            var rank: Int?
            for (i, s) in (r?.spans ?? []).enumerated() where s.messages.contains(where: { goldIDs.contains($0.id) }) { rank = i + 1; break }
            let found = Set((r?.spans ?? []).flatMap { $0.messages.map(\.id) })
            let allGold = goldIDs.isSubset(of: found)
            var windowOK = true
            if let w = cs.hardWindow {
                let lo = EvalCorpus.ts(w.0), hi = EvalCorpus.ts(w.1)
                windowOK = (r?.spans ?? []).allSatisfy { $0.date.timeIntervalSince1970 >= lo && $0.date.timeIntervalSince1970 < hi }
            }
            let ans = try await answerer.answer(question: cs.query, prompt: prompt)
            let low = ans.text.lowercased()
            let supported = !ans.abstained && cs.mustContain.allSatisfy { low.contains($0.lowercased()) } && !cs.mustNotContain.contains { low.contains($0.lowercased()) }
            // citation check: the quoted sentence must be present in the cited archive message / memory AND in the prompt the model would see
            var citeOK = true
            let promptText = prompt.messages.map(\.content).joined(separator: "\n")
            for s in ans.support {
                guard let c = prompt.citations.first(where: { $0.id == s.tag }) else { citeOK = false; continue }
                if let mid = c.memoryID { let txt = try memory.memory(mid)?.text; citeOK = citeOK && txt == s.sentence }
                else { let msgs = try store.messages(ids: c.messageIDs); citeOK = citeOK && msgs.values.contains { $0.text.contains(s.sentence) } }
                citeOK = citeOK && promptText.contains(s.sentence)
            }
            let abst: Bool? = cs.abstain ? ans.abstained : nil
            let passed = cs.abstain ? ans.abstained : (supported && citeOK && allGold && windowOK)
            results.append(EvalCaseResult(id: cs.id, category: cs.category, query: cs.query, goldRank: rank, allGoldFound: allGold, windowRespected: windowOK,
                                          answerSupported: supported, citationsValid: citeOK, abstainedCorrectly: abst, confidence: r?.confidence.rawValue ?? "n/a",
                                          retrievalMillis: ms, answer: ans.text, passed: passed))
            if !passed, let r { for s in r.spans.prefix(4) { log("      · \(s.conversationTitle) #\(s.firstSeq) score=\(String(format: "%.3f", s.score)) vec=\(s.vectorScore.map { String(format: "%.2f", $0) } ?? "-") ch=\(s.channels.joined(separator: ",")) :: \(s.messages.first?.text.prefix(60) ?? "")") } }
            if !passed, let qv = try? await embedder.embed([cs.query], kind: .query).first, let hits = try? vectors.search(qv, k: 5, nprobe: nil) {
                let chunks = (try? store.chunks(ids: hits.map(\.id))) ?? [:]
                for h in hits { if let c = chunks[h.id] { let hasGold = goldIDs.contains { $0 >= c.firstMsg && $0 <= c.lastMsg }; log("      vec \(String(format: "%.3f", h.score)) conv \(c.conversationID) seq \(c.firstSeq)-\(c.lastSeq)\(hasGold ? " ◀ GOLD" : "")") } }
            }
            log("\(passed ? "PASS" : "FAIL") [\(cs.category)] \(cs.id): rank=\(rank.map(String.init) ?? "-") conf=\(r?.confidence.rawValue ?? "-") → \(ans.text.prefix(140))")
        }
        let answerable = results.filter { $0.abstainedCorrectly == nil }
        func frac(_ xs: [Bool]) -> Double { xs.isEmpty ? 0 : Double(xs.filter { $0 }.count) / Double(xs.count) }
        let totalMsgs = Int(try store.stats().messages)
        var byCat: [String: [Bool]] = [:]
        for r in results { byCat[r.category, default: []].append(r.passed) }
        return EvalReport(embedder: embedder.id, realEmbedder: realEmbedder, noiseMessages: noiseMessages, totalMessages: totalMsgs, cases: results,
                          importSeconds: importSeconds, indexSeconds: indexSeconds,
                          hitAt1: frac(answerable.map { $0.goldRank == 1 }), hitAt3: frac(answerable.map { ($0.goldRank ?? 99) <= 3 }),
                          mrr: answerable.isEmpty ? 0 : answerable.reduce(0) { $0 + ($1.goldRank.map { 1.0 / Double($0) } ?? 0) } / Double(answerable.count),
                          allGoldRate: frac(answerable.map(\.allGoldFound)), answerRate: frac(answerable.map(\.answerSupported)),
                          abstainRate: frac(results.compactMap(\.abstainedCorrectly)), byCategory: byCat.mapValues { frac($0) },
                          heldOutPassRate: frac(results.filter { $0.id.hasPrefix("h-") }.map(\.passed)), tunedPassRate: frac(results.filter { !$0.id.hasPrefix("h-") && !$0.id.hasPrefix("g-") }.map(\.passed)),
                          heldOut2PassRate: frac(results.filter { $0.id.hasPrefix("g-") }.map(\.passed)))
    }
}
