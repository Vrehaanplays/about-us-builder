import Foundation

public enum ChatEvent: Sendable {
    case conversation(Int64)
    case userMessage(MessageRecord)
    /// Emitted once the prompt is assembled, before the first token: lets the UI show what was retrieved and how big the context is.
    case prepared(PreparedTurn)
    case token(String)
    case finished(MessageRecord, GenerationStats)
    /// Generation ended early (cancelled or failed). `saved` is the partial assistant message, kept in the archive and flagged interrupted.
    case interrupted(saved: MessageRecord?, reason: String)
}

public struct PreparedTurn: Sendable {
    public var citations: [Citation]
    public var promptTokens: Int
    public var windowTokens: Int
    public var historyMessagesIncluded: Int
    public var historyMessagesTotal: Int
    public var retrievalSummary: String
    public var notes: [String]
    public var assemblyMillis: Double
}

/// One chat turn, end to end: assemble context → persist the user's message → stream the model → persist the reply.
/// All user-visible text goes through the immutable archive first, so nothing the user typed is lost if generation fails or the app is killed.
public final class ChatController: @unchecked Sendable {
    public let archive: ArchiveStore
    public let assembler: PromptAssembler
    public var engine: any InferenceEngine
    public var profile: @Sendable () -> ModelProfile
    public var device: @Sendable () -> DeviceBudget
    /// Remote engines may only be used when this returns true. Off by default; flipping it is a user action in Settings.
    public var remoteAllowed: @Sendable () -> Bool = { false }
    public var onTurnCompleted: (@Sendable (_ conversationID: Int64) -> Void)?
    private var chatSourceID: Int64?
    private let lock = NSLock()
    private var lastPrompt: AssembledPrompt?

    public init(archive: ArchiveStore, assembler: PromptAssembler, engine: any InferenceEngine,
                profile: @escaping @Sendable () -> ModelProfile, device: @escaping @Sendable () -> DeviceBudget) {
        self.archive = archive; self.assembler = assembler; self.engine = engine; self.profile = profile; self.device = device
    }

    public func newConversation(title: String = "New chat", now: Date = Date()) throws -> Int64 {
        let src: Int64
        if let s = chatSourceID { src = s } else { src = try archive.upsertSource(kind: "app", name: "This device", externalID: "app"); chatSourceID = src }
        let t = now.timeIntervalSince1970
        return try archive.upsertConversation(sourceID: src, externalID: "app-\(UUID().uuidString)", title: title, createdAt: t, updatedAt: t, origin: "local").id
    }

    public func cancel() async { await engine.cancel() }

    public func send(conversationID: Int64?, text: String, now: Date = Date()) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task { [self] in
                do { try await run(conversationID: conversationID, text: text, now: now, emit: { cont.yield($0) }); cont.finish() }
                catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func run(conversationID: Int64?, text: String, now: Date, emit: (ChatEvent) -> Void) async throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        // privacy gate first: nothing is assembled, stored-for-sending or sent unless the engine's locality is allowed
        let info = await engine.info
        guard let info else { throw EngineError.notLoaded }
        if info.locality == .cloud, !remoteAllowed() { throw EngineError.remoteNotAllowed }

        let cid = try conversationID ?? newConversation(title: Self.title(from: clean), now: now)
        if conversationID == nil { emit(.conversation(cid)) }

        let t0 = Date()
        let prompt = try await assembler.assemble(conversationID: cid, userText: clean, model: profile(), device: device(), now: now)
        let assemblyMs = Date().timeIntervalSince(t0) * 1000
        let previous: AssembledPrompt? = lock.withLock { let p = lastPrompt; lastPrompt = prompt; return p }

        // the user's words are archived before the model sees them
        let u = NewMessage(role: .user, text: clean, createdAt: now.timeIntervalSince1970, locality: .local)
        _ = try archive.appendMessages(conversationID: cid, [u])
        if let rec = try archive.tail(conversationID: cid, limit: 1).last { emit(.userMessage(rec)) }

        var retrieval = "no retrieval"
        if let r = prompt.retrieval {
            retrieval = r.diagnostics.skipped.map { "skipped (\($0))" } ?? "\(r.confidence.rawValue): \(r.spans.count) passages, \(r.memories.count) notes"
        }
        emit(.prepared(PreparedTurn(citations: prompt.citations, promptTokens: prompt.totalTokens, windowTokens: prompt.plan.windowTokens,
                                    historyMessagesIncluded: prompt.historyMessagesIncluded, historyMessagesTotal: prompt.historyMessagesTotal,
                                    retrievalSummary: retrieval, notes: prompt.diagnostics, assemblyMillis: assemblyMs)))

        var params = GenerationParams()
        params.maxKVSize = prompt.plan.windowTokens
        params.maxTokens = prompt.plan.replyReserve
        var reply = ""
        var stats = GenerationStats()
        stats.reusedPrefixTokens = previous.map { prompt.commonPrefixCount(with: $0) } ?? 0
        do {
            for try await ev in engine.generate(messages: prompt.messages, params: params) {
                switch ev {
                case .token(let s): reply += s; emit(.token(s))
                case .finished(let st): stats = st
                }
            }
        } catch {
            let saved = try persistReply(reply, cid: cid, info: info, interrupted: true)
            if error is CancellationError || (error as? EngineError).map({ if case .cancelled = $0 { return true } else { return false } }) == true {
                emit(.interrupted(saved: saved, reason: "Stopped")); return
            }
            emit(.interrupted(saved: saved, reason: error.localizedDescription)); return
        }
        guard let saved = try persistReply(reply, cid: cid, info: info, interrupted: false) else {
            emit(.interrupted(saved: nil, reason: "The model returned an empty reply.")); return
        }
        emit(.finished(saved, stats))
        onTurnCompleted?(cid)
    }

    @discardableResult
    func persistReply(_ text: String, cid: Int64, info: EngineInfo, interrupted: Bool) throws -> MessageRecord? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let meta = interrupted ? #"{"interrupted":true}"# : nil
        _ = try archive.appendMessages(conversationID: cid, [NewMessage(role: .assistant, text: clean, createdAt: Date().timeIntervalSince1970,
                                                                         model: info.modelID, locality: info.locality, meta: meta)])
        return try archive.tail(conversationID: cid, limit: 1).last
    }

    static func title(from text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return one.count <= 48 ? one : String(one.prefix(45)) + "…"
    }
}
