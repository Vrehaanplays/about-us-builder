import Foundation

public enum ModelRole: String, Sendable, Codable { case chat, embedder }

/// How much we actually know about a catalogue entry. Nothing here is "verified on the target iPhone": that status only appears
/// after the in-app benchmark has run on the device (see `DeviceMeasurement`).
public enum ModelEvidence: String, Sendable, Codable {
    /// The repo id appears in the pinned mlx-swift-lm model registry, i.e. the architecture is implemented by the runtime we ship.
    case runtimeRegistry
    /// The architecture is implemented by the runtime (checked in its source) but this exact repo id is a community conversion.
    case architectureSupported
}

public struct ModelSpec: Sendable, Codable, Identifiable, Hashable {
    public var id: String                     // Hugging Face repo id
    public var displayName: String
    public var family: String
    public var role: ModelRole
    public var parametersBillions: Double
    public var quantisation: String
    /// Rough download size for display *before* the real file list is fetched. The real size always comes from the Hub API.
    public var approxDownloadGB: Double
    public var contextTokens: Int
    public var license: String
    public var licenseChecked: Bool
    public var evidence: ModelEvidence
    public var blurb: String
    public var embeddingDim: Int?
    public var promptPrefixes: EmbeddingPrefixes?
    /// Chat models only: smallest iPhone memory class we would suggest it for. A heuristic, not a measurement.
    public var suggestedMinRAMGB: Int
}

public struct EmbeddingPrefixes: Sendable, Codable, Hashable { public var query: String; public var document: String }

public enum ModelCatalog {
    public static let chat: [ModelSpec] = [
        ModelSpec(id: "mlx-community/Qwen3-4B-4bit", displayName: "Qwen3 4B", family: "Qwen3", role: .chat, parametersBillions: 4.0, quantisation: "4-bit",
                  approxDownloadGB: 2.3, contextTokens: 32_768, license: "Apache-2.0", licenseChecked: true, evidence: .runtimeRegistry,
                  blurb: "Best general quality that fits an 8 GB iPhone with room for a long context. Default.", embeddingDim: nil, promptPrefixes: nil, suggestedMinRAMGB: 8),
        ModelSpec(id: "mlx-community/Qwen3-1.7B-4bit", displayName: "Qwen3 1.7B", family: "Qwen3", role: .chat, parametersBillions: 1.7, quantisation: "4-bit",
                  approxDownloadGB: 1.0, contextTokens: 32_768, license: "Apache-2.0", licenseChecked: true, evidence: .runtimeRegistry,
                  blurb: "Fast and light; good for quick questions and background memory extraction.", embeddingDim: nil, promptPrefixes: nil, suggestedMinRAMGB: 6),
        ModelSpec(id: "mlx-community/Qwen3-0.6B-4bit", displayName: "Qwen3 0.6B", family: "Qwen3", role: .chat, parametersBillions: 0.6, quantisation: "4-bit",
                  approxDownloadGB: 0.4, contextTokens: 32_768, license: "Apache-2.0", licenseChecked: true, evidence: .runtimeRegistry,
                  blurb: "Tiny. Useful as a smoke test and for very old phones; expect weak reasoning.", embeddingDim: nil, promptPrefixes: nil, suggestedMinRAMGB: 4),
        ModelSpec(id: "mlx-community/gemma-4-e2b-it-4bit", displayName: "Gemma 4 E2B", family: "Gemma 4", role: .chat, parametersBillions: 2.0, quantisation: "4-bit",
                  approxDownloadGB: 3.0, contextTokens: 32_768, license: "see model card", licenseChecked: false, evidence: .runtimeRegistry,
                  blurb: "Google's small multimodal-capable family. Size estimate is rough: check the exact size shown before downloading.", embeddingDim: nil, promptPrefixes: nil, suggestedMinRAMGB: 8),
        ModelSpec(id: "mlx-community/gemma-4-e4b-it-4bit", displayName: "Gemma 4 E4B", family: "Gemma 4", role: .chat, parametersBillions: 4.0, quantisation: "4-bit",
                  approxDownloadGB: 5.0, contextTokens: 32_768, license: "see model card", licenseChecked: false, evidence: .runtimeRegistry,
                  blurb: "Larger Gemma 4. Probably too heavy for an 8 GB phone alongside a long context; shown so you can see the real size and decide.", embeddingDim: nil, promptPrefixes: nil, suggestedMinRAMGB: 12),
        ModelSpec(id: "mlx-community/gemma-3-1b-it-qat-4bit", displayName: "Gemma 3 1B (QAT)", family: "Gemma 3", role: .chat, parametersBillions: 1.0, quantisation: "4-bit QAT",
                  approxDownloadGB: 0.75, contextTokens: 32_768, license: "Gemma Terms of Use", licenseChecked: false, evidence: .runtimeRegistry,
                  blurb: "Very small and quantisation-aware trained, so it keeps quality at 4-bit.", embeddingDim: nil, promptPrefixes: nil, suggestedMinRAMGB: 4),
        ModelSpec(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B", family: "Llama 3.2", role: .chat, parametersBillions: 3.2, quantisation: "4-bit",
                  approxDownloadGB: 1.8, contextTokens: 131_072, license: "Llama 3.2 Community License", licenseChecked: false, evidence: .runtimeRegistry,
                  blurb: "Solid all-rounder with a very long architectural context.", embeddingDim: nil, promptPrefixes: nil, suggestedMinRAMGB: 6),
        ModelSpec(id: "mlx-community/SmolLM3-3B-4bit", displayName: "SmolLM3 3B", family: "SmolLM3", role: .chat, parametersBillions: 3.0, quantisation: "4-bit",
                  approxDownloadGB: 1.8, contextTokens: 65_536, license: "Apache-2.0", licenseChecked: false, evidence: .runtimeRegistry,
                  blurb: "Fully open small model with long-context training.", embeddingDim: nil, promptPrefixes: nil, suggestedMinRAMGB: 6),
    ]

    public static let embedders: [ModelSpec] = [
        ModelSpec(id: "sentence-transformers/all-MiniLM-L6-v2", displayName: "MiniLM-L6 (384-d)", family: "MiniLM", role: .embedder, parametersBillions: 0.022, quantisation: "fp32",
                  approxDownloadGB: 0.09, contextTokens: 256, license: "Apache-2.0", licenseChecked: true, evidence: .runtimeRegistry,
                  blurb: "Default. Small, fast; this is the model our retrieval evaluation was run with (ONNX build of the same weights).", embeddingDim: 384, promptPrefixes: nil, suggestedMinRAMGB: 4),
        ModelSpec(id: "BAAI/bge-small-en-v1.5", displayName: "BGE small (384-d)", family: "BGE", role: .embedder, parametersBillions: 0.033, quantisation: "fp32",
                  approxDownloadGB: 0.13, contextTokens: 512, license: "MIT", licenseChecked: true, evidence: .runtimeRegistry,
                  blurb: "Slightly stronger English retrieval, longer inputs. Needs a query instruction prefix.", embeddingDim: 384,
                  promptPrefixes: EmbeddingPrefixes(query: "Represent this sentence for searching relevant passages: ", document: ""), suggestedMinRAMGB: 4),
        ModelSpec(id: "intfloat/multilingual-e5-small", displayName: "Multilingual E5 small (384-d)", family: "E5", role: .embedder, parametersBillions: 0.118, quantisation: "fp32",
                  approxDownloadGB: 0.47, contextTokens: 512, license: "MIT", licenseChecked: false, evidence: .runtimeRegistry,
                  blurb: "Use if your conversations are not mostly English.", embeddingDim: 384,
                  promptPrefixes: EmbeddingPrefixes(query: "query: ", document: "passage: "), suggestedMinRAMGB: 4),
        ModelSpec(id: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", displayName: "Qwen3 Embedding 0.6B", family: "Qwen3 Embedding", role: .embedder, parametersBillions: 0.6, quantisation: "4-bit DWQ",
                  approxDownloadGB: 0.4, contextTokens: 8192, license: "Apache-2.0", licenseChecked: false, evidence: .runtimeRegistry,
                  blurb: "Highest-quality option here; slower to index a large archive.", embeddingDim: 1024,
                  promptPrefixes: EmbeddingPrefixes(query: "Instruct: Given a question, retrieve the passages from past conversations that answer it\nQuery: ", document: ""), suggestedMinRAMGB: 6),
    ]

    public static var all: [ModelSpec] { chat + embedders }
    public static let defaultChatID = "mlx-community/Qwen3-4B-4bit"
    public static let defaultEmbedderID = "sentence-transformers/all-MiniLM-L6-v2"
    public static func spec(_ id: String) -> ModelSpec? { all.first { $0.id == id } }

    /// Ordered suggestions for a device with `ramGB` of memory. Purely a heuristic until a model has been benchmarked on that device.
    public static func suggestions(ramGB: Int) -> [ModelSpec] { chat.filter { $0.suggestedMinRAMGB <= ramGB } }
}

/// KV-cache cost per token, computed from the model's own config.json (never hand-typed), so the context planner uses real numbers.
public enum KVEstimator {
    public static func bytesPerToken(configJSON: Data, kvBits: Int? = nil) -> Int? {
        guard var cfg = (try? JSONSerialization.jsonObject(with: configJSON)) as? [String: Any] else { return nil }
        if let t = cfg["text_config"] as? [String: Any] { cfg = t }           // multimodal wrappers nest the language model config
        func int(_ k: String) -> Int? { (cfg[k] as? Int) ?? (cfg[k] as? Double).map(Int.init) }
        guard let layers = int("num_hidden_layers"), let heads = int("num_attention_heads") else { return nil }
        let kvHeads = int("num_key_value_heads") ?? heads
        let hidden = int("hidden_size") ?? 0
        let headDim = int("head_dim") ?? (hidden > 0 ? hidden / heads : 128)
        var attnLayers = layers
        if let types = cfg["layer_types"] as? [String] {                       // hybrid models: only full-attention layers grow with context
            attnLayers = types.filter { $0 == "full_attention" || $0 == "attention" }.count
            if attnLayers == 0 { attnLayers = layers }
        }
        let bytesPerElement = Double(kvBits.map { Double($0) / 8.0 + 0.0625 } ?? 2.0)      // fp16, or n-bit + group scale overhead
        return Int(Double(2 * attnLayers * kvHeads * headDim) * bytesPerElement)
    }
}
