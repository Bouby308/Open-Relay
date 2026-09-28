import SwiftUI
import WatchKit

/// Open Relay for Apple Watch — a quick companion for the iPhone app.
///
/// Relay-only: the iPhone does all server work with the session it already
/// has, so the watch never signs in or stores credentials.
@main
struct OpenRelayWatchApp: App {
    @State private var link = WatchLink.shared
    @State private var store = WatchStore.shared
    @State private var router = WatchRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ReplyNotifier.shared.setUp()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(link)
                .environment(store)
                .environment(router)
                .onAppear {
                    link.activate()
                    let router = router
                    ReplyNotifier.shared.onOpenChat = { id, title in router.path = [.chat(id: id, title: title)] }
                    PendingLaunch.onChange = { router.consumePendingLaunch() }
                    router.consumePendingLaunch()
                }
                .onOpenURL { router.handle($0) }
                .onChange(of: link.pushedSnapshot) { _, snapshot in
                    if let snapshot { store.apply(snapshot) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                router.consumePendingLaunch()
                Task { await store.refresh() }
            }
        }
    }
}

/// Navigation state, driven by complications (`openrelay://…`), Siri /
/// Shortcuts and the UI.
@MainActor @Observable
final class WatchRouter {
    enum Route: Hashable {
        /// Talk screen. `typing` opens paused, ready for the keyboard;
        /// `prompt` sends that typed text right away.
        case talk(chatId: String? = nil, title: String? = nil, typing: Bool = false, prompt: String? = nil)
        case chat(id: String, title: String)
        case channel(id: String, name: String)
        case chats
        case channels
        case settings
    }

    var path: [Route] = []

    /// Siri / Shortcuts / Action button / Control Center.
    func consumePendingLaunch() {
        switch PendingLaunch.take() {
        case .talk: path = [.talk()]
        case .ask(let question): path = [.talk(prompt: question)]
        case nil: break
        }
    }

    /// `openrelay://talk`, `openrelay://type`, `openrelay://chat/{id}`
    /// (`ask` / `voice` from older complications still work).
    func handle(_ url: URL) {
        guard url.scheme == "openrelay" else { return }
        switch url.host() {
        case "talk", "voice": path = [.talk()]
        case "type", "ask": path = [.talk(typing: true)]
        case "chat":
            let id = url.lastPathComponent
            if !id.isEmpty, id != "/" {
                let title = WatchStore.shared.snapshot.chats.first { $0.id == id }?.title ?? "Chat"
                path = [.talk(chatId: id, title: title, typing: true)]
            }
        default: path = []
        }
    }
}

