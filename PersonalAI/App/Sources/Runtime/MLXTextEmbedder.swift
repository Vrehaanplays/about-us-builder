import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
import PersonalAICore

/// Neural text embedder running on the GPU through MLX. Query/document prefixes follow each model's published convention.
final class MLXTextEmbedder: TextEmbedder, @unchecked Sendable {
    let id: String
    let dim: Int
    let maxInputTokens: Int
    private let container: EmbedderModelContainer
    private let prefixes: EmbeddingPrefixes?

    init(directory: URL, spec: ModelSpec) async throws {
        let tokenizerLoader: any TokenizerLoader = #huggingFaceTokenizerLoader()
        container = try await EmbedderModelFactory.shared.loadContainer(from: directory, using: tokenizerLoader)
        id = "mlx:" + spec.id
        dim = spec.embeddingDim ?? 384
        maxInputTokens = min(spec.contextTokens, 512)
        prefixes = spec.promptPrefixes
    }

    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        let prefix = kind == .query ? (prefixes?.query ?? "") : (prefixes?.document ?? "")
        let maxLen = maxInputTokens
        var out: [[Float]] = []
        var i = 0
        while i < texts.count {
            let batch = Array(texts[i..<min(i + 16, texts.count)]).map { prefix + $0 }
            i += 16
            let vectors: [[Float]] = await container.perform { context -> [[Float]] in
                let encoded = batch.map { Array(context.tokenizer.encode(text: $0, addSpecialTokens: true).prefix(maxLen)) }
                let longest = max(encoded.map(\.count).max() ?? 1, 2)
                let pad = context.tokenizer.eosTokenId ?? 0
                let ids = stacked(encoded.map { MLXArray($0 + Array(repeating: pad, count: longest - $0.count)) })
                let mask = stacked(encoded.map { MLXArray(Array(repeating: true, count: $0.count) + Array(repeating: false, count: longest - $0.count)) })
                let types = MLXArray.zeros(like: ids)
                let pooled = context.pooling(context.model(ids, positionIds: nil, tokenTypeIds: types, attentionMask: mask), normalize: true, applyLayerNorm: true)
                pooled.eval()
                return pooled.map { $0.asArray(Float.self) }
            }
            out += vectors
        }
        return out.map { v in var x = v; VectorMath.normalize(&x); return x }
    }
}
