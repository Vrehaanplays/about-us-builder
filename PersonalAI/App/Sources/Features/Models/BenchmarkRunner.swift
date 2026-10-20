import Foundation
import Observation
import MLX
import PersonalAICore

/// Measures what only a real device can tell us. Every number written to the report comes from a timer or counter on this phone;
/// nothing is estimated. The JSON is the artefact to compare against the Linux harness (which is explicitly NOT a phone).
@MainActor @Observable
final class BenchmarkRunner {
    struct Step: Identifiable { var id = UUID(); var title: String; var state: State = .pending; var detail = ""; enum State { case pending, running, done, skipped, failed } }

    struct Report: Codable {
        var startedAt: Date
        var device: [String: String]
        var model: [String: String]
        var generation: [[String: Double]] = []
        var prefixReuse: [String: Double] = [:]
        var sustained: [String: Double] = [:]
        var embedder: [String: Double] = [:]
        var archive: [[String: Double]] = []
        var notes: [String] = []
    }

    var steps: [Step] = []
    var running = false
    var report: Report?
    var reportURL: URL?
    var fraction = 0.0
    private var task: Task<Void, Never>?

    enum Mode { case quick, full }

    func start(app: AppModel, mode: Mode) {
        guard !running else { return }
        running = true; report = nil; reportURL = nil; fraction = 0
        steps = [Step(title: "Device snapshot"), Step(title: "Model load"), Step(title: "Prompt-size sweep"), Step(title: "Prefix reuse"),
                 Step(title: "Sustained generation"), Step(title: "Embedding speed"), Step(title: "Archive scale on this phone")]
        task = Task { await run(app: app, mode: mode); running = false }
    }
    func cancel() { task?.cancel() }

    private func set(_ i: Int, _ s: Step.State, _ d: String = "") { steps[i].state = s; if !d.isEmpty { steps[i].detail = d }; fraction = Double(i + (s == .running ? 0 : 1)) / Double(steps.count) }

    private func run(app: AppModel, mode: Mode) async {
        let startThermal = DeviceInfo.thermal
        var r = Report(startedAt: Date(), device: [:], model: [:])
        // 0 device
        set(0, .running)
        r.device = ["machine": DeviceInfo.machine, "os": DeviceInfo.osVersion, "simulator": String(DeviceInfo.isSimulator),
                    "physicalMemoryGB": String(format: "%.1f", Double(DeviceInfo.physicalMemoryBytes) / 1e9),
                    "availableMemoryMB": String(DeviceInfo.availableMemoryBytes / 1_048_576), "thermalAtStart": "\(startThermal)",
                    "lowPowerMode": String(DeviceInfo.lowPowerMode), "charging": String(DeviceInfo.isCharging), "battery": String(format: "%.0f%%", DeviceInfo.batteryLevel * 100)]
        if DeviceInfo.isSimulator { r.notes.append("Simulator: MLX/Metal numbers are not representative. Run on a physical iPhone.") }
        set(0, .done, "\(DeviceInfo.machine) · iOS \(DeviceInfo.osVersion) · \(r.device["availableMemoryMB"]!) MB free")

        // 1 model
        set(1, .running)
        guard let loaded = await app.engine.loadedModel, let id = app.loadedChatModelID else {
            set(1, .failed, "Load a chat model in Models first."); for i in 2...5 { set(i, .skipped) }
            await archiveScale(&r, app: app, mode: mode); finish(r); return
        }
        r.model = ["id": id, "loadSeconds": String(format: "%.1f", loaded.loadSeconds), "weightsMB": String(loaded.weightsBytes / 1_048_576),
                   "kvBytesPerToken": String(loaded.kvBytesPerToken), "availableMBAfterLoad": String(DeviceInfo.availableMemoryBytes / 1_048_576),
                   "mlxActiveMB": String(MLX.Memory.activeMemory / 1_048_576)]
        set(1, .done, "loaded in \(r.model["loadSeconds"]!) s · \(r.model["weightsMB"]!) MB weights")
        if Task.isCancelled { finish(r); return }

        // 2 sweep
        set(2, .running)
        let sizes = mode == .quick ? [256, 1024, 2048] : [256, 1024, 2048, 4096, 8192]
        for n in sizes {
            if Task.isCancelled { break }
            let before = DeviceInfo.availableMemoryBytes
            if before < 450 * 1_048_576 { r.notes.append("Stopped sweep at \(n) tokens: only \(before / 1_048_576) MB headroom left."); break }
            await app.engine.trimMemory(unloadWeights: false)
            if let m = await measure(app, promptTokens: n, generate: 24) {
                var row: [String: Double] = ["promptTokens": Double(m.stats.promptTokens), "ttftMs": m.stats.timeToFirstTokenMs ?? -1, "prefillTPS": m.stats.prefillTokensPerSecond ?? -1,
                                             "decodeTPS": m.stats.tokensPerSecond ?? -1, "availableMBAfter": Double(DeviceInfo.availableMemoryBytes / 1_048_576), "mlxPeakMB": Double(MLX.Memory.peakMemory / 1_048_576)]
                row["thermalState"] = Double(DeviceInfo.thermal.rawValue)
                r.generation.append(row)
                steps[2].detail = "\(m.stats.promptTokens) tok → first word in \(Int(m.stats.timeToFirstTokenMs ?? 0)) ms"
            } else { r.notes.append("Generation failed at \(n) tokens."); break }
        }
        set(2, .done, steps[2].detail)

        // 3 prefix reuse
        set(3, .running)
        if !Task.isCancelled, let a = await measure(app, promptTokens: 2000, generate: 8, tail: "Question one: what is the first word above?"),
           let b = await measure(app, promptTokens: 2000, generate: 8, tail: "Question two: what is the last word above?", keepSession: true) {
            r.prefixReuse = ["coldTTFTms": a.stats.timeToFirstTokenMs ?? -1, "warmTTFTms": b.stats.timeToFirstTokenMs ?? -1,
                             "reusedTokens": Double(b.stats.reusedPrefixTokens), "promptTokens": Double(b.stats.promptTokens)]
            set(3, .done, "cold \(Int(a.stats.timeToFirstTokenMs ?? 0)) ms → warm \(Int(b.stats.timeToFirstTokenMs ?? 0)) ms (reused \(b.stats.reusedPrefixTokens) tokens)")
        } else { set(3, .failed, "could not measure") }

        // 4 sustained
        set(4, .running)
        if mode == .quick { set(4, .skipped, "Full mode only") } else if !Task.isCancelled {
            let t0 = Date(); var windows: [Double] = []
            while Date().timeIntervalSince(t0) < 90, !Task.isCancelled {
                if let m = await measure(app, promptTokens: 512, generate: 96, keepSession: false), let t = m.stats.tokensPerSecond { windows.append(t); steps[4].detail = String(format: "%.1f tok/s, thermal %@", t, "\(DeviceInfo.thermal)") }
                else { break }
            }
            if let first = windows.first, let last = windows.last {
                r.sustained = ["seconds": Date().timeIntervalSince(t0), "firstTPS": first, "lastTPS": last, "minTPS": windows.min() ?? 0, "runs": Double(windows.count), "thermalEnd": Double(DeviceInfo.thermal.rawValue), "batteryEnd": Double(DeviceInfo.batteryLevel)]
            }
            set(4, .done, steps[4].detail)
        }

        // 5 embedder
        set(5, .running)
        if let svc = app.services, app.loadedEmbedderID != nil {
            let texts = (0..<200).map { "Passage \($0): " + String(repeating: "the quick brown fox jumps over the lazy dog and talks about project \($0 % 7). ", count: 6) }
            let t0 = Date()
            _ = try? await svc.embedder.embed(texts, kind: .document)
            let secs = Date().timeIntervalSince(t0)
            r.embedder = ["texts": 200, "seconds": secs, "textsPerSecond": 200 / max(secs, 0.001)]
            set(5, .done, String(format: "%.0f passages/s", 200 / max(secs, 0.001)))
        } else { set(5, .skipped, "No embedding model loaded") }

        await archiveScale(&r, app: app, mode: mode)
        finish(r)
    }

    private func archiveScale(_ r: inout Report, app: AppModel, mode: Mode) async {
        set(6, .running)
        let sizes = mode == .quick ? [20_000] : [50_000, 200_000]
        for n in sizes {
            if Task.isCancelled { break }
            steps[6].detail = "\(n.formatted()) messages…"
            let result = await Task.detached(priority: .utility) { await Self.archiveBench(messages: n) }.value
            if let row = result { r.archive.append(row); steps[6].detail = String(format: "%d msgs: insert %.0f msg/s, retrieve p50 %.0f ms", n, row["insertMsgsPerSec"] ?? 0, row["retrieveP50ms"] ?? 0) }
        }
        set(6, .done, steps[6].detail)
    }

    nonisolated static func archiveBench(messages n: Int) async -> [String: Double]? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let s = try? PersonalAIServices(directory: dir, embedder: HashingEmbedder(dim: 256)) else { return nil }
        let t0 = Date()
        guard let needles = try? SyntheticArchive(seed: 5).generate(into: s.archive, messages: n, years: 10, needles: 40) else { return nil }
        let insert = Date().timeIntervalSince(t0)
        let t1 = Date()
        _ = try? s.pipeline.chunkStep(conversations: Int.max)
        while ((try? await s.pipeline.embedStep()) ?? 0) > 0 {}
        let index = Date().timeIntervalSince(t1)
        var lat: [Double] = []; var hits = 0
        for nd in needles {
            let t = Date()
            if let r = try? await s.retriever.retrieve(nd.query), r.spans.prefix(3).contains(where: { $0.messages.contains { $0.text == nd.messageText } }) { hits += 1 }
            lat.append(Date().timeIntervalSince(t) * 1000)
        }
        lat.sort()
        let st = try? s.archive.stats()
        return ["messages": Double(n), "insertMsgsPerSec": Double(n) / max(insert, 0.001), "indexSeconds": index, "dbMB": Double(st?.dbBytes ?? 0) / 1e6,
                "retrieveP50ms": lat[lat.count / 2], "retrieveP95ms": lat[min(lat.count - 1, Int(Double(lat.count) * 0.95))], "needleHitAt3": Double(hits) / Double(max(1, needles.count))]
    }

    private struct Measured { var stats: GenerationStats }

    private func measure(_ app: AppModel, promptTokens: Int, generate: Int, tail: String = "Reply with the single word OK.", keepSession: Bool = false) async -> Measured? {
        let filler = "The committee reviewed the quarterly logistics report and noted the shipping schedule for the northern depot, the warehouse staffing plan, and the maintenance budget. "
        let text = String(String(repeating: filler, count: promptTokens / 30 + 1).prefix(promptTokens * 4))
        let msgs = [ChatMessage(role: .system, content: "You are a benchmark assistant. Be brief."), ChatMessage(role: .user, content: text + "\n\n" + tail)]
        var p = GenerationParams(); p.maxTokens = generate; p.maxKVSize = max(4096, promptTokens + generate + 256); p.temperature = 0
        var stats = GenerationStats()
        do { for try await ev in app.engine.generate(messages: msgs, params: p) { if case .finished(let s) = ev { stats = s } } } catch { return nil }
        return Measured(stats: stats)
    }

    private func finish(_ r: Report) {
        report = r
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(r) {
            let dir = FileManager.default.temporaryDirectory
            let stamp = ISO8601DateFormatter().string(from: r.startedAt).replacingOccurrences(of: ":", with: "-")
            let url = dir.appendingPathComponent("personalai-benchmark-\(DeviceInfo.machine)-\(stamp).json")
            try? data.write(to: url); reportURL = url
        }
        fraction = 1
    }
}
