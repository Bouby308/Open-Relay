import Foundation

/// Small read-only state shared by the watch app with its complications /
/// Smart Stack widget through the app group. No credentials, just display
/// data (latest chat title + preview).
///
/// Shared into both the watch app and `OpenRelayWatchWidgets`.
nonisolated struct WidgetState: Codable, Sendable, Equatable {
    var signedIn: Bool
    var chatId: String?
    var chatTitle: String?
    var preview: String?
    var updatedAt: Date
    /// A reply is being made right now (shows a dot on the complication).
    var replyInProgress: Bool = false

    static let placeholder = WidgetState(signedIn: true, chatId: nil, chatTitle: "Ask anything",
                                         preview: "Tap to talk to your assistant", updatedAt: Date())

    private static let key = "watch.widgetState"

    static func load() -> WidgetState? {
        guard let defaults = UserDefaults(suiteName: WatchProtocol.watchAppGroup),
              let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetState.self, from: data)
    }

    func save() {
        guard let defaults = UserDefaults(suiteName: WatchProtocol.watchAppGroup),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
