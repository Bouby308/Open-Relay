import Foundation
import os.log

/// Loads and holds the two small voice-detection models shared by every call:
/// - **Silero VAD** — per-chunk speech probability, used every 32 ms.
/// - **Smart Turn v3.2** — "has the user actually finished talking?" classifier,
///   run on the last few seconds of audio when Silero reports sustained silence.
///
/// Both are Core ML models run on the **CPU only** (never Metal), so turn
/// detection and barge-in keep working while the app is backgrounded or the
/// phone is locked — MLX would need the GPU, which iOS forbids there.
///
/// ~18 MB total, downloaded once from Hugging Face into
/// `Documents/Models/coreml-vad/` and kept resident for the app's lifetime.
@MainActor @Observable
final class VADModelStore {

    enum LoadState: Sendable, Equatable {
        case unloaded
        case loading
        case ready
        case error(String)
    }

    private(set) var state: LoadState = .unloaded
    var isReady: Bool { state == .ready }

    static let sileroRepoID = "FluidInference/silero-vad-coreml"
    static let smartTurnRepoID = "aufklarer/Smart-Turn-v3.2-CoreML"

    private let logger = Logger(subsystem: "com.openui", category: "VADModelStore")

    // nonisolated(unsafe): written on @MainActor before a call starts; during
    // a call only used inside the `VADPipeline` actor.
    @ObservationIgnored nonisolated(unsafe) private(set) var silero: CoreMLSileroVAD?
    @ObservationIgnored nonisolated(unsafe) private(set) var smartTurn: CoreMLSmartTurn?

    private var loadTask: Task<Void, Never>?

    nonisolated static var baseDirectory: URL {
        StorageManager.modelCacheDirectory.appendingPathComponent("coreml-vad", isDirectory: true)
    }

    /// Loads both models if not already loaded/loading. Safe to call repeatedly.
    /// Silero and Smart Turn load independently: if only Smart Turn fails the
    /// call still has Silero (end-of-turn then trusts the silence timer).
    func loadIfNeeded() async {
        if isReady { return }
        if let loadTask {
            await loadTask.value
            return
        }

        state = .loading
        let logger = self.logger
        let task = Task { [weak self] in
            async let sileroLoad = Self.loadSilero(logger: logger)
            async let smartTurnLoad = Self.loadSmartTurn(logger: logger)
            let (loadedSilero, loadedSmartTurn) = await (sileroLoad, smartTurnLoad)
            guard let self else { return }
            self.silero = loadedSilero
            self.smartTurn = loadedSmartTurn
            if loadedSilero != nil {
                self.state = .ready
                self.logger.info("VAD models ready (Core ML, CPU) — Smart Turn: \(loadedSmartTurn != nil)")
            } else {
                self.state = .error("Silero VAD unavailable")
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// Waits for models to be ready with a timeout. Returns true if ready.
    func waitUntilReady(timeout: TimeInterval = 5) async -> Bool {
        if isReady { return true }
        await loadIfNeeded()
        if isReady { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isReady { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return isReady
    }

    func unload() {
        silero = nil
        smartTurn = nil
        state = .unloaded
    }
}


// MARK: - Loading

extension VADModelStore {

    fileprivate nonisolated static func loadSilero(logger: Logger) async -> CoreMLSileroVAD? {
        do {
            let url = try await resolveModel(
                repo: sileroRepoID, directory: CoreMLSileroVAD.modelDirectoryName,
                files: modelFiles + ["metadata.json"], logger: logger
            )
            return try await Task.detached(priority: .userInitiated) {
                try CoreMLSileroVAD(modelURL: url)
            }.value
        } catch {
            logger.error("Silero (Core ML) load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    fileprivate nonisolated static func loadSmartTurn(logger: Logger) async -> CoreMLSmartTurn? {
        do {
            let url = try await resolveModel(
                repo: smartTurnRepoID, directory: CoreMLSmartTurn.modelDirectoryName,
                files: modelFiles, logger: logger
            )
            return try await Task.detached(priority: .userInitiated) {
                let model = try CoreMLSmartTurn(modelURL: url)
                model.warmUp()
                return model
            }.value
        } catch {
            logger.error("Smart Turn (Core ML) load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Files that make up a compiled `.mlmodelc` bundle in these repos.
    private nonisolated static let modelFiles = [
        "coremldata.bin",
        "analytics/coremldata.bin",
        "model.mil",
        "weights/weight.bin",
    ]

    /// Returns the local `.mlmodelc` directory, downloading its files directly
    /// from `huggingface.co/<repo>/resolve/main/…` the first time. Downloads go
    /// to a staging folder that is only moved into place once every file is
    /// complete, so a half-finished download never looks usable.
    private nonisolated static func resolveModel(
        repo: String, directory: String, files: [String], logger: Logger
    ) async throws -> URL {
        let fm = FileManager.default
        let repoDir = baseDirectory.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"))
        let modelURL = repoDir.appendingPathComponent(directory, isDirectory: true)
        if isComplete(modelURL) { return modelURL }

        let staging = repoDir.appendingPathComponent(directory + ".partial", isDirectory: true)
        try? fm.removeItem(at: repoDir)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        logger.info("Downloading \(repo, privacy: .public)/\(directory, privacy: .public)")

        for file in files {
            guard let remote = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(directory)/\(file)") else {
                throw URLError(.badURL)
            }
            let (tmp, response) = try await URLSession.shared.download(from: remote)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                try? fm.removeItem(at: tmp)
                try? fm.removeItem(at: repoDir)
                logger.error("Model file \(file, privacy: .public) failed: HTTP \(status)")
                throw URLError(.badServerResponse)
            }
            let dest = staging.appendingPathComponent(file)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
        }

        guard isComplete(staging) else {
            try? fm.removeItem(at: repoDir)
            throw URLError(.cannotDecodeContentData)
        }
        try fm.moveItem(at: staging, to: modelURL)
        return modelURL
    }

    /// A compiled model folder is usable once its `coremldata.bin` and weights exist.
    private nonisolated static func isComplete(_ modelURL: URL) -> Bool {
        let fm = FileManager.default
        let weights = modelURL.appendingPathComponent("weights/weight.bin")
        let size = (try? fm.attributesOfItem(atPath: weights.path)[.size] as? Int) ?? 0
        return fm.fileExists(atPath: modelURL.appendingPathComponent("coremldata.bin").path) && size > 0
    }
}
