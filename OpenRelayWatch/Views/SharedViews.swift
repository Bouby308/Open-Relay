import SwiftUI

/// A text field that opens the system input sheet (dictation, Scribble,
/// keyboard) straight away. Dictation runs on the watch, so only text is
/// sent to the iPhone.
struct DictationButton: View {
    let title: String
    let systemImage: String
    var prominent = true
    let onSubmit: (String) -> Void

    @State private var text = ""

    var body: some View {
        TextField(text: $text) {
            Label(title, systemImage: systemImage)
        }
        .textFieldStyle(.plain)
        .submitLabel(.send)
        .onSubmit {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            if !value.isEmpty { onSubmit(value) }
        }
        .padding(.vertical, prominent ? 6 : 2)
        .accessibilityLabel(title)
    }
}

/// The prompt + streaming reply for one turn.
struct TurnContentView: View {
    let turn: TurnController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prompt = turn.prompt {
                Text(prompt)
                    .font(.footnote)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .background(Color.accentColor.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            }
            switch turn.phase {
            case .sending, .transcribing, .thinking:
                HStack(spacing: 6) {
                    ProgressView().frame(width: 18, height: 18)
                    Text(statusText).font(.footnote).foregroundStyle(.secondary)
                }
            case .failed(let message):
                if !turn.reply.isEmpty { replyText }
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            case .streaming, .done:
                replyText
            case .idle:
                EmptyView()
            }
            if turn.isSpeaking {
                Label(turn.speaksOnPhone ? "Speaking on iPhone" : "Speaking", systemImage: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var replyText: some View {
        Text(turn.reply)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: String {
        switch turn.phase {
        case .transcribing: return "Listening back…"
        case .thinking: return "Thinking…"
        default: return "Sending…"
        }
    }
}

/// "Open on iPhone" via Handoff.
struct HandoffModifier: ViewModifier {
    let chatId: String?

    func body(content: Content) -> some View {
        content.userActivity(WatchProtocol.chatActivityType, isActive: chatId != nil) { activity in
            activity.title = "Continue chat"
            if let chatId { activity.addUserInfoEntries(from: [WatchProtocol.chatActivityIdKey: chatId]) }
            activity.isEligibleForHandoff = true
        }
    }
}

extension View {
    func handoff(chatId: String?) -> some View { modifier(HandoffModifier(chatId: chatId)) }
}
