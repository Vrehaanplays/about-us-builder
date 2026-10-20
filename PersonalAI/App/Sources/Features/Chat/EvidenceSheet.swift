import SwiftUI
import PersonalAICore

struct EvidenceRequest: Identifiable {
    let citation: Citation
    var id: String { citation.id + "-\(citation.conversationID ?? 0)-\(citation.memoryID ?? 0)" }
}

/// "Why did it say that?" The exact archived words behind a source tag, with a way into the original conversation.
struct EvidenceSheet: View {
    let request: EvidenceRequest
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    @State private var messages: [MessageRecord] = []
    @State private var explanation: MemoryExplanation?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let mid = request.citation.memoryID {
                        memoryBody(mid)
                    } else {
                        Text("From your history").font(PBFont.label).foregroundStyle(p.sub)
                        Text(request.citation.title).font(PBFont.section)
                        ForEach(messages) { m in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(m.role == .user ? "You" : "Assistant") · \(Date(timeIntervalSince1970: m.createdAt).formatted(date: .abbreviated, time: .shortened))").font(PBFont.label).foregroundStyle(p.sub)
                                Text(m.text).font(PBFont.body).textSelection(.enabled)
                            }
                            .card()
                            .overlay(alignment: .topTrailing) { if request.citation.anchorMessageIDs.contains(m.id) { Sticker(text: "matched", tilt: 4).padding(8) } }
                        }
                        if let cid = request.citation.conversationID {
                            NavigationLink { ConversationReaderView(conversationID: cid, highlight: Set(request.citation.anchorMessageIDs)) } label: { Text("Open the whole conversation") }
                                .buttonStyle(LipButtonStyle(kind: .primary))
                        }
                    }
                }
                .padding(PB.margin)
            }
            .scene()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.font(PBFont.bodyHeavy) } }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { load() }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func memoryBody(_ id: Int64) -> some View {
        Text("A note about you").font(PBFont.label).foregroundStyle(p.sub)
        Text(request.citation.title).font(PBFont.section)
        if let e = explanation {
            Text("How we know: \(e.memory.epistemic.rawValue). Confidence \(Int(e.memory.confidence * 100))%.").font(PBFont.body).foregroundStyle(p.sub)
            ForEach(Array(e.evidence.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(item.link.quote)”").font(PBFont.body)
                    if let m = item.message { Text("\(item.link.speaker) · \(Date(timeIntervalSince1970: m.createdAt).formatted(date: .abbreviated, time: .omitted))").font(PBFont.meta).foregroundStyle(p.sub) }
                }.card()
            }
            NavigationLink { MemoryDetailView(memoryID: id) } label: { Text("Review or correct this note") }.buttonStyle(LipButtonStyle(kind: .primary))
        }
    }

    private func load() {
        guard let s = app.services else { return }
        if let mid = request.citation.memoryID { explanation = try? s.memory.explain(mid) }
        else { messages = ((try? s.archive.messages(ids: request.citation.messageIDs)) ?? [:]).values.sorted { ($0.conversationID, $0.seq) < ($1.conversationID, $1.seq) } }
    }
}

struct ContextSheet: View {
    let prepared: PreparedTurn?
    let stats: GenerationStats?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let t = prepared {
                        Text("What the model saw").font(PBFont.section)
                        let used = Double(t.promptTokens) / Double(max(1, t.windowTokens))
                        VStack(alignment: .leading, spacing: 8) {
                            SegmentBar(fraction: min(1, used))
                            Text("\(t.promptTokens.formatted()) of \(t.windowTokens.formatted()) tokens planned for this turn").font(PBFont.meta).foregroundStyle(p.sub)
                        }.card()
                        row("Conversation messages in view", "\(t.historyMessagesIncluded) of \(t.historyMessagesTotal)")
                        row("Archive search", t.retrievalSummary)
                        row("Preparation time", String(format: "%.0f ms", t.assemblyMillis))
                        if let s = stats {
                            row("Prompt reused from cache", "\(s.reusedPrefixTokens.formatted()) tokens")
                            if let ttft = s.timeToFirstTokenMs { row("Time to first word", String(format: "%.1f s", ttft / 1000)) }
                            if let tps = s.tokensPerSecond { row("Writing speed", String(format: "%.1f tokens/s", tps)) }
                        }
                        if !t.notes.isEmpty {
                            Text("Why this size").font(PBFont.bodyHeavy)
                            ForEach(t.notes, id: \.self) { Text("• \($0)").font(PBFont.meta).foregroundStyle(p.sub) }
                        }
                        Text("These numbers are measured on this device for this turn.").font(PBFont.meta).foregroundStyle(p.sub)
                    } else {
                        Text("Send a message to see how the context was built.").font(PBFont.body)
                    }
                }.padding(PB.margin)
            }
            .scene()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.font(PBFont.bodyHeavy) } }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(k).font(PBFont.body); Spacer(); Text(v).font(PBFont.bodyHeavy).multilineTextAlignment(.trailing) }
            .padding(.vertical, 6).overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 2) }
    }
}

/// Read-only view of any archived conversation. Pages in windows so a 1000+ message chat opens instantly.
struct ConversationReaderView: View {
    let conversationID: Int64
    var highlight: Set<Int64> = []
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var msgs: [MessageRecord] = []
    @State private var lo = 0, hi = 0, total = 0
    @State private var title = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if lo > 0 { Button("Earlier messages") { loadEarlier() }.font(PBFont.meta).underline().frame(maxWidth: .infinity) }
                    ForEach(msgs) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(m.role == .user ? "You" : m.role.rawValue.capitalized) · \(Date(timeIntervalSince1970: m.createdAt).formatted(date: .abbreviated, time: .shortened)) · #\(m.seq + 1)").font(PBFont.label).foregroundStyle(p.sub)
                            Text(m.text).font(PBFont.body).textSelection(.enabled)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(highlight.contains(m.id) ? PB.lime.opacity(0.9) : p.card))
                        .foregroundStyle(highlight.contains(m.id) ? PB.ink : p.fg)
                        .id(m.id)
                    }
                    if hi < total - 1 { Button("Later messages") { loadLater() }.font(PBFont.meta).underline().frame(maxWidth: .infinity) }
                }
                .padding(PB.margin)
            }
            .onAppear { load(); if let h = highlight.first { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo(h, anchor: .center) } } }
        }
        .scene()
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }

    private func load() {
        guard let s = app.services else { return }
        total = (try? s.archive.messageCount(conversationID: conversationID)) ?? 0
        title = (try? s.archive.conversation(conversationID)?.title) ?? "Conversation"
        var center = total - 1
        if let h = highlight.first, let m = (try? s.archive.messages(ids: [h]))?[h] { center = m.seq }
        lo = max(0, center - 40); hi = min(total - 1, center + 40)
        msgs = (try? s.archive.messages(conversationID: conversationID, seqFrom: lo, seqTo: hi)) ?? []
    }
    private func loadEarlier() {
        guard let s = app.services else { return }
        let nlo = max(0, lo - 80)
        msgs = ((try? s.archive.messages(conversationID: conversationID, seqFrom: nlo, seqTo: lo - 1)) ?? []) + msgs; lo = nlo
    }
    private func loadLater() {
        guard let s = app.services else { return }
        let nhi = min(total - 1, hi + 80)
        msgs += (try? s.archive.messages(conversationID: conversationID, seqFrom: hi + 1, seqTo: nhi)) ?? []; hi = nhi
    }
}
