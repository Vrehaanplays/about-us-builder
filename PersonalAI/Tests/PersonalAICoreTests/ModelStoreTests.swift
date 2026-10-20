import XCTest
@testable import PersonalAICore

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var files: [String: Data] = [:]           // path -> bytes
    var lfsSha: [String: String] = [:]
    var corrupt: Set<String> = []
    var stallAfter: Int64?                    // simulate a connection drop / pause after N bytes of the next download
    private(set) var requestedOffsets: [Int64] = []
    private(set) var urls: [URL] = []
    let lock = NSLock()

    func getJSON(_ url: URL, headers: [String: String]) async throws -> Data {
        lock.withLock { urls.append(url) }
        var arr: [[String: Any]] = files.map { path, d in
            var o: [String: Any] = ["type": "file", "path": path, "size": d.count]
            if let s = lfsSha[path] { o["lfs"] = ["oid": s] }
            return o
        }
        arr.append(["type": "file", "path": "README.md", "size": 10])
        arr.append(["type": "file", "path": "onnx/model.onnx", "size": 10])
        arr.append(["type": "directory", "path": "onnx"])
        return try JSONSerialization.data(withJSONObject: arr)
    }

    func download(_ url: URL, to file: URL, resumeFrom offset: Int64, headers: [String: String], progress: @Sendable @escaping (Int64) -> Void) async throws -> Int64 {
        lock.withLock { urls.append(url); requestedOffsets.append(offset) }
        let name = url.pathComponents.last!
        var data = files[name]!
        if corrupt.contains(name) { data[0] ^= 0xff }
        if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
        let h = try FileHandle(forWritingTo: file); defer { try? h.close() }
        try h.seekToEnd()
        var pos = Int(offset)
        let step = 1000
        var written: Int64 = 0
        while pos < data.count {
            try Task.checkCancellation()
            let end = min(data.count, pos + step)
            try h.write(contentsOf: data[pos..<end]); pos = end; written += Int64(end - Int(offset) - Int(written) > 0 ? step : 0)
            progress(Int64(pos))
            if let s = stallAfter, Int64(pos) >= s { stallAfter = nil; throw CancellationError() }
            await Task.yield()
        }
        return Int64(pos)
    }
}

final class ModelStoreTests: XCTestCase {
    func sha(_ d: Data) -> String { SHA256Hasher.hex(of: d) }

    func testSHA256MatchesKnownVectors() {
        XCTAssertEqual(SHA256Hasher.hex(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Hasher.hex(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Data(String(repeating: "a", count: 1_000_000).utf8)
        XCTAssertEqual(SHA256Hasher.hex(of: long), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func waitFor(_ store: ModelStore, _ id: String, timeout: Double = 10, _ pred: (ModelState) -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if pred(await store.state(of: id)) { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("timeout; state = \(await store.state(of: id))")
    }

    func fixture() -> (FakeTransport, Data, Data) {
        let t = FakeTransport()
        let weights = Data((0..<20_000).map { UInt8($0 % 251) })
        let cfg = Data(#"{"num_hidden_layers": 4}"#.utf8)
        t.files = ["model.safetensors": weights, "config.json": cfg, "tokenizer.json": Data("{}".utf8)]
        t.lfsSha = ["model.safetensors": sha(weights)]
        return (t, weights, cfg)
    }

    func testDownloadVerifiesAndInstallsOnlyNeededFiles() async throws {
        let (t, weights, _) = fixture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID())"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelStore(root: dir, transport: t, ledger: NetworkLedger())
        await store.start("mlx-community/Test-4bit")
        try await waitFor(store, "mlx-community/Test-4bit") { if case .installed = $0 { return true }; return false }
        let d = await store.directory(for: "mlx-community/Test-4bit")
        XCTAssertEqual(try Data(contentsOf: d.appendingPathComponent("model.safetensors")), weights)
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("README.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("onnx").path))
        let ids = await store.installedModelIDs()
        XCTAssertEqual(ids, ["mlx-community/Test-4bit"])
        XCTAssertTrue(t.urls.allSatisfy { NetworkPolicy.isAllowedModelHost($0.host ?? "") }, "only the model host is contacted")
    }

    func testPauseThenResumeContinuesFromTheByteOffsetAndSurvivesRestart() async throws {
        let (t, weights, _) = fixture()
        t.stallAfter = 7_000
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID())"); defer { try? FileManager.default.removeItem(at: dir) }
        var store = ModelStore(root: dir, transport: t, ledger: NetworkLedger())
        let id = "mlx-community/Test-4bit"
        await store.start(id)
        try await waitFor(store, id) { if case .paused = $0 { return true }; return false }
        // "kill the app": a brand-new store over the same folder rediscovers the partial download
        store = ModelStore(root: dir, transport: t, ledger: NetworkLedger())
        if case .paused(let got, let total) = await store.state(of: id) { XCTAssertGreaterThan(got, 0); XCTAssertGreaterThan(total, got) } else { XCTFail("expected paused after restart") }
        await store.start(id)
        try await waitFor(store, id) { if case .installed = $0 { return true }; return false }
        XCTAssertTrue(t.requestedOffsets.contains { $0 >= 7_000 }, "second attempt resumed at the saved offset, got \(t.requestedOffsets)")
        let d = await store.directory(for: id)
        XCTAssertEqual(try Data(contentsOf: d.appendingPathComponent("model.safetensors")), weights)
    }

    func testCorruptDownloadIsDiscardedNotInstalled() async throws {
        let (t, _, _) = fixture(); t.corrupt = ["model.safetensors"]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID())"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelStore(root: dir, transport: t, ledger: NetworkLedger())
        let id = "mlx-community/Test-4bit"
        await store.start(id)
        try await waitFor(store, id) { if case .failed = $0 { return true }; return false }
        let d = await store.directory(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("model.safetensors").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("model.safetensors.part").path))
        let ids = await store.installedModelIDs()
        XCTAssertTrue(ids.isEmpty)
    }

    func testInsufficientSpaceIsRefusedBeforeAnyDownload() async throws {
        let (t, _, _) = fixture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID())"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelStore(root: dir, transport: t, ledger: NetworkLedger(), freeSpace: { 1000 })
        let id = "mlx-community/Test-4bit"
        await store.start(id)
        try await waitFor(store, id) { if case .failed(let m) = $0 { return m.contains("Not enough free space") }; return false }
        XCTAssertTrue(t.requestedOffsets.isEmpty)
    }

    func testRemoveDeletesEverything() async throws {
        let (t, _, _) = fixture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID())"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelStore(root: dir, transport: t, ledger: NetworkLedger())
        let id = "mlx-community/Test-4bit"
        await store.start(id)
        try await waitFor(store, id) { if case .installed = $0 { return true }; return false }
        await store.remove(id)
        let st = await store.state(of: id)
        XCTAssertEqual(st, .notInstalled)
        let d = await store.directory(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.path))
    }

    func testKVEstimatorUsesConfigNotConstants() {
        let qwen4b = #"{"num_hidden_layers":36,"num_attention_heads":32,"num_key_value_heads":8,"head_dim":128,"hidden_size":2560}"#
        XCTAssertEqual(KVEstimator.bytesPerToken(configJSON: Data(qwen4b.utf8)), 2 * 36 * 8 * 128 * 2)
        let q8 = KVEstimator.bytesPerToken(configJSON: Data(qwen4b.utf8), kvBits: 8)!
        XCTAssertLessThan(q8, 2 * 36 * 8 * 128 * 2 * 6 / 10)
        let hybrid = #"{"text_config":{"num_hidden_layers":24,"num_attention_heads":8,"num_key_value_heads":2,"head_dim":256,"layer_types":["linear_attention","linear_attention","linear_attention","full_attention","linear_attention","linear_attention","linear_attention","full_attention","linear_attention","linear_attention","linear_attention","full_attention","linear_attention","linear_attention","linear_attention","full_attention","linear_attention","linear_attention","linear_attention","full_attention","linear_attention","linear_attention","linear_attention","full_attention"]}}"#
        XCTAssertEqual(KVEstimator.bytesPerToken(configJSON: Data(hybrid.utf8)), 2 * 6 * 2 * 256 * 2, "only full-attention layers grow with context")
    }

    func testCatalogueHasOneDefaultChatAndEmbedderAndAllIDsAreWellFormed() {
        XCTAssertNotNil(ModelCatalog.spec(ModelCatalog.defaultChatID)); XCTAssertNotNil(ModelCatalog.spec(ModelCatalog.defaultEmbedderID))
        for m in ModelCatalog.all { XCTAssertEqual(m.id.split(separator: "/").count, 2, m.id) }
        XCTAssertEqual(Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count)
    }
}
