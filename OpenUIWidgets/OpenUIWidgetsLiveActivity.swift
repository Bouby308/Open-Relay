//
//  OpenUIWidgetsLiveActivity.swift
//  OpenUIWidgets
//
//
//  Voice-call Live Activity: Dynamic Island (compact / minimal / expanded)
//  and the Lock Screen banner. `VoiceCallActivityAttributes` and the two
//  button intents live in the app target and are shared with this extension.
//

import ActivityKit
import AppIntents
import WidgetKit
import SwiftUI

struct VoiceCallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceCallActivityAttributes.self) { context in
            VoiceCallLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(OpenUIURL.voiceCall)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        PhaseIcon(phase: context.state.phase, size: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(context.attributes.modelName)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            Text(context.state.phase.label)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CallTimer(start: context.attributes.startDate)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CallButtons(isMuted: context.state.isMuted)
                        .padding(.top, 6)
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase, size: 13)
            } compactTrailing: {
                if context.state.isMuted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                } else {
                    CallTimer(start: context.attributes.startDate)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(maxWidth: 44)
                }
            } minimal: {
                PhaseIcon(phase: context.state.phase, size: 12)
            }
            .widgetURL(OpenUIURL.voiceCall)
            .keylineTint(PhaseIcon.color(for: context.state.phase))
        }
    }
}

// MARK: - Lock Screen

private struct VoiceCallLockScreenView: View {
    let context: ActivityViewContext<VoiceCallActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(PhaseIcon.color(for: context.state.phase).opacity(0.2))
                    .frame(width: 42, height: 42)
                PhaseIcon(phase: context.state.phase, size: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.modelName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(context.state.phase.label)
                    Text("·")
                    CallTimer(start: context.attributes.startDate)
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 8)
            CallButtons(isMuted: context.state.isMuted, compact: true)
        }
        .padding(14)
    }
}
// MARK: - Pieces

private struct PhaseIcon: View {
    let phase: VoiceCallActivityAttributes.Phase
    let size: CGFloat

    static func color(for phase: VoiceCallActivityAttributes.Phase) -> Color {
        switch phase {
        case .listening:  return .blue
        case .speaking:   return .green
        case .thinking:   return .purple
        case .paused:     return .orange
        case .connecting: return .gray
        }
    }

    var body: some View {
        Image(systemName: phase.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Self.color(for: phase))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// Self-updating elapsed timer — no Live Activity update needed each second.
private struct CallTimer: View {
    let start: Date

    var body: some View {
        Text(timerInterval: start...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

private struct CallButtons: View {
    let isMuted: Bool
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            Button(intent: ToggleVoiceCallMuteIntent()) {
                label(isMuted ? "mic.slash.fill" : "mic.fill",
                      text: isMuted ? "Unmute" : "Mute",
                      tint: isMuted ? .orange : .white.opacity(0.2))
            }
            .buttonStyle(.plain)

            Button(intent: EndVoiceCallIntent()) {
                label("phone.down.fill", text: "End", tint: .red)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func label(_ symbol: String, text: String, tint: Color) -> some View {
        if compact {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint, in: Circle())
        } else {
            Label(text, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(tint, in: Capsule())
        }
    }
}


