import SwiftUI
import PersonalAICore

struct ChatView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var vm: ChatViewModel
    @State private var evidence: EvidenceRequest?
    @State private var showContext = false
    @FocusState private var focused: Bool

    init(conversationID: Int64?) { _vm = State(initialValue: ChatViewModel(conversationID: conversationID)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            messages
            if let e = vm.error { ErrorBanner(message: e, retry: nil, dismiss: { vm.error = nil }).padding(.horizontal, PB.margin).padding(.bottom, 8) }
            composer
        }
        .scene()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task { vm.load(app) }
        .sheet(item: $evidence) { EvidenceSheet(request: $0) }
        .sheet(isPresented: $showContext) { ContextSheet(prepared: vm.prepared, stats: vm.lastStats) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(PBFont.heavy(22, relativeTo: .title2)).lineLimit(1)
                HStack(spacing: 8) {
                    LocalityBadge(where_: .onDevice)
                    Text(app.loadedChatModelID.flatMap { ModelCatalog.spec($0)?.displayName } ?? "No model loaded").font(PBFont.meta).foregroundStyle(p.sub)
                }
            }
            Spacer()
            Button { showContext = true } label: { Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 20, weight: .bold)).frame(width: 44, height: 44) }
                .accessibilityLabel("Context details").disabled(vm.prepared == nil)
        }
        .padding(.horizontal, PB.margin).padding(.top, 8).padding(.bottom, 10)
    }

    private var title: String {
        if let id = vm.conversationID, let c = app.conversations.first(where: { $0.id == id }) { return c.title }
        return "New chat"
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if vm.hasEarlier { Button("Load earlier messages") { vm.loadEarlier(app) }.font(PBFont.meta).underline().frame(maxWidth: .infinity) }
                    if vm.lines.isEmpty { emptyState }
                    ForEach(vm.lines) { line in
                        MessageRow(line: line, showDetails: app.settings.showRetrievalDetails, onCite: { c in evidence = EvidenceRequest(citation: c) })
                            .id(line.id)
                            .transition(.scale(scale: 0.96, anchor: line.role == .user ? .bottomTrailing : .bottomLeading).combined(with: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, PB.margin).padding(.vertical, 8)
                .motion(PB.bouncy, value: vm.lines.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.lines.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: vm.lines.count) { _, _ in withAnimation(PB.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if app.loadedChatModelID == nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pick a model to start.").font(PBFont.section)
                Text("Chats run on this iPhone. Download a model once; after that nothing leaves the device.").font(PBFont.body).foregroundStyle(p.sub)
                if let s = app.engineStatus { Chip(text: s, systemImage: "hourglass", emphasised: true) }
            }.card()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ask anything.").font(PBFont.mega).tracking(-3).minimumScaleFactor(0.5)
                Text(app.settings.useArchiveInChat ? "Your imported history and memories are searched on this phone when they help." : "Archive search is off for this chat.").font(PBFont.body).foregroundStyle(p.sub)
            }.padding(.top, 40)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $vm.input, axis: .vertical)
                .font(PBFont.body).lineLimit(1...6).focused($focused)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(p.card))
                .submitLabel(.send)
            if vm.isGenerating {
                Button { vm.stop(app) } label: { Image(systemName: "stop.fill").frame(width: 30, height: 30) }
                    .buttonStyle(LipButtonStyle(kind: .danger, fullWidth: false)).accessibilityLabel("Stop")
            } else {
                Button { vm.send(app); focused = false } label: { Image(systemName: "arrow.up").font(.system(size: 18, weight: .heavy)).frame(width: 30, height: 30) }
                    .buttonStyle(LipButtonStyle(kind: .primary, fullWidth: false))
                    .disabled(vm.input.trimmingCharacters(in: .whitespaces).isEmpty || app.loadedChatModelID == nil)
                    .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, PB.margin).padding(.top, 6).padding(.bottom, 8)
    }
}

struct MessageRow: View {
    let line: ChatViewModel.Line
    let showDetails: Bool
    let onCite: (Citation) -> Void
    @Environment(\.palette) private var p

    var body: some View {
        if line.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(line.text).font(PBFont.body).textSelection(.enabled)
                    .foregroundStyle(p.ctaFg)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(p.ctaBg))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if line.streaming && line.text.isEmpty { ThinkingDots() }
                else { Text(Self.render(line.text)).font(PBFont.body).textSelection(.enabled).lineSpacing(3) }
                if line.interrupted { Chip(text: "Stopped early", systemImage: "hand.raised.fill") }
                if showDetails && !line.citations.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(line.citations) { c in
                            Button { onCite(c) } label: {
                                HStack(spacing: 6) {
                                    Text(c.id).font(PBFont.label)
                                    Text(c.title).font(PBFont.meta).lineLimit(1)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(PB.lime)).foregroundStyle(PB.ink)
                            }
                            .accessibilityLabel("Source \(c.id): \(c.title)")
                        }
                    }
                }
                if !line.streaming, let m = line.model, line.locality != .imported {
                    Text("\(line.locality == .cloud ? "Cloud" : "On this iPhone") · \(ModelCatalog.spec(m)?.displayName ?? m)").font(PBFont.meta).foregroundStyle(p.sub)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func render(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct ThinkingDots: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle().frame(width: 10, height: 10)
                    .scaleEffect(on && !reduce ? 1.0 : 0.6)
                    .animation(reduce ? nil : .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: on)
            }
        }
        .onAppear { on = true }
        .accessibilityLabel("Thinking")
    }
}

/// Wrapping row for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: w, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz)); x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
