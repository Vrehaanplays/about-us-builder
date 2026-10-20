import Foundation
import Observation
import SwiftUI
import PersonalAICore

struct ImportUIState: Equatable {
    var title: String
    var fraction: Double
    var detail: String
    var finished = false
    var error: String?
}

/// Owns the whole object graph and the long-lived background work. Views read it; they never reach into storage directly.
@MainActor @Observable
final class AppModel {
    enum Boot: Equatable { case starting, ready, failed(String) }

    var boot: Boot = .starting
    let settings = AppSettings()
    let engine = MLXEngine()
    let gate = WorkGate()
    let profileBox = ProfileBox()
    private let transport = URLSessionTransport()

    private(set) var services: PersonalAIServices?
    private(set) var modelStore: ModelStore?
    private(set) var chat: ChatController?

    var modelStates: [String: ModelState] = [:]
    var loadedChatModelID: String?
    var loadedEmbedderID: String?
    var engineStatus: String?
    var indexStatus: IndexStatus?
    var storage: StorageStats?
    var modelBytes: Int64 = 0
    var conversations: [ConversationRecord] = []
    var importState: ImportUIState?
    var banner: String?
    var isGenerating = false { didSet { gate.update(generating: isGenerating); if isGenerating { Task { await engine.cancelBackground() } } } }

    private var scheduler: IndexScheduler?
    private var statusTask: Task<Void, Never>?
    private var observerID: UUID?
    private var importTask: Task<Void, Never>?

    // MARK: boot

    func bootstrap() async {
        guard services == nil else { return }
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PersonalAI", isDirectory: true)
            let dataDir = base.appendingPathComponent("Data", isDirectory: true)
            var modelsDir = base.appendingPathComponent("Models", isDirectory: true)
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            var rv = URLResourceValues(); rv.isExcludedFromBackup = true       // multi-GB, re-downloadable
            try? modelsDir.setResourceValues(rv)

            let svc = try PersonalAIServices(directory: dataDir)
            services = svc
            let store = ModelStore(root: modelsDir, transport: transport, freeSpace: { DeviceInfo.freeDiskBytes })
            modelStore = store
            observerID = await store.observe { [weak self] id, state in Task { @MainActor in self?.modelStates[id] = state } }
            for spec in ModelCatalog.all { modelStates[spec.id] = await store.state(of: spec.id) }

            let profileBox = self.profileBox
            let c = svc.makeChatController(engine: engine, profile: { profileBox.get() }, device: { DeviceInfo.budget() })
            c.remoteAllowed = { false }     // no remote engine exists in this build; the gate stays shut regardless of settings
            chat = c
            gate.update(charging: DeviceInfo.isCharging, onlyCharging: settings.indexOnlyWhileCharging)
            boot = .ready
            refreshConversations(); refreshStorage()
            startIndexing()
            Task { await autoLoadModels() }
        } catch {
            boot = .failed(error.localizedDescription)
        }
    }

    private func autoLoadModels() async {
        guard settings.autoLoadModelOnLaunch else { return }
        if !settings.embedderID.isEmpty, case .installed = modelStates[settings.embedderID] ?? .notInstalled { await loadEmbedder(settings.embedderID) }
        if !settings.chatModelID.isEmpty, case .installed = modelStates[settings.chatModelID] ?? .notInstalled { await loadChatModel(settings.chatModelID) }
    }

    // MARK: models

    func downloadModel(_ id: String) async {
        guard settings.allowModelDownloads else { banner = "Downloads are switched off in Settings → Privacy."; return }
        await modelStore?.start(id)
    }
    func pauseModel(_ id: String) async { await modelStore?.pause(id) }
    func removeModel(_ id: String) async {
        if loadedChatModelID == id { await unloadChatModel() }
        if loadedEmbedderID == id { loadedEmbedderID = nil; try? services?.setEmbedder(HashingEmbedder(dim: 256)); restartIndexing() }
        await modelStore?.remove(id)
        refreshStorage()
    }

    func loadChatModel(_ id: String) async {
        guard let store = modelStore, let spec = ModelCatalog.spec(id) else { return }
        engineStatus = "Loading \(spec.displayName)…"
        do {
            let dir = await store.directory(for: id)
            try await engine.load(directory: dir, modelID: id, maxContext: spec.contextTokens) { [weak self] s in Task { @MainActor in self?.engineStatus = s } }
            if let l = await engine.loadedModel {
                profileBox.set(ModelProfile(id: id, maxContext: l.maxContext, weightsBytes: l.weightsBytes, kvBytesPerToken: l.kvBytesPerToken, supportsPrefixCache: true))
            }
            loadedChatModelID = id; settings.chatModelID = id; engineStatus = nil
        } catch {
            engineStatus = nil; loadedChatModelID = nil
            banner = "Couldn't load \(spec.displayName): \(error.localizedDescription)"
        }
    }
    func unloadChatModel() async { await engine.unload(); loadedChatModelID = nil }

    func loadEmbedder(_ id: String) async {
        guard let store = modelStore, let spec = ModelCatalog.spec(id), let svc = services else { return }
        engineStatus = "Loading \(spec.displayName)…"
        do {
            let dir = await store.directory(for: id)
            let e = try await MLXTextEmbedder(directory: dir, spec: spec)
            try svc.setEmbedder(e)
            loadedEmbedderID = id; settings.embedderID = id; engineStatus = nil
            restartIndexing()
            refreshStorage()
        } catch {
            engineStatus = nil
            banner = "Couldn't load \(spec.displayName): \(error.localizedDescription)"
        }
    }

    // MARK: chat state

    func refreshConversations() {
        guard let s = services else { return }
        conversations = (try? s.archive.conversations(limit: 300)) ?? []
    }

    func refreshStorage() {
        guard let s = services else { return }
        storage = try? s.archive.stats()
        Task { if let store = modelStore { modelBytes = await store.totalInstalledBytes() } }
    }

    /// Applies the user's context ceiling and archive switch to the planner before a turn.
    func prepareForTurn() {
        guard let s = services else { return }
        s.assembler.retrievalEnabled = settings.useArchiveInChat
        var p = ContextPlanner()
        if settings.contextCap > 0 { for k in p.capByComplexity.keys { p.capByComplexity[k] = min(p.capByComplexity[k]!, settings.contextCap) } }
        s.assembler.planner = p
    }

    func turnFinished() {
        refreshConversations(); refreshStorage()
    }

    // MARK: indexing

    func startIndexing() {
        guard let s = services else { return }
        let gate = self.gate
        let sched = IndexScheduler(pipeline: s.pipeline, level: { gate.level() })
        scheduler = sched
        let rulesEx = MemoryExtractor(archive: s.archive, memory: s.memory, entities: s.entities, generator: nil)
        let engine = self.engine
        let llmEx = MemoryExtractor(archive: s.archive, memory: s.memory, entities: s.entities, generator: EngineTextGenerator(engine: engine, modelName: "on-device"))
        llmEx.watermarkKey = "extract.llm"; llmEx.runRules = false
        let learn = { @MainActor [weak self] in self?.settings.learnMemoriesAutomatically ?? false }
        Task {
            await sched.setExtractor { [rulesEx, llmEx] in
                guard await learn() else { return false }
                // 1. free rule pass over anything new
                if let cid = rulesEx.pendingConversation() {
                    let r = try? await rulesEx.extract(conversationID: cid, maxWindows: 4, shouldContinue: { gate.level() >= .full })
                    return (r?.windowsProcessed ?? 0) > 0
                }
                // 2. model-assisted pass: only while charging, idle, cool, with a model already in memory
                guard gate.level() == .full, gate.isCharging, await engine.isLoaded, let cid = llmEx.pendingConversation() else { return false }
                let r = try? await llmEx.extract(conversationID: cid, maxWindows: 1, shouldContinue: { gate.level() == .full })
                return (r?.windowsProcessed ?? 0) > 0
            }
            await sched.start()
        }
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await st in sched.statusUpdates { self?.indexStatus = st; if st.activity == "idle" { self?.refreshStorage() } }
        }
    }

    func restartIndexing() {
        let old = scheduler
        scheduler = nil
        Task { await old?.stop(); startIndexing() }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        gate.update(foreground: phase == .active, charging: DeviceInfo.isCharging, onlyCharging: settings.indexOnlyWhileCharging)
        if phase == .background { Task { await engine.trimMemory(unloadWeights: false) } }
    }

    func memoryWarning() { Task { await engine.trimMemory(unloadWeights: false); banner = "Memory was low, so the model's working memory was released." } }

    // MARK: import

    func importFile(_ url: URL) {
        guard let s = services else { return }
        importTask?.cancel()
        importState = ImportUIState(title: url.lastPathComponent, fraction: 0, detail: "Reading…")
        importTask = Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let work = try await Task.detached(priority: .utility) { () -> (ImportReport, URL?) in
                    let (item, tmp) = try ArchiveUnpacker.prepare(url)
                    defer { if let t = tmp { try? FileManager.default.removeItem(at: t) } }
                    let r = try s.importer.importItem(at: item, progress: { p in
                        Task { @MainActor in self?.importState = ImportUIState(title: url.lastPathComponent, fraction: p.fraction, detail: "\(p.conversations) conversations · \(p.messages) messages") }
                    }, isCancelled: { Task.isCancelled })
                    return (r, tmp)
                }.value
                let r = work.0
                self?.importState = ImportUIState(title: url.lastPathComponent, fraction: 1,
                    detail: "\(r.messagesInserted) messages added, \(r.messagesDuplicate) already present, \(r.conversationsNew) new conversations", finished: true)
                self?.refreshConversations(); self?.refreshStorage()
            } catch {
                self?.importState = ImportUIState(title: url.lastPathComponent, fraction: 0, detail: "", finished: true, error: error.localizedDescription)
            }
        }
    }
    func cancelImport() { importTask?.cancel() }
}
