import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var tab = 0
    @Namespace private var ns

    var body: some View {
        Group {
            switch app.boot {
            case .starting:
                ZStack { PB.ink.ignoresSafeArea(); VStack(spacing: 12) { Text("Personal AI").font(PBFont.heavy(40)).foregroundStyle(PB.lime); ProgressView().tint(PB.lime) } }
            case .failed(let m):
                EmptyState(title: "Couldn't open your data", message: m, systemImage: "exclamationmark.triangle").scene()
            case .ready:
                if !app.settings.onboarded { OnboardingView() } else { tabs }
            }
        }
        .task { await app.bootstrap() }
    }

    private var tabs: some View {
        VStack(spacing: 0) {
            ZStack {
                switch tab {
                case 0: ChatListView()
                case 1: MemoryView()
                case 2: LibraryView()
                case 3: ModelsView()
                default: SettingsView()
                }
            }
            TabBar(selection: $tab, ns: ns)
        }
        .scene()
    }
}

/// Bottom bar whose highlight stretches like jelly between tabs (Playbook motion).
struct TabBar: View {
    @Binding var selection: Int
    let ns: Namespace.ID
    @Environment(\.palette) private var p
    private let items: [(String, String)] = [("Chats", "bubble.left.and.bubble.right.fill"), ("Memory", "brain"), ("Library", "tray.full.fill"), ("Models", "cpu"), ("Privacy", "lock.shield.fill")]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                Button { selection = i } label: {
                    VStack(spacing: 3) {
                        Image(systemName: items[i].1).font(.system(size: 19, weight: .bold))
                        Text(items[i].0).font(PBFont.label)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(selection == i ? p.ctaFg : p.fg.opacity(0.7))
                    .background { if selection == i { Capsule().fill(p.ctaBg).matchedGeometryEffect(id: "tab", in: ns) } }
                }
                .accessibilityLabel(items[i].0).accessibilityAddTraits(selection == i ? .isSelected : [])
            }
        }
        .padding(6).background(Capsule().fill(p.card)).padding(.horizontal, 12).padding(.bottom, 4)
        .motion(PB.wobbly, value: selection)
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var step = 0
    @State private var chosen = ModelCatalog.defaultChatID

    var body: some View {
        ZStack {
            PB.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                SegmentBar(fraction: Double(step + 1) / 3, segments: 3)
                Spacer()
                if step == 0 {
                    Text("An AI that lives on your phone.").font(PBFont.heavy(46, relativeTo: .largeTitle)).tracking(-2).foregroundStyle(PB.cream)
                    Text("It remembers your past chats, and never sends them anywhere.").font(PBFont.lead).foregroundStyle(PB.cream.opacity(0.75))
                } else if step == 1 {
                    Text("Everything stays here.").font(PBFont.heavy(46, relativeTo: .largeTitle)).tracking(-2).foregroundStyle(PB.cream)
                    VStack(alignment: .leading, spacing: 10) {
                        point("Chats, search and memory run on this iPhone.")
                        point("No account. No cloud fallback.")
                        point("The only download is the model file you choose.")
                        point("See, correct, export or erase anything, any time.")
                    }
                } else {
                    Text("Pick a model.").font(PBFont.heavy(46, relativeTo: .largeTitle)).tracking(-2).foregroundStyle(PB.cream)
                    ForEach(ModelCatalog.suggestions(ramGB: max(4, Int((Double(DeviceInfo.physicalMemoryBytes) / 1e9).rounded()))).prefix(3)) { m in
                        Button { chosen = m.id } label: {
                            HStack { VStack(alignment: .leading) { Text(m.displayName).font(PBFont.bodyHeavy); Text("≈ \(String(format: "%.1f", m.approxDownloadGB)) GB · \(m.blurb)").font(PBFont.meta).lineLimit(2) }; Spacer() }
                                .padding(16).foregroundStyle(chosen == m.id ? PB.lime : PB.ink)
                                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(chosen == m.id ? PB.ink : PB.cream))
                                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(PB.lime, lineWidth: chosen == m.id ? 3 : 0))
                        }
                    }
                    Text("You can change this later. The search model (about 90 MB) is downloaded too.").font(PBFont.meta).foregroundStyle(PB.cream.opacity(0.7))
                }
                Spacer()
                Button {
                    if step < 2 { withAnimation(PB.snappy) { step += 1 } }
                    else {
                        app.settings.chatModelID = chosen; app.settings.embedderID = ModelCatalog.defaultEmbedderID
                        Task { await app.downloadModel(ModelCatalog.defaultEmbedderID); await app.downloadModel(chosen) }
                        app.settings.onboarded = true
                    }
                } label: { Text(step < 2 ? "Continue" : "Download and start") }.buttonStyle(LipButtonStyle(kind: .lime))
                if step == 2 { Button("Not now") { app.settings.onboarded = true }.font(PBFont.meta).foregroundStyle(PB.cream.opacity(0.7)) }
            }
            .padding(PB.margin)
        }
        .preferredColorScheme(.dark)
        .environment(\.palette, Palette.resolve(.dark))
    }
    private func point(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 10) { Image(systemName: "checkmark.circle.fill").foregroundStyle(PB.lime); Text(s).font(PBFont.body).foregroundStyle(PB.cream) }
    }
}
