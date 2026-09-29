import Foundation
import AVFoundation

extension AudioRoute {
    /// The current output route of the shared audio session.
    static func current(_ session: AVAudioSession = .sharedInstance()) -> AudioRoute {
        let outputs = session.currentRoute.outputs
        if outputs.contains(where: { $0.portType == .builtInSpeaker }) { return .speaker }
        let wireless: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .carAudio,
        ]
        if outputs.contains(where: { wireless.contains($0.portType) }) { return .bluetooth }
        return .isolated
    }
}

/// Where call audio is currently heard — drives the route button's icon.
enum CallOutputRoute: Equatable, Sendable {
    case earpiece
    case speaker
    case airpods
    case headphones
    case car
    case bluetoothSpeaker
    case other

    /// Ports that mean "the user has a device connected" — the call should
    /// go there instead of being forced onto the phone's speaker.
    nonisolated static let externalOutputs: Set<AVAudioSession.Port> = [
        .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .carAudio,
        .headphones, .usbAudio, .airPlay,
    ]
    nonisolated static let externalInputs: Set<AVAudioSession.Port> = [
        .bluetoothHFP, .carAudio, .headsetMic, .usbAudio,
    ]

    /// True when a headset / car / wired device is connected — either
    /// already the output, or offering a mic (right after it connects the
    /// route may still briefly report the built-in speaker).
    nonisolated static func hasExternalDevice(_ session: AVAudioSession = .sharedInstance()) -> Bool {
        if session.currentRoute.outputs.contains(where: { externalOutputs.contains($0.portType) }) { return true }
        return (session.availableInputs ?? []).contains { externalInputs.contains($0.portType) }
    }

    nonisolated static func current(_ session: AVAudioSession = .sharedInstance()) -> CallOutputRoute {
        guard let port = session.currentRoute.outputs.first else { return .other }
        switch port.portType {
        case .builtInReceiver: return .earpiece
        case .builtInSpeaker: return .speaker
        case .carAudio: return .car
        case .headphones, .usbAudio: return .headphones
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            let name = port.portName.lowercased()
            if name.contains("airpods") { return .airpods }
            if name.contains("car") || name.contains("auto") { return .car }
            if name.contains("speaker") || name.contains("boom") || name.contains("soundlink") {
                return .bluetoothSpeaker
            }
            return .headphones
        default: return .other
        }
    }

    var iconName: String {
        switch self {
        case .earpiece: return "iphone"
        case .speaker: return "speaker.wave.3.fill"
        case .airpods: return "airpods"
        case .headphones: return "headphones"
        case .car: return "car.fill"
        case .bluetoothSpeaker: return "hifispeaker.fill"
        case .other: return "airplayaudio"
        }
    }

    /// Highlighted whenever audio isn't on the plain earpiece.
    var isHighlighted: Bool { self != .earpiece }

    var accessibilityLabel: String {
        switch self {
        case .earpiece: return "Audio output: iPhone"
        case .speaker: return "Audio output: Speaker"
        case .airpods: return "Audio output: AirPods"
        case .headphones: return "Audio output: Headphones"
        case .car: return "Audio output: Car"
        case .bluetoothSpeaker: return "Audio output: Bluetooth speaker"
        case .other: return "Audio output"
        }
    }
}
