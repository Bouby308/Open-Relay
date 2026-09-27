import Foundation

/// Serialises synchronous MLX inference across the call's MLX engines
/// (MLX STT, and the gate checked by MLX TTS) so graphs are never built from
/// two threads at once. Recursive so nested `eval` calls inside a locked
/// block are fine.
///
/// Also the call's GPU gate: once the app is about to leave the foreground
/// (`willResignActive`) `gpuAllowed` is cleared and `run` throws instead of
/// submitting Metal work, which iOS would answer with abort(). Voice
/// detection no longer uses MLX (it's Core ML, CPU-only), so it's unaffected.
nonisolated enum MLXCallLock {
    struct GPUUnavailable: Error {}

    private static let lock = NSRecursiveLock()
    private static let flagLock = NSLock()
    nonisolated(unsafe) private static var _gpuAllowed = true

    static var gpuAllowed: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return _gpuAllowed }
        set { flagLock.lock(); _gpuAllowed = newValue; flagLock.unlock() }
    }

    /// GPU work. Throws `GPUUnavailable` while the app isn't active.
    static func run<R>(_ body: () throws -> R) throws -> R {
        lock.lock()
        defer { lock.unlock() }
        guard gpuAllowed else { throw GPUUnavailable() }
        return try body()
    }
}
