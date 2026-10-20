import Foundation
import Observation
import PersonalAICore

@MainActor @Observable
final class ChatViewModel {
    struct Line: Identifiable, Equatable {
        var id: String
        var messageID: Int64?
        var role: Role
        var text: String
        var locality: Locality = .local
        var model: String?
        var citations: [Citation] = []
        var interrupted = false
        var streaming = false
        var date: Date?
        static func == (a: Line, b: Line) -> Bool { a.id == b.id && a.text == b.text && a.streaming == b.streaming && a.citations.count == b.citations.count && a.interrupted == b.interrupted }
    }

    var lines: [Line] = []
    var conversationID: Int64?
    var input = ""
    var isGenerating = false
    var error: String?
    var prepared: PreparedTurn?
    var lastStats: GenerationStats?
    var hasEarlier = false
    private var oldestSeq = 0
    private var task: Task<Void, Never>?
    private let pageSize = 60

    init(conversationID: Int64?) { self.conversationID = conversationID }

    func load(_ app: AppModel) {
        guard let cid = conversationID, let s = app.services else { return }
        let msgs = (try? s.archive.tail(conversationID: cid, limit: pageSize)) ?? []
        lines = msgs.compactMap(Self.line)
        oldestSeq = msgs.first?.seq ?? 0
        hasEarlier = oldestSeq > 0
    }

    func loadEarlier(_ app: AppModel) {
        guard let cid = conversationID, let s = app.services, oldestSeq > 0 else { return }
        let from = max(0, oldestSeq - pageSize)
        let older = ((try? s.archive.messages(conversationID: cid, seqFrom: from, seqTo: oldestSeq - 1)) ?? []).compactMap(Self.line)
        lines.insert(contentsOf: older, at: 0)
        oldestSeq = from; hasEarlier = from > 0
    }

    static func line(_ m: MessageRecord) -> Line? {
        guard m.role == .user || m.role == .assistant else { return nil }
        return Line(id: "m\(m.id)", messageID: m.id, role: m.role, text: m.text, locality: m.locality, model: m.model,
                    interrupted: m.meta?.contains("interrupted") ?? false, date: Date(timeIntervalSince1970: m.createdAt))
    }

    func send(_ app: AppModel) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating, let chat = app.chat else { return }
        input = ""; error = nil
        isGenerating = true; app.isGenerating = true
        app.prepareForTurn()
        let streamingID = "stream-\(UUID().uuidString)"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isGenerating = false; app.isGenerating = false; app.turnFinished() }
            var citationsForTurn: [Citation] = []
            do {
                for try await ev in chat.send(conversationID: conversationID, text: text) {
                    switch ev {
                    case .conversation(let id): conversationID = id
                    case .userMessage(let m): if let l = Self.line(m) { lines.append(l) }
                    case .prepared(let p):
                        prepared = p; citationsForTurn = p.citations
                        lines.append(Line(id: streamingID, role: .assistant, text: "", streaming: true, date: Date()))
                    case .token(let t):
                        if let i = lines.lastIndex(where: { $0.id == streamingID }) { lines[i].text += t }
                    case .finished(let m, let stats):
                        lastStats = stats
                        if let i = lines.lastIndex(where: { $0.id == streamingID }), var l = Self.line(m) {
                            l.citations = Self.usedCitations(in: m.text, from: citationsForTurn); lines[i] = l
                        }
                    case .interrupted(let saved, let reason):
                        if let i = lines.lastIndex(where: { $0.id == streamingID }) {
                            if let m = saved, var l = Self.line(m) { l.interrupted = true; lines[i] = l } else { lines.remove(at: i) }
                        }
                        if reason != "Stopped" { error = reason }
                    }
                }
            } catch {
                if let i = lines.lastIndex(where: { $0.id == streamingID }) { lines.remove(at: i) }
                self.error = error.localizedDescription
            }
        }
    }

    func stop(_ app: AppModel) { Task { await app.chat?.cancel() } }

    /// Only tags the model actually wrote are shown as sources; unused retrieved passages stay in the "context" sheet.
    static func usedCitations(in answer: String, from all: [Citation]) -> [Citation] {
        all.filter { answer.contains("[\($0.id)]") || answer.contains("[\($0.id),") || answer.contains(", \($0.id)]") }
    }
}
