import XCTest
@testable import PersonalAICore

/// Whole pipeline: real importer → chunk/embed → memory extraction → hybrid retrieval → prompt assembly → grounded answer.
final class EndToEndTests: XCTestCase {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pai-e2e-\(UUID().uuidString)") }

    /// Always runs. The hashing embedder is lexical only, so this asserts the properties that must hold *without* semantics:
    /// exact recall, identifiers, abstention, citation validity. Paraphrase is deliberately not asserted here.
    func testLexicalPipelineIsExactAndAbstainsWhenUnsupported() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let rep = try await EvalSuite.run(embedder: HashingEmbedder(dim: 256), realEmbedder: false, noiseMessages: 1500, dir: dir)
        for id in ["floor-exact", "locker", "alex-work", "abstain-passport", "abstain-sister"] {
            let r = rep.cases.first { $0.id == id }!
            XCTAssertTrue(r.passed, "\(id): \(r.answer)")
        }
        XCTAssertTrue(rep.cases.allSatisfy { $0.citationsValid }, "no answer may quote text that is not in the cited archive message")
    }

    /// Runs only where the MiniLM ONNX files exist (see docs/EVAL.md); skipped otherwise rather than silently passing.
    func testNeuralPipelineMeetsRetrievalFloors() async throws {
        let model = ProcessInfo.processInfo.environment["PAI_MINILM_DIR"] ?? "/tmp/claude-0/minilm"
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tools/embed_server.py").path
        guard let e = ProcessEmbedder(script: script, modelDir: model) else { throw XCTSkip("MiniLM ONNX model not available") }
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let rep = try await EvalSuite.run(embedder: e, realEmbedder: true, noiseMessages: 1500, dir: dir)
        print("neural e2e: tuned \(rep.tunedPassRate) h \(rep.heldOutPassRate) g \(rep.heldOut2PassRate) hit@3 \(rep.hitAt3)")
        XCTAssertGreaterThanOrEqual(rep.tunedPassRate, 0.9)
        XCTAssertGreaterThanOrEqual(rep.heldOut2PassRate, 0.5, "regression floor on the untouched batch, not a quality claim")
        XCTAssertTrue(rep.cases.allSatisfy { $0.citationsValid })
        XCTAssertEqual(rep.abstainRate, 1.0)
    }
}
