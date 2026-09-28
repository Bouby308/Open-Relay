import AVFoundation
import Foundation

// MARK: - Sending audio to the iPhone

extension VoiceCapture {

    /// Sends chunks in order. A chunk is only dropped once the iPhone
    /// acknowledged it; while unreachable it waits and retries, so nothing
    /// recorded is lost. Up to `maxChunksPerMessage` go in one message when
    /// catching up.
    func startSender() {
        let source = buffer
        let id = turnId
        sender = Task { [weak self] in
            var seq = 0
            while !Task.isCancelled {
                guard let payload = source.peek(maxChunks: WatchProtocol.maxChunksPerMessage) else {
                    if source.isFinished && source.isDrained { break }
                    try? await Task.sleep(for: .milliseconds(80))
                    continue
                }
                let envelope = WatchEnvelope(type: .audioChunk, turn: id, seq: seq, body: payload.data)
                do {
                    _ = try await WatchLink.shared.send(envelope)
                    source.drop(bytes: payload.data.count)
                    seq += 1
                    self?.sentMessages = seq
                } catch let error as LinkError where !error.isTransient {
                    break
                } catch {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
}

/// Thread-safe 16 kHz Int16 byte queue filled by the mic tap.
nonisolated final class PCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var levelSum: Float = 0
    private var levelCount = 0
    private var finished = false

    struct Payload { let data: Data }

    func reset() {
        lock.lock(); data = Data(); finished = false; levelSum = 0; levelCount = 0; lock.unlock()
    }

    func append(_ bytes: Data, level: Float) {
        lock.lock()
        if !finished { data.append(bytes) }
        levelSum = max(levelSum, level)
        levelCount += 1
        lock.unlock()
    }

    /// Peak loudness since the last call.
    func takeLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        let value = levelSum
        levelSum = 0
        levelCount = 0
        return value
    }

    /// Up to `maxChunks` full chunks, or the final partial chunk once finished.
    func peek(maxChunks: Int) -> Payload? {
        lock.lock(); defer { lock.unlock() }
        let chunk = WatchProtocol.audioChunkBytes
        let full = data.count / chunk
        if full > 0 {
            return Payload(data: Data(data.prefix(min(full, maxChunks) * chunk)))
        }
        if finished && !data.isEmpty { return Payload(data: Data(data)) }
        return nil
    }

    func drop(bytes: Int) {
        lock.lock(); data.removeFirst(min(bytes, data.count)); lock.unlock()
    }

    func finish() { lock.lock(); finished = true; lock.unlock() }

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var isDrained: Bool { lock.lock(); defer { lock.unlock() }; return data.isEmpty }
}

nonisolated enum AudioConversion {
    /// Converts a native mic buffer to 16 kHz Int16 mono bytes.
    static func convert(_ pcm: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> Data {
        let ratio = format.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return Data() }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        guard error == nil, let ch = out.int16ChannelData?[0] else { return Data() }
        return Data(bytes: ch, count: Int(out.frameLength) * 2)
    }

    static func rms(_ pcm: AVAudioPCMBuffer) -> Float {
        guard let ch = pcm.floatChannelData?[0], pcm.frameLength > 0 else { return 0 }
        let n = Int(pcm.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return (sum / Float(n)).squareRoot()
    }
}
