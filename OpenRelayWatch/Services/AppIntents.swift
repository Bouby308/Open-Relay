import AppIntents
import Foundation

// MARK: - Siri / Shortcuts / Action button
//
// Intents open the app (the watch can only reliably reach the iPhone while
// Open Relay is in front) and hand over what to do via `PendingLaunch`.

struct AskOpenRelayIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Open Relay"
    static let description = IntentDescription("Ask your AI assistant a question and hear the answer.")
    static let openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Open Relay \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingLaunch.set(.ask(question))
        return .result()
    }
}

struct TalkToOpenRelayIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Open Relay"
    static let description = IntentDescription("Start a spoken conversation with your AI assistant.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingLaunch.set(.talk)
        return .result()
    }
}

struct OpenRelayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOpenRelayIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
            shortTitle: "Ask",
            systemImageName: "text.bubble.fill"
        )
        AppShortcut(
            intent: TalkToOpenRelayIntent(),
            phrases: ["Talk to \(.applicationName)", "Start \(.applicationName)"],
            shortTitle: "Talk",
            systemImageName: "waveform"
        )
    }
}

/// What the app should do on next activation (set by intents / controls).
@MainActor
enum PendingLaunch {
    enum Action: Equatable { case talk, ask(String) }

    private(set) static var action: Action?
    /// Bumped on every set so the UI reacts even for the same action twice.
    static var onChange: (() -> Void)?

    static func set(_ action: Action) {
        self.action = action
        onChange?()
    }

    static func take() -> Action? {
        defer { action = nil }
        return action
    }
}
