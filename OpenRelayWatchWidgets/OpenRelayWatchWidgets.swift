import SwiftUI
import WidgetKit

/// Watch face complications, Smart Stack widget and Control Center control.
/// Shortcuts into the app plus a "Latest chat" widget fed by the watch app
/// through the shared app group (`WidgetState`).
@main
struct OpenRelayWatchWidgets: WidgetBundle {
    var body: some Widget {
        AskComplication()
        VoiceComplication()
        OpenRelayComplication()
        LatestChatWidget()
        if #available(watchOS 26.0, *) {
            TalkControl()
        }
    }
}

struct StaticEntry: TimelineEntry {
    let date: Date
    var state: WidgetState?
}

/// Reads the shared state; reloaded by the app whenever it changes.
struct StaticProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaticEntry { StaticEntry(date: .now, state: .placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (StaticEntry) -> Void) {
        completion(StaticEntry(date: .now, state: context.isPreview ? .placeholder : WidgetState.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StaticEntry>) -> Void) {
        let entry = StaticEntry(date: .now, state: WidgetState.load())
        // Refresh hourly so "2h ago" style text stays roughly right.
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

// MARK: - Talk

struct AskComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.openui.watch.ask", provider: StaticProvider()) { entry in
            ComplicationView(systemImage: "waveform", title: "Talk", subtitle: "Talk to Open Relay",
                             busy: entry.state?.replyInProgress == true)
                .widgetURL(URL(string: "openrelay://talk"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Talk")
        .description("Start a conversation with your AI assistant.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Type

struct VoiceComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.openui.watch.voice", provider: StaticProvider()) { _ in
            ComplicationView(systemImage: "keyboard", title: "Type", subtitle: "Type to Open Relay")
                .widgetURL(URL(string: "openrelay://type"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Type")
        .description("Start a conversation by typing or Scribble.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - App

struct OpenRelayComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.openui.watch.app", provider: StaticProvider()) { entry in
            ComplicationView(systemImage: "sparkles", title: "Open Relay",
                             subtitle: entry.state?.signedIn == false ? "Open on iPhone" : "Chats & channels",
                             inlineDate: entry.state?.chatId != nil ? entry.state?.updatedAt : nil)
                .widgetURL(URL(string: "openrelay://home"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Open Relay")
        .description("Open your chats and channels.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let systemImage: String
    let title: String
    let subtitle: String
    var busy = false
    var inlineDate: Date? = nil

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .widgetLabel(title)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.headline).widgetAccentable()
                    Text(busy ? "Answering…" : subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            if let inlineDate {
                Label { Text("Open Relay · \(inlineDate, style: .relative)") } icon: { Image(systemName: systemImage) }
            } else {
                Label(subtitle, systemImage: systemImage)
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .widgetAccentable()
                if busy {
                    Circle().fill(.tint).frame(width: 7, height: 7)
                        .offset(x: 13, y: -13)
                }
            }
            .accessibilityLabel(busy ? "\(title), reply on its way" : title)
        }
    }
}

// MARK: - Latest chat (Smart Stack)

struct LatestChatWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.openui.watch.latest", provider: StaticProvider()) { entry in
            LatestChatView(state: entry.state)
                .widgetURL(URL(string: entry.state?.chatId.map { "openrelay://chat/\($0)" } ?? "openrelay://talk"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Latest Chat")
        .description("Your most recent conversation. Tap to continue it.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct LatestChatView: View {
    let state: WidgetState?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: state?.replyInProgress == true ? "ellipsis.bubble.fill" : "bubble.left.fill")
                    .font(.caption2)
                    .widgetAccentable()
                Text(title).font(.headline).lineLimit(1).widgetAccentable()
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let date = state?.updatedAt, state?.chatId != nil {
                Text(date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        guard let state, state.signedIn else { return "Open Relay" }
        return state.chatTitle ?? "Ask anything"
    }

    private var detail: String {
        guard let state else { return "Tap to talk" }
        if !state.signedIn { return "Open Open Relay on your iPhone" }
        if state.replyInProgress { return "Answering…" }
        return state.preview ?? "Tap to talk"
    }
}
