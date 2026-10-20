import SwiftUI
import UIKit
import PersonalAICore

struct ModelsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var planned: [String: DownloadPlan] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Models", subtitle: "Downloaded once. Chats run on this iPhone.")
                    deviceCard
                    if let b = app.banner { ErrorBanner(message: b, retry: nil, dismiss: { app.banner = nil }) }
                    Text("Chat models").font(PBFont.section)
                    ForEach(ModelCatalog.chat) { ModelCard(spec: $0) }
                    Text("Search models").font(PBFont.section).padding(.top, 8)
                    Text("These turn passages into vectors so search works by meaning. Switching rebuilds the search index (your messages aren't touched).").font(PBFont.meta).foregroundStyle(p.sub)
                    ForEach(ModelCatalog.embedders) { ModelCard(spec: $0) }
                    NavigationLink { BenchmarkView() } label: { Text("Measure this iPhone…") }.buttonStyle(LipButtonStyle(kind: .outline)).padding(.top, 8)
                    Text("Sizes and licences come from each model's page. Speed on your phone is only known after you run the measurement above.").font(PBFont.meta).foregroundStyle(p.sub)
                }
                .padding(.horizontal, PB.margin).padding(.top, 8).padding(.bottom, 32)
            }
            .scene().toolbar(.hidden, for: .navigationBar)
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(DeviceInfo.machine).font(PBFont.bodyHeavy); Spacer(); Text("\(String(format: "%.0f", Double(DeviceInfo.physicalMemoryBytes) / 1e9)) GB memory").font(PBFont.meta).foregroundStyle(p.sub) }
            Text("About \(ByteCountFormatter.string(Int64(DeviceInfo.availableMemoryBytes))) available to this app right now · \(ByteCountFormatter.string(DeviceInfo.freeDiskBytes)) free storage").font(PBFont.meta).foregroundStyle(p.sub)
            if let s = app.engineStatus { Chip(text: s, systemImage: "hourglass", emphasised: true) }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

struct ModelCard: View {
    let spec: ModelSpec
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var confirmRemove = false

    private var state: ModelState { app.modelStates[spec.id] ?? .notInstalled }
    private var isActive: Bool { spec.role == .chat ? app.loadedChatModelID == spec.id : app.loadedEmbedderID == spec.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.displayName).font(PBFont.section)
                Spacer()
                if isActive { Sticker(text: "In use", tilt: 4) }
            }
            HStack(spacing: 6) {
                LocalityBadge(where_: .onDevice)
                Chip(text: spec.quantisation)
                Chip(text: sizeText)
            }
            Text(spec.blurb).font(PBFont.meta).foregroundStyle(p.sub)
            Text("\(spec.license)\(spec.licenseChecked ? "" : " (check the model page)") · up to \(spec.contextTokens.formatted()) tokens\(spec.role == .chat ? " · suggested for \(spec.suggestedMinRAMGB) GB+ phones" : "")").font(PBFont.meta).foregroundStyle(p.sub)
            if spec.role == .chat && Double(DeviceInfo.physicalMemoryBytes) / 1e9 < Double(spec.suggestedMinRAMGB) - 0.5 {
                Text("May not fit comfortably on this phone.").font(PBFont.meta).foregroundStyle(PB.coral)
            }
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
        .alert("Remove \(spec.displayName)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await app.removeModel(spec.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The downloaded files are deleted from this phone. You can download them again later.") }
    }

    private var sizeText: String {
        switch state {
        case .installed(let b): return ByteCountFormatter.string(b)
        case .downloading(_, let t, _), .paused(_, let t): return ByteCountFormatter.string(t)
        default: return "≈ " + String(format: "%.1f GB", spec.approxDownloadGB)
        }
    }

    @ViewBuilder private var controls: some View {
        switch state {
        case .notInstalled:
            Button { Task { await app.downloadModel(spec.id) } } label: { Text("Download") }.buttonStyle(LipButtonStyle(kind: .primary))
        case .planning:
            HStack { ProgressView(); Text("Checking exact size…").font(PBFont.meta) }
        case .downloading(let got, let total, let file):
            VStack(alignment: .leading, spacing: 8) {
                SegmentBar(fraction: Double(got) / Double(max(1, total)))
                Text("\(ByteCountFormatter.string(got)) of \(ByteCountFormatter.string(total)) · \(file)").font(PBFont.meta).foregroundStyle(p.sub).lineLimit(1)
                Button { Task { await app.pauseModel(spec.id) } } label: { Text("Pause") }.buttonStyle(LipButtonStyle(kind: .outline))
                Text("Keep the app open while downloading.").font(PBFont.meta).foregroundStyle(p.sub)
            }
        case .paused(let got, let total):
            VStack(alignment: .leading, spacing: 8) {
                SegmentBar(fraction: Double(got) / Double(max(1, total)), tint: PB.violet)
                Text("Paused at \(ByteCountFormatter.string(got)) of \(ByteCountFormatter.string(total))").font(PBFont.meta).foregroundStyle(p.sub)
                Button { Task { await app.downloadModel(spec.id) } } label: { Text("Resume") }.buttonStyle(LipButtonStyle(kind: .primary))
                Button { confirmRemove = true } label: { Text("Discard download") }.font(PBFont.meta).underline()
            }
        case .verifying(let f):
            HStack { ProgressView(); Text("Verifying \(f)…").font(PBFont.meta) }
        case .installed:
            VStack(alignment: .leading, spacing: 8) {
                if !isActive {
                    Button { Task { if spec.role == .chat { await app.loadChatModel(spec.id) } else { await app.loadEmbedder(spec.id) } } } label: { Text(spec.role == .chat ? "Use this model" : "Use for search") }
                        .buttonStyle(LipButtonStyle(kind: .lime)).disabled(app.engineStatus != nil)
                } else if spec.role == .chat {
                    Button { Task { await app.unloadChatModel() } } label: { Text("Unload from memory") }.buttonStyle(LipButtonStyle(kind: .outline))
                }
                Button { confirmRemove = true } label: { Text("Remove from this phone") }.font(PBFont.meta).underline()
            }
        case .failed(let m):
            VStack(alignment: .leading, spacing: 8) {
                ErrorBanner(message: m, retry: { Task { await app.downloadModel(spec.id) } }, dismiss: nil)
            }
        }
    }
}

struct BenchmarkView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var runner = BenchmarkRunner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: "Measure this iPhone", subtitle: "Real timings from this device. Nothing is estimated.")
                Text("Plug in and let the phone cool first. The full run takes about 8 minutes and warms the phone on purpose, to show whether speed holds up. Results are saved as a file you can share.").font(PBFont.body).foregroundStyle(p.sub)
                if app.loadedChatModelID == nil { Text("Load a chat model in Models to include generation speed.").font(PBFont.meta).foregroundStyle(PB.coral) }
                if runner.running {
                    SegmentBar(fraction: runner.fraction)
                    Button { runner.cancel() } label: { Text("Stop") }.buttonStyle(LipButtonStyle(kind: .danger))
                } else {
                    Button { runner.start(app: app, mode: .quick) } label: { Text("Quick run (~2 min)") }.buttonStyle(LipButtonStyle(kind: .primary))
                    Button { runner.start(app: app, mode: .full) } label: { Text("Full run (~8 min)") }.buttonStyle(LipButtonStyle(kind: .outline))
                }
                ForEach(runner.steps) { s in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(s.state)).foregroundStyle(s.state == .failed ? PB.coral : p.accent)
                        VStack(alignment: .leading) { Text(s.title).font(PBFont.bodyHeavy); if !s.detail.isEmpty { Text(s.detail).font(PBFont.meta).foregroundStyle(p.sub) } }
                    }
                }
                if let u = runner.reportURL {
                    ShareLink(item: u) { Label("Share results file", systemImage: "square.and.arrow.up") }.font(PBFont.bodyHeavy)
                    if let r = runner.report { ForEach(Array(r.notes.enumerated()), id: \.offset) { Text($1).font(PBFont.meta).foregroundStyle(PB.coral) } }
                }
            }
            .padding(PB.margin)
        }
        .scene().navigationBarTitleDisplayMode(.inline)
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: runner.running) { _, r in UIApplication.shared.isIdleTimerDisabled = r }
    }
    private func icon(_ s: BenchmarkRunner.Step.State) -> String {
        switch s { case .pending: return "circle"; case .running: return "circle.dotted"; case .done: return "checkmark.circle.fill"; case .skipped: return "minus.circle"; case .failed: return "xmark.circle.fill" }
    }
}
