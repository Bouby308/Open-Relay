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
