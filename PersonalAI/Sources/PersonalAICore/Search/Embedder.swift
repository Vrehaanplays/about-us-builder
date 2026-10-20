import Foundation

public enum EmbeddingKind: Sendable { case document, query }

/// Retrieval component only: maps text to vectors. Reasoning happens in the language model, over the retrieved *messages*.
public protocol TextEmbedder: Sendable {
    var id: String { get }              // stable identity; a change means every vector must be rebuilt
    var dim: Int { get }
    var maxInputTokens: Int { get }
    /// Returns L2-normalised vectors.
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]]
}

/// Matryoshka-style truncation wrapper: models such as EmbeddingGemma and Qwen3-Embedding keep most quality at smaller prefixes,
/// letting the index store 256 dims instead of 768/1024 (3-4x less storage and scan bandwidth).
public struct TruncatingEmbedder: TextEmbedder {
    let base: any TextEmbedder
    public let dim: Int
    public var id: String { "\(base.id)@\(dim)" }
    public var maxInputTokens: Int { base.maxInputTokens }
    public init(_ base: any TextEmbedder, dim: Int) { self.base = base; self.dim = min(dim, base.dim) }
    public func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        try await base.embed(texts, kind: kind).map { v in
            var t = Array(v.prefix(dim))
            VectorMath.normalize(&t)
            return t
        }
    }
}

/// Deterministic feature-hashing embedder (word uni/bi-grams + char trigrams). It captures *lexical* overlap, not meaning.
/// Used as (a) an always-available fallback before a neural model is downloaded, and (b) a deterministic test double.
/// It is never presented as semantic search.
public struct HashingEmbedder: TextEmbedder {
    public let dim: Int
    public var id: String { "hashing-v1@\(dim)" }
    public var maxInputTokens: Int { 512 }
    public init(dim: Int = 256) { self.dim = dim }

    public func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] { texts.map(embedOne) }

    public func embedOne(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        let words = TextNorm.words(text)
        func add(_ s: String, _ w: Float) {
            let h = Hash64.of(s)
            let idx = Int(h % UInt64(dim))
            v[idx] += ((h >> 40) & 1) == 0 ? w : -w
        }
        for (i, w) in words.enumerated() {
            if Self.stop.contains(w) { continue }
            add(w, 1)
            if i + 1 < words.count { add(w + " " + words[i + 1], 0.6) }
            if w.count >= 5 {
                let u = Array(w.unicodeScalars)
                for j in 0..<(u.count - 2) { add(String(String.UnicodeScalarView(u[j..<j + 3])), 0.25) }
            }
        }
        for i in 0..<dim { v[i] = v[i] == 0 ? 0 : (v[i] > 0 ? 1 : -1) * (abs(v[i])).squareRoot() }   // sublinear tf
        VectorMath.normalize(&v)
        return v
    }

    static let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "is", "it", "that", "for", "on", "with", "as", "was", "are", "be", "this", "i", "you", "my", "me", "we", "do", "did", "at", "by", "so", "but"]
}

public enum VectorMath {
    public static func normalize(_ v: inout [Float]) {
        var s: Float = 0
        for x in v { s += x * x }
        guard s > 0 else { return }
        let inv = 1 / s.squareRoot()
        for i in v.indices { v[i] *= inv }
    }
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        let n = min(a.count, b.count)
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in for i in 0..<n { s += pa[i] * pb[i] } } }
        return s
    }
}
