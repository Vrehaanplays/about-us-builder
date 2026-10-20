import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
import PersonalAICore

/// On-device language model via MLX. Every turn the app sends the *whole* assembled prompt; the engine forks the previous chat session
/// with that transcript, and mlx-swift-lm keeps only the part of its KV cache that the new prompt still starts with. That is what makes the
/// stable-prefix prompt layout pay off: system block + older history are never re-processed.
actor MLXEngine: InferenceEngine {
    struct Loaded: Sendable { var modelID: String; var maxContext: Int; var weightsBytes: Int; var kvBytesPerToken: Int; var loadSeconds: Double }

    private var container: ModelContainer?
    private var session: ChatSession?
    private var loaded: Loaded?
    private var kvTier: Int?
    private var running: Task<Void, Never>?

    var info: EngineInfo? {
        guard let l = loaded else { return nil }
        return EngineInfo(name: "MLX (on device)", modelID: l.modelID, locality: .local, maxContext: l.maxContext)
    }
    var loadedModel: Loaded? { loaded }

    /// Loads weights from a directory produced by `ModelStore`. Weights are memory-mapped by MLX; nothing is sent anywhere.
    func load(directory: URL, modelID: String, maxContext: Int, progress: @Sendable (String) -> Void = { _ in }) async throws {
        await unload()
        progress("Reading model")
        let t0 = Date()
        // MLX keeps freed GPU buffers cached for reuse; on a phone that cache competes with the app and the KV cache.
        MLX.Memory.cacheLimit = 128 * 1024 * 1024
        let tokenizerLoader: any TokenizerLoader = #huggingFaceTokenizerLoader()
        let c = try await loadModelContainer(from: directory, using: tokenizerLoader)
        container = c
        let weights = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension == "safetensors" }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
        let kv = (try? Data(contentsOf: directory.appendingPathComponent("config.json"))).flatMap { KVEstimator.bytesPerToken(configJSON: $0) } ?? 150_000
        loaded = Loaded(modelID: modelID, maxContext: maxContext, weightsBytes: weights, kvBytesPerToken: kv, loadSeconds: Date().timeIntervalSince(t0))
        progress("Ready")
    }

    func unload() async {
        running?.cancel(); running = nil
        session = nil; container = nil; loaded = nil; kvTier = nil
        MLX.Memory.clearCache()
    }

    func cancel() async { running?.cancel() }

    func trimMemory(unloadWeights: Bool) async {
        running?.cancel()
        session = nil; kvTier = nil
        MLX.Memory.clearCache()
        if unloadWeights { container = nil; loaded = nil }
    }

    nonisolated func generate(messages: [ChatMessage], params: GenerationParams) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task { await self.run(messages: messages, params: params, cont: cont) }
            cont.onTermination = { _ in task.cancel() }
            Task { await self.remember(task) }
        }
    }
    private func remember(_ t: Task<Void, Never>) { running = t }

    private func run(messages: [ChatMessage], params: GenerationParams, cont: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async {
        guard let container, loaded != nil else { cont.finish(throwing: EngineError.notLoaded); return }
        guard let last = messages.last, last.role == .user else { cont.finish(throwing: EngineError.failed("Nothing to answer.")); return }
        let system = messages.first(where: { $0.role == .system })?.content
        let history: [Chat.Message] = messages.dropLast().compactMap { m in
            switch m.role {
            case .user: return .user(m.content)
            case .assistant: return .assistant(m.content)
            default: return nil
            }
        }
        let tier = KVTier.choose(requested: params.maxKVSize ?? 8192, current: kvTier)
        let tierChanged = kvTier != nil && kvTier != tier
        kvTier = tier
        let gp = GenerateParameters(maxTokens: params.maxTokens, maxKVSize: tier, kvBits: params.kvBits, temperature: params.temperature, topP: params.topP)
        let additional: [String: any Sendable] = ["enable_thinking": false]
        let chat: ChatSession
        if let s = session, !tierChanged {
            chat = await s.fork(history: history)
            chat.instructions = system
            chat.generateParameters = gp
        } else {
            chat = ChatSession(container, instructions: system, history: history, generateParameters: gp, additionalContext: additional)
        }
        chat.additionalContext = additional
        session = chat

        var stats = GenerationStats()
        var strip = ThinkStripper()
        let started = Date()
        var firstToken: Date?
        do {
            for try await g in chat.streamDetails(to: last.content, role: .user) {
                try Task.checkCancellation()
                switch g {
                case .chunk(let s):
                    if firstToken == nil { firstToken = Date() }
                    let visible = strip.push(s)
                    if !visible.isEmpty { cont.yield(.token(visible)) }
                case .info(let i):
                    stats.promptTokens = i.totalPromptTokenCount
                    stats.reusedPrefixTokens = i.cachedPromptTokenCount
                    stats.generatedTokens = i.generationTokenCount
                    stats.tokensPerSecond = i.tokensPerSecond
                    stats.prefillTokensPerSecond = i.promptTokensPerSecond
                default: break
                }
            }
            let tail = strip.finish()
            if !tail.isEmpty { cont.yield(.token(tail)) }
            stats.timeToFirstTokenMs = firstToken.map { $0.timeIntervalSince(started) * 1000 }
            cont.yield(.finished(stats))
            cont.finish()
        } catch is CancellationError {
            cont.finish(throwing: EngineError.cancelled)
        } catch {
            cont.finish(throwing: EngineError.failed(error.localizedDescription))
        }
    }
}
