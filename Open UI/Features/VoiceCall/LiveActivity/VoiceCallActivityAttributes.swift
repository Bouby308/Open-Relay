//
//  VoiceCallActivityAttributes.swift
//
//  Shared between the app and the OpenUIWidgets extension (target membership
//  is added via a pbxproj exception). Describes the voice-call Live Activity
//  shown in the Dynamic Island and on the Lock Screen, plus the two buttons it
//  offers. The intents run in the app process and post notifications that
//  `VoiceCallLiveActivityController` forwards to the active call.
//

import ActivityKit
import AppIntents
import Foundation

nonisolated struct VoiceCallActivityAttributes: ActivityAttributes {

    nonisolated enum Phase: String, Codable, Hashable, Sendable {
        case connecting, listening, thinking, speaking, paused

        var label: String {
            switch self {
            case .connecting: return "Connecting…"
            case .listening:  return "Listening"
            case .thinking:   return "Thinking…"
            case .speaking:   return "Speaking"
            case .paused:     return "Paused"
            }
        }

        var symbol: String {
            switch self {
            case .connecting: return "ellipsis"
            case .listening:  return "waveform"
            case .thinking:   return "sparkles"
            case .speaking:   return "speaker.wave.2.fill"
            case .paused:     return "pause.fill"
            }
        }
    }

    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
        var isMuted: Bool
    }

    /// Model the user is talking to.
    var modelName: String
    /// When the call connected — drives the self-updating timer.
    var startDate: Date
}

// MARK: - Notifications posted by the Live Activity buttons

nonisolated enum VoiceCallActivityNotification {
    static let toggleMute = Notification.Name("com.openui.voiceCall.activity.toggleMute")
    static let endCall    = Notification.Name("com.openui.voiceCall.activity.endCall")
}

// MARK: - Intents

/// Mutes / unmutes the mic from the Dynamic Island or Lock Screen.
nonisolated struct ToggleVoiceCallMuteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle Mute"
    static var description = IntentDescription("Mute or unmute the microphone during a voice call.")
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: VoiceCallActivityNotification.toggleMute, object: nil)
        }
        return .result()
    }
}

/// Ends the voice call from the Dynamic Island or Lock Screen.
nonisolated struct EndVoiceCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End Voice Call"
    static var description = IntentDescription("End the current voice call.")
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: VoiceCallActivityNotification.endCall, object: nil)
        }
        return .result()
    }
}
