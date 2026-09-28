import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Control Center / Smart Stack control (watchOS 26+)

/// Opens Open Relay straight into Talk. Uses a URL so the control works
/// without sharing intent code between the extension and the app.
@available(watchOS 26.0, *)
struct TalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.openui.watch.control.talk") {
            ControlWidgetButton(action: OpenTalkIntent()) {
                Label("Talk", systemImage: "waveform")
            }
        }
        .displayName("Talk to Open Relay")
        .description("Start a conversation with your AI assistant.")
    }
}

@available(watchOS 26.0, *)
struct OpenTalkIntent: OpenIntent {
    static let title: LocalizedStringResource = "Talk to Open Relay"
    static let isDiscoverable = false

    @Parameter(title: "Destination")
    var target: TalkDestination

    init() { target = .talk }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "openrelay://talk")!))
    }
}

@available(watchOS 26.0, *)
enum TalkDestination: String, AppEnum {
    case talk
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static let caseDisplayRepresentations: [TalkDestination: DisplayRepresentation] = [.talk: "Talk"]
}
