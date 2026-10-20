import SwiftUI
import PersonalAICore

struct ChatListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var path: [ChatRoute] = []
    @State private var confirmDelete: ConversationRecord?

    enum ChatRoute: Hashable { case chat(Int64?) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Chats", subtitle: app.storage.map { "\($0.messages.formatted()) messages on this iPhone" })
                    Button { path.append(.chat(nil)) } label: { Label("New chat", systemImage: "plus") }
                        .buttonStyle(LipButtonStyle(kind: .primary))
                    if let s = app.engineStatus { Chip(text: s, systemImage: "hourglass", emphasised: true) }
                    if app.loadedChatModelID == nil && app.engineStatus == nil { noModelCard }
                    if let b = app.banner { ErrorBanner(message: b, retry: nil, dismiss: { app.banner = nil }) }
                    if app.conversations.isEmpty {
                        EmptyState(title: "Nothing here yet", message: "Start a chat, or import your ChatGPT or Claude history from the Library tab so the assistant can remember it.", systemImage: "bubble.left.and.bubble.right")
                    } else {
                        ForEach(app.conversations) { c in
                            Button { path.append(.chat(c.id)) } label: { row(c) }.buttonStyle(.plain)
                                .contextMenu { Button("Delete conversation", systemImage: "trash", role: .destructive) { confirmDelete = c } }
                        }
                    }
                }
                .padding(.horizontal, PB.margin).padding(.top, 8).padding(.bottom, 24)
            }
            .scene()
            .navigationDestination(for: ChatRoute.self) { r in if case .chat(let id) = r { ChatView(conversationID: id).id(id ?? -1) } }
            .toolbar(.hidden, for: .navigationBar)
            .alert("Delete this conversation?", isPresented: .init(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { c in
                Button("Delete", role: .destructive) { if let s = app.services { _ = try? s.archive.eraseConversation(c.id); app.refreshConversations(); app.refreshStorage() } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("The messages, search entries and any notes learned only from them are removed from this phone. This can't be undone.") }
        }
    }

    private var noModelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No model loaded").font(PBFont.section)
            Text("Open the Models tab to download one. Until then you can browse and search your history, but not chat.").font(PBFont.body).foregroundStyle(p.sub)
        }.card()
    }

    private func row(_ c: ConversationRecord) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(c.title).font(PBFont.bodyHeavy).lineLimit(2)
                Text("\(c.messageCount) messages · \(Date(timeIntervalSince1970: c.updatedAt).formatted(date: .abbreviated, time: .omitted))").font(PBFont.meta).foregroundStyle(p.sub)
            }
            Spacer()
            if c.origin == "imported" { Sticker(text: "Imported", tilt: 3, fill: PB.violet) }
        }
        .padding(.vertical, 10).overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 2) }
        .contentShape(Rectangle())
    }
}
