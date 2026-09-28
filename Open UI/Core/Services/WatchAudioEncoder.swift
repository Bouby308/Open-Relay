import Foundation
import AVFoundation

/// Encodes reply speech for the watch: 24 kHz mono AAC in an m4a container.
nonisolated enum WatchAudioEncoder {

    /// Max bytes per `replyAudio` message (the envelope is JSON, so the
    /// bytes grow ~33% as base64 — still well under the WC message limit).
    static let partBytes = 24_000
    static let sampleRate: Double = 24_000

    static func split(_ data: Data) -> [Data] {
        var parts: [Data] = []
        var start = 0
        while start < data.count {
            let end = min(start + partBytes, data.count)
            parts.append(data.subdata(in: start..<end))
            start = end
        }
        return parts
    }

    static func encodeAAC(_ samples: [Float], sampleRate: Double) -> Data? {
        guard let pcm = resampled(samples, from: sampleRate) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]
        do {
            // Scoped so the file is closed (and finalized) before reading it back.
            try autoreleasepool {
                let file = try AVAudioFile(forWriting: url, settings: settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: pcm)
            }
            return try Data(contentsOf: url)
        } catch {
            return nil
        }
    }

    private static func resampled(_ samples: [Float], from rate: Double) -> AVAudioPCMBuffer? {
        guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { channel[i] = s }
        guard rate != sampleRate else { return input }

        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        let capacity = AVAudioFrameCount(Double(samples.count) * sampleRate / rate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? out : nil
    }
}
