import Foundation

public protocol Reranker: Sendable {
    /// Relevance of each candidate text to the query (higher is better). Cross-encoder in the app; optional.
    func rerank(query: String, candidates: [String]) async throws -> [Float]
}

public struct RetrievalConfig: Sendable {
    public var lexicalK = 40
    public var vectorK = 40
    public var nprobe: Int? = nil
    public var rrfK = 60.0
    public var weights: [String: Double] = ["lexical": 1.0, "vector": 1.0, "memory": 1.3, "entity": 0.6, "assoc": 0.5]
    public var maxSpans = 6
    public var maxPerConversation = 2
    public var maxSpanMessages = 12
    public var windowBefore = 1, windowAfter = 1
    /// Cosine floor for vector-only evidence. Depends on the embedder; calibrate per model in the on-device eval (docs/EVAL.md).
    public var minVectorScore: Float = 0.30
    public var strongVectorScore: Float = 0.50
    public var minTermCoverage = 0.34
    public init() {}
}

public struct RetrievalContext: Sendable {
    public var currentConversationID: Int64?
    /// First seq of the verbatim tail already in the prompt; older messages of the same conversation may still be retrieved.
    public var visibleTailStartSeq: Int?
    public var now: Date
    public init(currentConversationID: Int64? = nil, visibleTailStartSeq: Int? = nil, now: Date = Date()) {
        self.currentConversationID = currentConversationID; self.visibleTailStartSeq = visibleTailStartSeq; self.now = now
    }
}

public struct EvidenceSpan: Sendable, Identifiable {
    public var id: String { "\(conversationID):\(firstSeq)-\(lastSeq)" }
    public var conversationID: Int64
    public var conversationTitle: String
    public var firstSeq: Int, lastSeq: Int
    public var anchorMessageIDs: [Int64]
    public var messages: [MessageRecord]
    public var score: Double
    public var channels: [String]
    public var reasons: [String]
    public var termCoverage: Double
    public var vectorScore: Float?
    public var date: Date { Date(timeIntervalSince1970: messages.first?.createdAt ?? 0) }
}

public struct RankedMemory: Sendable { public var memory: MemoryRecord; public var effectiveConfidence: Double; public var reason: String }
public struct AssetHit: Sendable { public var asset: AssetRecord; public var score: Double; public var reason: String; public var linkedMessageID: Int64? }
public enum RetrievalConfidence: String, Sendable { case none, weak, good }

public struct RetrievalDiagnostics: Sendable {
    public var millis: [String: Double] = [:]
    public var counts: [String: Int] = [:]
    public var skipped: String?
}

public struct RetrievalResult: Sendable {
    public var plan: QueryPlan
    public var spans: [EvidenceSpan]
    public var memories: [RankedMemory]
    public var standing: [MemoryRecord]
    public var assets: [AssetHit]
    public var confidence: RetrievalConfidence
    public var diagnostics: RetrievalDiagnostics
    public static func empty(_ plan: QueryPlan, why: String) -> RetrievalResult {
        var d = RetrievalDiagnostics(); d.skipped = why
        return RetrievalResult(plan: plan, spans: [], memories: [], standing: [], assets: [], confidence: .none, diagnostics: d)
    }
}

/// Hybrid retrieval: lexical + semantic + memory/entity channels, fused with reciprocal-rank fusion, gated for relevance,
/// diversified, and expanded to the *actual archived messages* the language model will read.
public final class HybridRetriever: @unchecked Sendable {
    public let archive: ArchiveStore
    public let lexical: LexicalSearch
    public let vectors: VectorIndex?
    public var memoryVectors: VectorIndex?
    public let embedder: (any TextEmbedder)?
    public let memory: MemoryStore
    public let entities: EntityStore
    public let assets: AssetStore
    public var reranker: Reranker?
    public var config = RetrievalConfig()
    public var analyzer = QueryAnalyzer()

    public init(archive: ArchiveStore, vectors: VectorIndex?, embedder: (any TextEmbedder)?, memory: MemoryStore, entities: EntityStore) {
        self.archive = archive; self.lexical = LexicalSearch(db: archive.db); self.vectors = vectors; self.embedder = embedder
        self.memory = memory; self.entities = entities; self.assets = AssetStore(db: archive.db)
    }

    struct Cand {
        var conv: Int64, lo: Int, hi: Int
        var anchors: Set<Int>
        var channels: [String: Int]            // channel -> best rank
        var t0: Double, t1: Double
        var vectorScore: Float?
        var lexScore: Double?
        var reasons: [String] = []
    }

    private func ms(_ since: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e6 }

    public func retrieve(_ query: String, context: RetrievalContext = RetrievalContext(), hasHistory: Bool = true) async throws -> RetrievalResult {
        var diag = RetrievalDiagnostics()
        let t0 = DispatchTime.now()
        let plan = analyzer.analyze(query, now: context.now, entities: entities, hasHistory: hasHistory)
        diag.millis["analyze"] = ms(t0)

        // Standing instructions are tiny and always relevant; they never depend on a retrieval pass.
        let standing = (try? memory.standing()) ?? []
        guard plan.needsRetrieval else {
            var r = RetrievalResult.empty(plan, why: plan.complexity == .trivial ? "trivial turn" : "no retrieval cues")
            r.standing = standing
            r.diagnostics.millis = diag.millis
            return r
        }

        let deep = plan.complexity == .deep
        let cfg = config
        let k = deep ? cfg.lexicalK * 2 : cfg.lexicalK
        let filters = SearchFilters(timeRange: (plan.time?.hard ?? false) ? plan.time!.from...plan.time!.to : nil,
                                    excludeConversation: nil)

        // ---- channels, run concurrently (SQLite readers are pooled) ----
        let tl = DispatchTime.now()
        async let lexTask: [LexicalHit] = Task.detached { [lexical, plan] in
            try lexical.searchMessages(phrases: plan.phrases, terms: plan.terms, filters: filters, limit: k)
        }.value
        // one query embedding feeds both semantic channels
        var qv: [Float]?
        if let embedder, !plan.query.isEmpty { qv = try? await embedder.embed([plan.query], kind: .query).first }
        let vecHits = (try? await self.vectorChannel(qv: qv, k: deep ? cfg.vectorK * 2 : cfg.vectorK, hardTime: filters.timeRange)) ?? []
        let memHits = (try? await Task.detached { [self] in try self.memoryChannel(plan: plan, context: context, qv: qv) }.value) ?? []
        let lexHits = (try? await lexTask) ?? []
        diag.millis["channels"] = ms(tl)
        diag.counts["lexical"] = lexHits.count; diag.counts["vector"] = vecHits.count; diag.counts["memory"] = memHits.count

        // ---- candidates ----
        var cands: [Cand] = []
        for (rank, h) in lexHits.enumerated() {
            cands.append(Cand(conv: h.conversationID, lo: h.seq, hi: h.seq, anchors: [h.seq], channels: ["lexical": rank], t0: h.createdAt, t1: h.createdAt, lexScore: h.score))
        }
        for (rank, (h, c)) in vecHits.enumerated() {
            cands.append(Cand(conv: c.conversationID, lo: c.firstSeq, hi: c.lastSeq, anchors: Set(c.firstSeq...c.lastSeq), channels: ["vector": rank], t0: c.t0, t1: c.t1, vectorScore: h.score))
        }
        // memory-backed evidence: the messages that *prove* a relevant memory are strong candidates
        for (rank, m) in memHits.prefix(6).enumerated() {
            for link in (try? memory.evidence(for: m.memory.id)) ?? [] where link.role != "contradicts" {
                if let msg = try? archive.message(link.messageID) {
                    cands.append(Cand(conv: msg.conversationID, lo: msg.seq, hi: msg.seq, anchors: [msg.seq], channels: ["memory": rank], t0: msg.createdAt, t1: msg.createdAt,
                                      reasons: ["evidence for memory: \(m.memory.text.prefix(60))"]))
                }
            }
        }
        if !plan.entityIDs.isEmpty {
            let rows: [(Int64, Int, Double)] = (try? archive.db.read { try $0.query("""
                SELECT m.conversation_id, m.seq, m.created_at FROM entity_mention em JOIN message m ON m.id=em.message_id
                WHERE em.entity_id IN (\(plan.entityIDs.map(String.init).joined(separator: ","))) ORDER BY m.created_at DESC LIMIT 20
                """) { ($0.int(0), Int($0.int(1)), $0.double(2)) } }) ?? []
            for (rank, r) in rows.enumerated() { cands.append(Cand(conv: r.0, lo: r.1, hi: r.1, anchors: [r.1], channels: ["entity": rank], t0: r.2, t1: r.2, reasons: ["mentions a person/project from your question"])) }
        }

        // current conversation: never re-retrieve what is already verbatim in the prompt
        if let cur = context.currentConversationID, let tail = context.visibleTailStartSeq {
            cands = cands.compactMap { c in
                guard c.conv == cur else { return c }
                if c.lo >= tail { return nil }
                var x = c; x.hi = min(x.hi, tail - 1); x.anchors = x.anchors.filter { $0 < tail }
                return x.anchors.isEmpty ? nil : x
            }
        }
        // hard time constraint
        if let t = plan.time, t.hard { cands = cands.filter { $0.t1 >= t.from && $0.t0 <= t.to } }

        // ---- merge overlapping spans, RRF ----
        var merged = Self.merge(cands, maxLen: cfg.maxSpanMessages)
        for i in merged.indices {
            var s = 0.0
            for (ch, rank) in merged[i].channels { s += (cfg.weights[ch] ?? 1) / (cfg.rrfK + Double(rank)) }
            merged[i].lexScore = s       // reuse field for fused score
        }
        merged.sort { ($0.lexScore ?? 0) > ($1.lexScore ?? 0) }
        merged = Array(merged.prefix(40))

        // ---- features, gating ----
        let tr = DispatchTime.now()
        let info = lexical.informativeTerms(plan.terms, total: (try? archive.stats().messages) ?? 0)
        let rare = info.map(\.term)
        struct Scored { var c: Cand; var score: Double; var coverage: Double; var msgs: [MessageRecord] }
        var scored: [Scored] = []
        let now = context.now.timeIntervalSince1970
        let dayHalf = 180.0 * 86400
        for c in merged {
            let msgs = (try? archive.messages(conversationID: c.conv, seqFrom: c.lo, seqTo: c.hi)) ?? []
            if msgs.isEmpty { continue }
            let words = Set(msgs.flatMap { TextNorm.words($0.text) })
            let coverage = rare.isEmpty ? 0 : Double(rare.filter { words.contains($0) }.count) / Double(rare.count)
            let phraseHit = plan.phrases.contains { p in msgs.contains { $0.text.lowercased().contains(p.lowercased()) } }
            var pass = phraseHit || coverage >= cfg.minTermCoverage || c.channels["memory"] != nil
            if let v = c.vectorScore, v >= cfg.minVectorScore { pass = true }
            if c.channels["entity"] != nil { pass = true }
            if !pass { continue }
            var s = c.lexScore ?? 0
            if !rare.isEmpty { s *= 0.8 + 0.4 * coverage }
            if phraseHit { s *= 1.5 }
            if let t = plan.time {
                let inside = c.t1 >= t.from && c.t0 <= t.to
                s *= inside ? 1.25 : (t.hard ? 0 : 0.85)
            }
            if plan.roleBias == .user, msgs.contains(where: { c.anchors.contains($0.seq) && $0.role == .user }) { s *= 1.1 }
            if !plan.intents.contains(.timeline), !plan.intents.contains(.compare) { s *= 1 + 0.1 * exp(-max(0, now - c.t1) / dayHalf) }
            scored.append(Scored(c: c, score: s, coverage: coverage, msgs: msgs))
        }
        scored.sort { $0.score > $1.score }

        // optional neural rerank of the head
        if let reranker, deep || scored.count > 3, !scored.isEmpty {
            let head = Array(scored.prefix(20))
            let texts = head.map { s in s.msgs.map { "\($0.role.rawValue): \($0.text.prefix(500))" }.joined(separator: "\n") }
            if let rr = try? await reranker.rerank(query: plan.query, candidates: texts), rr.count == head.count {
                let mx = rr.max() ?? 1, mn = rr.min() ?? 0
                let spread = max(mx - mn, 1e-6)
                var re = head
                for i in re.indices { re[i].score = re[i].score * (0.6 + 0.8 * Double((rr[i] - mn) / spread)) }
                re.sort { $0.score > $1.score }
                scored = re + scored.dropFirst(20)
            }
        }
        diag.millis["rank"] = ms(tr)

        // ---- diversity ----
        let perConv = (deep && !plan.intents.contains(.findOriginal)) ? max(cfg.maxPerConversation, 4) : cfg.maxPerConversation
        var countPerConv: [Int64: Int] = [:]
        var picked: [Scored] = []
        for s in scored {
            if countPerConv[s.c.conv, default: 0] >= perConv { continue }
            countPerConv[s.c.conv, default: 0] += 1
            picked.append(s)
            if picked.count >= (plan.intents.contains(.findOriginal) ? 3 : cfg.maxSpans) { break }
        }

        // ---- expand to readable windows ----
        var spans: [EvidenceSpan] = []
        let titles = Dictionary(uniqueKeysWithValues: try archive.db.read { db in
            try picked.map { $0.c.conv }.map { cid in (cid, try db.queryOne("SELECT COALESCE(title,'Untitled') FROM conversation WHERE id=?", [.int(cid)]) { $0.text(0) } ?? "Untitled") }
        })
        for s in picked {
            let isSingle = s.c.lo == s.c.hi
            var lo = max(0, s.c.lo - (isSingle ? cfg.windowBefore : 0)), hi = s.c.hi + (isSingle ? cfg.windowAfter : 0)
            if isSingle, let ch = try? archive.db.read({ try $0.queryOne("SELECT first_seq, last_seq FROM chunk WHERE conversation_id=? AND first_seq<=? AND last_seq>=? AND char_start IS NULL LIMIT 1",
                                                                          [.int(s.c.conv), .int(s.c.lo), .int(s.c.lo)]) { (Int($0.int(0)), Int($0.int(1))) } }),
               ch.1 - ch.0 + 1 <= cfg.maxSpanMessages {
                // a keyword hit is read in the context of the coherent chunk it belongs to, not as an orphan line
                lo = min(lo, ch.0); hi = max(hi, ch.1)
            }
            var upper = hi
            if s.c.conv == context.currentConversationID, let tail = context.visibleTailStartSeq { upper = min(hi, tail - 1) }
            let msgs = (try? archive.messages(conversationID: s.c.conv, seqFrom: lo, seqTo: upper)) ?? s.msgs
            var channels = s.c.channels.keys.sorted()
            if s.c.vectorScore != nil && !channels.contains("vector") { channels.append("vector") }
            var reasons = s.c.reasons
            if s.c.channels["lexical"] != nil { reasons.append("keyword match") }
            if let v = s.c.vectorScore { reasons.append(String(format: "semantic match (%.2f)", v)) }
            spans.append(EvidenceSpan(conversationID: s.c.conv, conversationTitle: titles[s.c.conv] ?? "Untitled", firstSeq: lo, lastSeq: upper,
                                      anchorMessageIDs: msgs.filter { s.c.anchors.contains($0.seq) }.map(\.id), messages: msgs, score: s.score, channels: channels,
                                      reasons: reasons, termCoverage: s.coverage, vectorScore: s.c.vectorScore))
        }

        // ---- associative hop (deep queries): neighbours of the best evidence that the query never named ----
        if deep, let vectors, let top = picked.first(where: { $0.c.vectorScore != nil }) ?? picked.first {
            let ta = DispatchTime.now()
            if let chunkID = try? archive.db.read({ try $0.queryOne("SELECT id FROM chunk WHERE conversation_id=? AND first_seq<=? AND last_seq>=? ORDER BY id LIMIT 1",
                                                                     [.int(top.c.conv), .int(top.c.hi), .int(top.c.lo)]) { $0.int(0) } }),
               let qv = try? vectors.vector(forItem: chunkID), let near = try? vectors.search(qv, k: 8, nprobe: cfg.nprobe) {
                let have = Set(spans.map(\.conversationID))
                let chunks = (try? archive.chunks(ids: near.map(\.id))) ?? [:]
                for h in near where h.score >= cfg.strongVectorScore {
                    guard let c = chunks[h.id], !have.contains(c.conversationID), c.conversationID != context.currentConversationID else { continue }
                    let msgs = (try? archive.messages(conversationID: c.conversationID, seqFrom: c.firstSeq, seqTo: c.lastSeq)) ?? []
                    if msgs.isEmpty { continue }
                    let title = (try? archive.conversation(c.conversationID)?.title) ?? "Untitled"
                    spans.append(EvidenceSpan(conversationID: c.conversationID, conversationTitle: title, firstSeq: c.firstSeq, lastSeq: c.lastSeq, anchorMessageIDs: msgs.map(\.id),
                                              messages: msgs, score: Double(h.score) * 0.01, channels: ["assoc"],
                                              reasons: ["related discussion (similar to \"\(top.c.conv == c.conversationID ? "" : titles[top.c.conv] ?? "")\")"], termCoverage: 0, vectorScore: h.score))
                    if spans.count >= cfg.maxSpans + 2 { break }
                }
            }
            diag.millis["assoc"] = ms(ta)
        }

        // ---- assets ----
        var assetHits: [AssetHit] = []
        if plan.intents.contains(.findAsset) || !spans.isEmpty {
            let kinds = plan.wantsFile && !plan.wantsPhoto ? ["document", "text"] : (plan.wantsPhoto && !plan.wantsFile ? ["photo", "image"] : nil)
            if plan.intents.contains(.findAsset) {
                let tr2 = (plan.time?.hard ?? false) ? plan.time!.from...plan.time!.to : nil
                for (i, h) in ((try? lexical.searchAssets(terms: plan.terms, timeRange: tr2, kinds: kinds)) ?? []).enumerated() {
                    if let a = try? assets.asset(h.id) { assetHits.append(AssetHit(asset: a, score: 1.0 / Double(i + 1), reason: "matches text/labels/caption", linkedMessageID: nil)) }
                }
            }
            let anchorIDs = spans.flatMap { $0.messages.map(\.id) }
            for a in (try? assets.assets(linkedTo: anchorIDs)) ?? [] where !assetHits.contains(where: { $0.asset.id == a.id }) {
                if let kinds, !kinds.contains(a.kind) { continue }
                assetHits.append(AssetHit(asset: a, score: 0.8, reason: "attached in a retrieved conversation", linkedMessageID: nil))
            }
            if plan.intents.contains(.findAsset), plan.wantsPhoto, let first = spans.first?.messages.first(where: { spans.first!.anchorMessageIDs.contains($0.id) }) ?? spans.first?.messages.first {
                for a in (try? assets.assetsNear(time: first.createdAt, window: 1800, limit: 5)) ?? [] where !assetHits.contains(where: { $0.asset.id == a.id }) {
                    assetHits.append(AssetHit(asset: a, score: 0.4, reason: "taken near the time of that conversation (inferred, not attached)", linkedMessageID: first.id))
                }
            }
        }

        // ---- confidence ----
        var conf: RetrievalConfidence = .none
        if !spans.isEmpty || !memHits.isEmpty || !assetHits.isEmpty {
            let strong = spans.contains { $0.termCoverage >= 0.6 || ($0.vectorScore ?? 0) >= cfg.strongVectorScore || $0.channels.contains("memory") || $0.channels.contains("entity") } || memHits.contains { $0.reason.hasPrefix("matches") } || !assetHits.isEmpty && plan.intents.contains(.findAsset)
            conf = strong ? .good : .weak
        }
        diag.millis["total"] = ms(t0)
        diag.counts["spans"] = spans.count
        return RetrievalResult(plan: plan, spans: spans, memories: memHits, standing: standing, assets: assetHits, confidence: conf, diagnostics: diag)
    }

    // MARK: channels

    private func vectorChannel(qv: [Float]?, k: Int, hardTime: ClosedRange<Double>?) async throws -> [(VectorHit, ChunkRecord)] {
        guard let vectors, let qv else { return [] }
        let hits = try await Task.detached { [cfg = config] in try vectors.search(qv, k: k, nprobe: cfg.nprobe) }.value
        let chunks = try archive.chunks(ids: hits.map(\.id))
        var out: [(VectorHit, ChunkRecord)] = []
        for h in hits { if let c = chunks[h.id], h.score >= config.minVectorScore * 0.8 { out.append((h, c)) } }
        if let t = hardTime { out = out.filter { $0.1.t1 >= t.lowerBound && $0.1.t0 <= t.upperBound } }
        return out
    }

    private func memoryChannel(plan: QueryPlan, context: RetrievalContext, qv: [Float]?) throws -> [RankedMemory] {
        var byID: [Int64: RankedMemory] = [:]
        func add(_ m: MemoryRecord, _ boost: Double, _ reason: String) {
            let eff = memory.effectiveConfidence(m, now: context.now.timeIntervalSince1970)
            if eff < 0.15 || m.status == .retracted { return }
            let score = eff * boost
            if let e = byID[m.id], e.effectiveConfidence >= score { return }
            byID[m.id] = RankedMemory(memory: m, effectiveConfidence: score, reason: reason)
        }
        for (m, _) in try memory.search(terms: plan.terms, limit: 12) { add(m, 1.0, "matches your words") }
        if let mv = memoryVectors, let qv, let hits = try? mv.searchExact(qv, k: 8) {
            for h in hits where h.score >= config.minVectorScore { if let m = try memory.memory(h.id), m.status != .superseded { add(m, 1.0 + Double(h.score) * 0.2, "matches your meaning") } }
        }
        for m in try memory.about(entities: plan.entityIDs, limit: 12) { add(m, 1.1, "about someone you mentioned") }
        if let c = context.currentConversationID { for m in try memory.scoped(toConversation: c) { add(m, 1.2, "decision/constraint from this conversation") } }
        return byID.values.sorted { $0.effectiveConfidence > $1.effectiveConfidence }.prefix(10).map { $0 }
    }

    static func merge(_ cands: [Cand], maxLen: Int) -> [Cand] {
        let sorted = cands.sorted { ($0.conv, $0.lo, $0.hi) < ($1.conv, $1.lo, $1.hi) }
        var out: [Cand] = []
        for c in sorted {
            if var last = out.last, last.conv == c.conv, c.lo <= last.hi + 1, max(last.hi, c.hi) - last.lo + 1 <= maxLen {
                last.hi = max(last.hi, c.hi); last.anchors.formUnion(c.anchors)
                for (ch, r) in c.channels { last.channels[ch] = min(last.channels[ch] ?? Int.max, r) }
                last.t0 = min(last.t0, c.t0); last.t1 = max(last.t1, c.t1)
                last.vectorScore = [last.vectorScore, c.vectorScore].compactMap { $0 }.max()
                last.reasons.append(contentsOf: c.reasons.filter { !last.reasons.contains($0) })
                out[out.count - 1] = last
            } else { out.append(c) }
        }
        return out
    }
}
