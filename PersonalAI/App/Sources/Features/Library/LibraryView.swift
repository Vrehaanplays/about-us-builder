import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PersonalAICore

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var pickerMode: PickerMode?
    enum PickerMode { case export, folder }
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var mediaStatus: String?
    @State private var confirmErase = false
    @State private var confirmRebuild = false
    @State private var exportURL: URL?
    @State private var mediaTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Library", subtitle: "Everything stays on this iPhone.")
                    statusCard
                    importCard
                    mediaCard
                    maintenanceCard
                }
                .padding(.horizontal, PB.margin).padding(.top, 8).padding(.bottom, 32)
            }
            .scene().toolbar(.hidden, for: .navigationBar)
            .fileImporter(isPresented: .init(get: { pickerMode != nil }, set: { if !$0 { pickerMode = nil } }),
                          allowedContentTypes: pickerMode == .folder ? [.folder] : [.json, .zip, .folder, .plainText], allowsMultipleSelection: false) { r in
                let mode = pickerMode; pickerMode = nil
                guard case .success(let urls) = r, let u = urls.first else { return }
                if mode == .folder { indexFolder(u) } else { app.importFile(u) }
            }
            .onChange(of: photoItems) { _, items in if !items.isEmpty { indexPhotos(items) } }
            .alert("Rebuild the search index?", isPresented: $confirmRebuild) {
                Button("Rebuild") { try? app.services?.rebuildDerived(); app.refreshStorage(); app.restartIndexing() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Search entries and vectors are deleted and recreated from your messages, which are not touched. This uses battery for a while.") }
            .alert("Erase everything?", isPresented: $confirmErase) {
                Button("Erase all data", role: .destructive) { try? app.services?.eraseEverything(); app.refreshConversations(); app.refreshStorage() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("All conversations, notes, search data and file/photo index entries are permanently deleted from this phone. Downloaded models stay. This can't be undone.") }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Index").font(PBFont.section)
            if let s = app.storage {
                stat("\(s.messages.formatted())", "messages · \(s.conversations.formatted()) conversations")
                stat("\(s.vectors.formatted())", "passages searchable by meaning")
                if s.chunksPending > 0 { SegmentBar(fraction: Double(s.chunks - s.chunksPending) / Double(max(1, s.chunks))); Text("\(s.chunksPending.formatted()) passages waiting to be indexed").font(PBFont.meta).foregroundStyle(p.sub) }
                stat("\(s.memories.formatted())", "notes about you")
                stat(ByteCountFormatter.string(s.dbBytes), "archive on disk · models \(ByteCountFormatter.string(app.modelBytes))")
            }
            if let st = app.indexStatus { Chip(text: statusText(st), systemImage: "gearshape.2") }
            if app.loadedEmbedderID == nil { Text("Keyword search is active. Install an embedding model in Models to search by meaning.").font(PBFont.meta).foregroundStyle(p.sub) }
            Text(workExplanation).font(PBFont.meta).foregroundStyle(p.sub)
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var workExplanation: String {
        app.settings.indexOnlyWhileCharging ? "Indexing runs while the app is open and charging, and pauses when the phone is warm, in Low Power Mode, or while you chat." : "Indexing runs while the app is open and pauses when the phone is warm, in Low Power Mode, or while you chat."
    }
    private func statusText(_ s: IndexStatus) -> String {
        s.level == .none ? "Paused" : (s.activity == "idle" ? "Up to date" : s.activity.capitalized)
    }
    private func stat(_ big: String, _ small: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) { Text(big).font(PBFont.heavy(28, relativeTo: .title)); Text(small).font(PBFont.meta).foregroundStyle(p.sub) }
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import conversations").font(PBFont.section)
            Text("Choose the export you get from ChatGPT or Claude (the .zip, the folder, or conversations.json). Your original messages are stored exactly as written; duplicates are skipped.").font(PBFont.body).foregroundStyle(p.sub)
            if let st = app.importState {
                VStack(alignment: .leading, spacing: 8) {
                    Text(st.title).font(PBFont.bodyHeavy).lineLimit(1)
                    if let e = st.error { ErrorBanner(message: e, retry: nil, dismiss: { app.importState = nil }) }
                    else {
                        SegmentBar(fraction: st.fraction, tint: st.finished ? PB.lime : PB.violet)
                        Text(st.detail).font(PBFont.meta).foregroundStyle(p.sub)
                        if !st.finished { Button("Cancel import") { app.cancelImport() }.font(PBFont.meta).underline() }
                    }
                }
            }
            Button { pickerMode = .export } label: { Text("Choose export…") }.buttonStyle(LipButtonStyle(kind: .primary))
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photos and files").font(PBFont.section)
            Text("Pick the photos or a folder you want searchable. Text in images and what they show are read on this phone with Apple's Vision. Only what you pick is indexed; nothing else in Photos or Files is touched.").font(PBFont.body).foregroundStyle(p.sub)
            PhotosPicker(selection: $photoItems, maxSelectionCount: 100, matching: .images, photoLibrary: .shared()) { Text("Choose photos…") }
                .buttonStyle(LipButtonStyle(kind: .outline))
            Button { pickerMode = .folder } label: { Text("Choose a folder…") }.buttonStyle(LipButtonStyle(kind: .outline))
            if let m = mediaStatus { Text(m).font(PBFont.meta).foregroundStyle(p.sub) }
            Text("Photos and files are found by their words, labels, names and dates. They are not yet searched by meaning.").font(PBFont.meta).foregroundStyle(p.sub)
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var maintenanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your data").font(PBFont.section)
            Button { export() } label: { Text("Export everything") }.buttonStyle(LipButtonStyle(kind: .outline))
            if let u = exportURL { ShareLink(item: u) { Label("Share export folder", systemImage: "square.and.arrow.up") }.font(PBFont.bodyHeavy) }
            Button { confirmRebuild = true } label: { Text("Rebuild search index") }.buttonStyle(LipButtonStyle(kind: .outline))
            Button { confirmErase = true } label: { Text("Erase all data") }.buttonStyle(LipButtonStyle(kind: .danger))
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func export() {
        guard let s = app.services else { return }
        Task.detached {
            let dir = FileManager.default.temporaryDirectory
            let r = try? ArchiveExporter.export(from: s, to: dir)
            await MainActor.run { exportURL = r?.url; mediaStatus = r.map { "Exported \($0.conversations) conversations, \($0.messages) messages and \($0.memories) notes." } ?? "Export failed." }
        }
    }

    private func indexPhotos(_ items: [PhotosPickerItem]) {
        guard let s = app.services else { return }
        mediaTask?.cancel()
        mediaTask = Task {
            var done = 0
            for item in items {
                if Task.isCancelled { break }
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let id = item.itemIdentifier ?? "photo-\(UUID().uuidString)"
                    try? await Task.detached(priority: .utility) { try MediaIndexer.indexPhoto(data: data, identifier: id, name: nil, services: s) }.value
                }
                done += 1; mediaStatus = "Indexed \(done) of \(items.count) photos…"
            }
            mediaStatus = "Indexed \(done) photos on this phone."; photoItems = []; app.refreshStorage()
        }
    }

    private func indexFolder(_ url: URL) {
        guard let s = app.services else { return }
        mediaTask?.cancel()
        mediaStatus = "Reading \(url.lastPathComponent)…"
        mediaTask = Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let n = try? await Task.detached(priority: .utility) {
                try MediaIndexer.indexFolder(url, services: s, isCancelled: { Task.isCancelled }, progress: { n, name in Task { @MainActor in mediaStatus = "Indexed \(n) files… \(name)" } })
            }.value
            mediaStatus = "Indexed \(n ?? 0) files from \(url.lastPathComponent)."; app.refreshStorage()
        }
    }
}
