import SwiftUI
import PersonalAICore
import MLXLLM
import MLXLMCommon
import MLXEmbedders
import MLXHuggingFace
import HuggingFace
import Tokenizers

@main
struct PersonalAIApp: App {
    var body: some Scene {
        WindowGroup {
            let loader: any TokenizerLoader = #huggingFaceTokenizerLoader()
            Text("Personal AI \(String(describing: type(of: loader)))")
        }
    }
}
