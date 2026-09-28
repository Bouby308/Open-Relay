import SwiftUI

/// Home: Talk + Type up top, then recent chats, channels and settings.
struct HomeView: View {
    @Environment(WatchStore.self) private var store
    @Environment(WatchRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            List {
                if store.needsPhone || (!store.snapshot.signedIn && store.hasData) {
                    PhoneNoticeRow(message: store.lastError ?? "Open Open Relay on your iPhone and sign in.")
                } else if let error = store.lastError, !store.hasData {
                    PhoneNoticeRow(message: error)
                }

                // Two tiles in one List row: each needs its own button with a
                // borderless style, otherwise watchOS treats the whole row as one
                // tap target and fires both links (two screens get pushed).
                Section {
                    HStack(spacing: 8) {
                        Button { router.path.append(.talk()) } label: {
                            ActionTile(title: "Talk", systemImage: "waveform", tint: .accentColor)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityHint("Start a spoken conversation")

                        TextFieldLink(prompt: Text("Type a message")) {
                            Image(systemName: "keyboard")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 64)
                                .background(Color.gray.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } onSubmit: { text in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { router.path.append(.talk(prompt: trimmed)) }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Type a message")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if let last = store.lastChat, store.snapshot.signedIn {
                    Section {
                        Button {
                            router.path.append(.talk(chatId: last.id, title: last.title, typing: true))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Continue", systemImage: "arrow.uturn.forward")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tint)
                                Text(last.title).font(.footnote).lineLimit(1)
                            }
                        }
                        .accessibilityLabel("Continue \(last.title)")
                    }
                }


                if !store.snapshot.chats.isEmpty {
                    Section("Recent") {
                        ForEach(store.snapshot.chats.prefix(5)) { chat in
                            NavigationLink(value: WatchRouter.Route.chat(id: chat.id, title: chat.title)) {
                                ChatRow(chat: chat)
                            }
                        }
                        if store.snapshot.chats.count > 5 {
                            NavigationLink(value: WatchRouter.Route.chats) {
                                Label("All Chats", systemImage: "bubble.left.and.bubble.right")
                            }
                        }
                    }
                } else if store.isRefreshing && !store.hasData {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                }

                Section {
                    if !store.snapshot.channels.isEmpty {
                        NavigationLink(value: WatchRouter.Route.channels) {
                            Label("Channels", systemImage: "number")
                        }
                    }
                    NavigationLink(value: WatchRouter.Route.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Open Relay")
            .navigationDestination(for: WatchRouter.Route.self) { route in
                switch route {
                case .talk(let chatId, let title, let typing, let prompt):
                    TalkView(chatId: chatId, chatTitle: title, startTyping: typing, initialPrompt: prompt)
                case .chat(let id, let title): ChatView(chatId: id, title: title)
                case .channel(let id, let name): ChannelView(channelId: id, name: name)
                case .chats: ChatsListView()
                case .channels: ChannelsListView()
                case .settings: WatchSettingsView()
                }
            }
            .refreshable { await store.refresh() }
        }
    }
}

struct ActionTile: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
            Text(title)
                .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(tint.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

struct ChatRow: View {
    let chat: WatchChatSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if chat.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text(chat.title).font(.body).lineLimit(2)
            }
            Text(chat.updatedAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chat.pinned ? "Pinned. " : "")\(chat.title)")
    }
}

struct PhoneNoticeRow: View {
    let message: String

    var body: some View {
        Label {
            Text(message).font(.footnote)
        } icon: {
            Image(systemName: "iphone.gen3").foregroundStyle(.orange)
        }
        .listRowBackground(Color.orange.opacity(0.15).clipShape(RoundedRectangle(cornerRadius: 12)))
    }
}
