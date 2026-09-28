import SwiftUI

/// Under the orb in Talk: your words, the reply (auto-scrolls; Crown scrolls
/// back), then follow-up chips.
struct TalkContentView: View {
    let turn: TurnController
    let capture: VoiceCapture
    let onChip: (String) -> Void

    private var yourWords: String? {
        if capture.state == .listening { return turn.liveTranscript }
        return turn.prompt ?? turn.liveTranscript
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let words = yourWords, !words.isEmpty {
                        Text(words)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("You said: \(words)")
                    }
                    if !turn.reply.isEmpty {
                        Text(turn.reply)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !turn.isBusy, !turn.followUps.isEmpty {
                        ChipsView(items: turn.followUps.map { ($0, $0) }, systemImage: "arrow.turn.down.right",
                                  onTap: onChip)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: turn.reply) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: turn.followUps) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }
}

/// Tappable follow-up suggestion chips.
struct ChipsView: View {
    /// (label, text to send)
    let items: [(String, String)]
    let systemImage: String
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button { onTap(item.1) } label: {
                    Label(item.0, systemImage: systemImage)
                        .font(.footnote)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Sends this message")
            }
        }
    }
}
