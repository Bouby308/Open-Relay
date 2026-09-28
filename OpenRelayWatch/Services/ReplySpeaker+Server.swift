import AVFoundation
import Foundation

// MARK: - Server voice clips

extension ReplySpeaker {

    /// Downloads and schedules the server clip for sentence `index`.
    /// Returns false so the caller falls back to the Apple voice.
    func playServerClip(index: Int, gen: Int) async -> Bool {
        var parts: [Data] = []
        var total = 1
        var waits = 0
        while parts.count < total, gen == generation, !Task.isCancelled {
            let req = WatchClipRequest(turnId: turnId, index: index, part: parts.count)
            guard let envelope = try? WatchEnvelope.make(.replyAudio, payload: req),
                  let reply = try? await WatchLink.shared.sendWithRetry(envelope, attempts: 2) else { return false }
            let count = reply.seq ?? -1
            if count < 0 { return false }               // unavailable on the iPhone
            if count == 0 {                              // still being made
                waits += 1
                if waits > 60 { return false }           // ~15 s
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            total = count
            parts.append(reply.body)
        }
        guard gen == generation, parts.count == total,
              let buffer = Self.decode(parts.reduce(Data(), +)) else { return false }
        audio.schedule(buffer)
        return true
    }

    nonisolated static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            try file.read(into: buffer)
            return buffer
        } catch {
            return nil
        }
    }
}
