import SwiftUI
import PersonalAICore

struct MemoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var tab = 0
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    ScreenHeader(title: "Memory", subtitle: "What your assistant has learned, with the proof.")
                    Picker("", selection: $tab) { Text("Notes").tag(0); Text("Search").tag(1) }.pickerStyle(.segmented)
                }.padding(.horizontal, PB.margin).padding(.top, 8).padding(.bottom, 10)
                if tab == 0 { NotesList() } else { ArchiveSearchView() }
            }
            .scene().toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct NotesList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var notes: [MemoryRecord] = []
    @State private var filter: MemoryKind?
    @State private var showHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button { filter = nil } label: { Chip(text: "All", emphasised: filter == nil) }
                        ForEach(MemoryKind.allCases, id: \.self) { k in
                            Button { filter = k } label: { Chip(text: k.rawValue.replacingOccurrences(of: "_", with: " "), emphasised: filter == k) }
                        }
                    }
                }
                Toggle("Include replaced and disputed notes", isOn: $showHistory).font(PBFont.meta)
                if notes.isEmpty {
                    EmptyState(title: "No notes yet", message: "As you chat or import history, explicit facts, preferences and decisions you state are saved here, each linked to your exact words.", systemImage: "brain")
                }
                ForEach(notes) { n in
                    NavigationLink { MemoryDetailView(memoryID: n.id) } label: { NoteRow(note: n) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, PB.margin).padding(.bottom, 24)
        }
        .task(id: "\(filter?.rawValue ?? "")\(showHistory)") { load() }
        .onAppear { load() }
    }
    private func load() {
        guard let s = app.services else { return }
        notes = (try? s.memory.list(statuses: showHistory ? [.active, .disputed, .superseded] : [.active, .disputed], kinds: filter.map { [$0] }, limit: 300)) ?? []
    }
}

struct NoteRow: View {
    let note: MemoryRecord
    @Environment(\.palette) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.text).font(PBFont.bodyHeavy).multilineTextAlignment(.leading)
            HStack(spacing: 8) {
                Chip(text: note.kind.rawValue.replacingOccurrences(of: "_", with: " "))
                Chip(text: howWeKnow, systemImage: note.epistemic == .stated ? "quote.opening" : "questionmark")
                if note.status != .active { Chip(text: note.status.rawValue, emphasised: false) }
                if note.userState == .confirmed { Chip(text: "confirmed by you", systemImage: "checkmark", emphasised: true) }
            }
            if let from = note.validFrom { Text("since \(Date(timeIntervalSince1970: from).formatted(date: .abbreviated, time: .omitted))").font(PBFont.meta).foregroundStyle(p.sub) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
        .opacity(note.status == .superseded ? 0.6 : 1)
    }
    private var howWeKnow: String {
        switch note.epistemic { case .stated: return "you said it"; case .observed: return "seen in text"; case .inferred: return "a guess" }
    }
}

struct MemoryDetailView: View {
    let memoryID: Int64
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var ex: MemoryExplanation?
    @State private var editing = false
    @State private var newText = ""
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let e = ex {
                    Text(e.memory.text).font(PBFont.title).tracking(-1)
                    VStack(alignment: .leading, spacing: 6) {
                        line("How we know", e.memory.epistemic == .stated ? "You said it" : (e.memory.epistemic == .observed ? "Seen in your text" : "A guess from patterns"))
                        line("Confidence", "\(Int(e.memory.confidence * 100))%")
                        line("Status", e.memory.status.rawValue)
                        if let f = e.memory.validFrom { line("Valid from", Date(timeIntervalSince1970: f).formatted(date: .abbreviated, time: .omitted)) }
                        if let t = e.memory.validTo { line("Valid until", Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .omitted)) }
                        line("Written by", e.memory.createdBy == "rule" ? "Built-in rule" : e.memory.createdBy)
                    }.card()

                    Text("Evidence").font(PBFont.section)
                    if e.evidence.isEmpty { Text("No supporting message is stored for this note.").font(PBFont.body).foregroundStyle(p.sub) }
                    ForEach(Array(e.evidence.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("“\(item.link.quote)”").font(PBFont.body)
                            if let m = item.message {
                                Text("\(item.link.speaker == "user" ? "You" : "Assistant") · \(Date(timeIntervalSince1970: m.createdAt).formatted(date: .abbreviated, time: .omitted))").font(PBFont.meta).foregroundStyle(p.sub)
                                NavigationLink { ConversationReaderView(conversationID: m.conversationID, highlight: [m.id]) } label: { Text("Open original message →").font(PBFont.meta).underline() }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).card()
                    }

                    if !e.supersededChain.isEmpty {
                        Text("Earlier versions").font(PBFont.section)
                        ForEach(e.supersededChain) { old in NoteRow(note: old) }
                    }
                    if !e.events.isEmpty {
                        Text("History").font(PBFont.section)
                        ForEach(Array(e.events.enumerated()), id: \.offset) { _, ev in
                            Text("\(Date(timeIntervalSince1970: ev.at).formatted(date: .abbreviated, time: .shortened)) · \(ev.action) by \(ev.actor)").font(PBFont.meta).foregroundStyle(p.sub)
                        }
                    }

                    VStack(spacing: 6) {
                        Button { try? app.services?.memory.confirm(memoryID); load() } label: { Text("This is right") }.buttonStyle(LipButtonStyle(kind: .lime))
                        Button { newText = e.memory.text; editing = true } label: { Text("Correct it") }.buttonStyle(LipButtonStyle(kind: .outline))
                        Button { try? app.services?.memory.reject(memoryID); load() } label: { Text("This is wrong") }.buttonStyle(LipButtonStyle(kind: .outline))
                        Button { confirmDelete = true } label: { Text("Delete this note") }.buttonStyle(LipButtonStyle(kind: .danger))
                    }.padding(.top, 8)
                    Text("Corrections you make override everything the assistant infers. Your original messages are never changed.").font(PBFont.meta).foregroundStyle(p.sub)
                } else {
                    ProgressView()
                }
            }
            .padding(PB.margin)
        }
        .scene()
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form { TextField("What is true?", text: $newText, axis: .vertical).lineLimit(2...6) }
                    .navigationTitle("Correct note").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Save") { _ = try? app.services?.memory.correct(memoryID, newText: newText); editing = false; load() } }
                    }
            }.presentationDetents([.medium])
        }
        .alert("Delete this note?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { try? app.services?.memory.delete(memoryID); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The note is removed. Your conversations are untouched, and the assistant will not re-learn it from the same words.") }
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(PBFont.meta).foregroundStyle(p.sub); Spacer(); Text(v).font(PBFont.bodyHeavy) }
    }
    private func load() { ex = try? app.services?.memory.explain(memoryID) }
}

/// Searches everything on the phone: the same retrieval the assistant uses, with the reason for each hit visible.
struct ArchiveSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var query = ""
    @State private var result: RetrievalResult?
    @State private var busy = false
    @State private var elapsed: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Search your history and notes", text: $query).font(PBFont.body).submitLabel(.search).onSubmit { run() }
                    if busy { ProgressView() } else { Button { run() } label: { Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .bold)) }.accessibilityLabel("Search") }
                }
                .padding(.horizontal, 16).padding(.vertical, 14).background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(p.card))
                Text(searchModeNote).font(PBFont.meta).foregroundStyle(p.sub)
                if let r = result {
                    if let e = elapsed { Text("\(r.spans.count) passages · \(r.memories.count) notes · \(String(format: "%.0f", e)) ms · all on this iPhone").font(PBFont.meta).foregroundStyle(p.sub) }
                    if r.spans.isEmpty && r.memories.isEmpty && r.assets.isEmpty {
                        EmptyState(title: "Nothing found", message: r.diagnostics.skipped ?? "No passage in your history matches closely enough. Nothing is guessed.", systemImage: "magnifyingglass")
                    }
                    ForEach(r.memories, id: \.memory.id) { m in
                        NavigationLink { MemoryDetailView(memoryID: m.memory.id) } label: { NoteRow(note: m.memory) }.buttonStyle(.plain)
                    }
                    ForEach(r.spans) { s in
                        NavigationLink { ConversationReaderView(conversationID: s.conversationID, highlight: Set(s.anchorMessageIDs)) } label: { SpanCard(span: s) }.buttonStyle(.plain)
                    }
                    ForEach(r.assets, id: \.asset.id) { a in
                        HStack { Image(systemName: a.asset.kind == "photo" ? "photo" : "doc.text"); VStack(alignment: .leading) { Text(a.asset.name ?? a.asset.externalID).font(PBFont.bodyHeavy); Text(a.reason).font(PBFont.meta).foregroundStyle(p.sub) } }.card()
                    }
                }
            }
            .padding(.horizontal, PB.margin).padding(.bottom, 24)
        }
    }

    private var searchModeNote: String {
        app.loadedEmbedderID == nil ? "Keyword search only. Install an embedding model in Models to also search by meaning." : "Searching by keywords and by meaning."
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let s = app.services else { return }
        busy = true
        Task {
            let t0 = Date()
            let r = try? await s.retriever.retrieve(q, context: RetrievalContext(now: Date()))
            result = r; elapsed = Date().timeIntervalSince(t0) * 1000; busy = false
        }
    }
}

struct SpanCard: View {
    let span: EvidenceSpan
    @Environment(\.palette) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(span.conversationTitle).font(PBFont.bodyHeavy).lineLimit(1)
                Spacer()
                Text(span.date.formatted(date: .abbreviated, time: .omitted)).font(PBFont.meta).foregroundStyle(p.sub)
            }
            ForEach(span.messages.filter { span.anchorMessageIDs.contains($0.id) }.prefix(2)) { m in
                Text(m.text).font(PBFont.body).lineLimit(4).multilineTextAlignment(.leading)
            }
            FlowLayout(spacing: 6) {
                ForEach(span.channels, id: \.self) { Chip(text: Self.channelName($0)) }
                if let o = span.outdated { Chip(text: "replaced later", systemImage: "arrow.triangle.2.circlepath") ; Text(o.currentText).font(PBFont.meta).foregroundStyle(p.sub) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }
    static func channelName(_ c: String) -> String {
        switch c { case "lexical": return "keywords"; case "vector": return "meaning"; case "fine": return "close meaning"; case "memory": return "a note"; case "entity": return "a person you named"; case "assoc": return "related"; default: return c }
    }
}
