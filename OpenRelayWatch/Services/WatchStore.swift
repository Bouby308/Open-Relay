import Foundation
import Observation

/// Home data + user preferences for the watch app. The snapshot is cached
/// on disk so the lists show instantly on launch, then refreshed from the
/// iPhone.
@MainActor @Observable
final class WatchStore {

    static let shared = WatchStore()

    private(set) var snapshot: WatchSnapshot
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    /// True when the iPhone says it isn't signed in / Apple Watch is off.
    private(set) var needsPhone = false

    /// Model for new chats started on the watch (`nil` = server default).
    var selectedModelId: String? {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: Keys.model) }
    }
    /// Read replies aloud after asking (voice mode always speaks).
    var speakReplies: Bool {
        didSet { UserDefaults.standard.set(speakReplies, forKey: Keys.speak) }
    }
    /// Watch reply voice: "apple" (built in, default) or "server".
    var voice: String {
        didSet { UserDefaults.standard.set(voice, forKey: Keys.voice) }
    }
    var usesServerVoice: Bool { voice == "server" }
    /// Talk: speaking over a reply stops it and listens.
    var interruptBySpeaking: Bool {
        didSet { UserDefaults.standard.set(interruptBySpeaking, forKey: Keys.interrupt) }
    }

    private enum Keys {
        static let snapshot = "watch.snapshot"
        static let model = "watch.modelId"
        static let speak = "watch.speakReplies"
        static let voice = "watch.voice"
        static let interrupt = "watch.interrupt"
        static let lastChat = "watch.lastChat"
    }

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.snapshot),
           let cached = try? JSONDecoder().decode(WatchSnapshot.self, from: data) {
            snapshot = cached
        } else {
            snapshot = .empty
        }
        selectedModelId = defaults.string(forKey: Keys.model)
        speakReplies = defaults.object(forKey: Keys.speak) as? Bool ?? false
        voice = defaults.string(forKey: Keys.voice) ?? "apple"
        // Talk to Interrupt isn't reliable yet on the watch speaker — off by default.
        interruptBySpeaking = defaults.object(forKey: Keys.interrupt) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.lastChat) {
            lastChat = try? JSONDecoder().decode(LastChat.self, from: data)
        }
        if !snapshot.signedIn { lastChat = nil }
    }

    var hasData: Bool { snapshot.updatedAt > .distantPast }

    var selectedModelName: String {
        let id = selectedModelId ?? snapshot.defaultModelId
        return snapshot.models.first { $0.id == id }?.name ?? "Default model"
    }

    /// Model to send with a new chat, dropping a choice that no longer exists.
    var effectiveModelId: String? {
        guard let id = selectedModelId, snapshot.models.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func apply(_ new: WatchSnapshot) {
        guard new.updatedAt >= snapshot.updatedAt || !new.signedIn else { return }
        needsPhone = !new.signedIn
        if !new.signedIn {
            // Signed out / switched account on the iPhone: never keep showing
            // the previous account's chats or channels.
            snapshot = WatchSnapshot.empty
            snapshot.updatedAt = new.updatedAt
            lastChat = nil
            lastError = "Open Open Relay on your iPhone and sign in."
        } else {
            snapshot = new
            lastError = nil
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Keys.snapshot)
        }
        WidgetBridge.update(from: snapshot, lastChat: lastChat)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await WatchLink.shared.request(.snapshot, WatchEmpty(), as: WatchSnapshot.self, attempts: 2)
            lastError = nil
            apply(fresh)
        } catch LinkError.needsPhone(let message) {
            needsPhone = true
            lastError = message
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Updates a chat's place in the list after the watch used it.
    func noteChat(id: String, title: String?, preview: String? = nil) {
        var chats = snapshot.chats
        let existing = chats.first { $0.id == id }
        chats.removeAll { $0.id == id }
        let summary = WatchChatSummary(id: id, title: title ?? existing?.title ?? "New Chat",
                                       updatedAt: Date(), pinned: existing?.pinned ?? false)
        let pinnedCount = chats.prefix { $0.pinned }.count
        chats.insert(summary, at: summary.pinned ? 0 : pinnedCount)
        snapshot.chats = chats
        lastChat = LastChat(id: id, title: summary.title, preview: preview, date: Date())
        WidgetBridge.update(from: snapshot, lastChat: lastChat)
    }

    /// The chat most recently used on the watch (Home "Continue" banner).
    private(set) var lastChat: LastChat? {
        didSet {
            if let data = try? JSONEncoder().encode(lastChat) { UserDefaults.standard.set(data, forKey: Keys.lastChat) }
        }
    }

    struct LastChat: Codable, Equatable {
        let id: String
        let title: String
        let preview: String?
        let date: Date
    }
}
