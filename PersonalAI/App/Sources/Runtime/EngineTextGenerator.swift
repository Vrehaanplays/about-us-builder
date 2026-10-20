import Foundation
import PersonalAICore

/// Lets the memory extractor use the on-device chat model. Runs in an isolated session so the user's conversation cache is untouched.
struct EngineTextGenerator: TextGenerator {
    let engine: MLXEngine
    let modelName: String
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        var p = GenerationParams()
        p.maxTokens = maxTokens; p.temperature = 0.1; p.maxKVSize = 4096; p.isolated = true
        var out = ""
        for try await ev in engine.generate(messages: [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)], params: p) {
            if case .token(let t) = ev { out += t }
        }
        return out
    }
}
