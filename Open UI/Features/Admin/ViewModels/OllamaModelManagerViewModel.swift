import Foundation
import os.log

// MARK: - Pull State

struct OllamaPullState {
    var status: String
    var error: String?
    var task: Task<Void, Never>?
    // Per-layer byte tracking: digest → (completed, total)
    var layerBytes: [String: (completed: Int64, total: Int64)] = [:]

    /// Overall model progress 0–100, computed from all layers' bytes
    var overallProgress: Double? {
        let totalBytes = layerBytes.values.reduce(Int64(0)) { $0 + $1.total }
        let completedBytes = layerBytes.values.reduce(Int64(0)) { $0 + $1.completed }
        guard totalBytes > 0 else { return nil }
        return min(Double(completedBytes) / Double(totalBytes) * 100.0, 100.0)
    }
}

// MARK: - Create State

struct OllamaCreateState {
    var status: String
    var progress: Double?
    var error: String?
    var task: Task<Void, Never>?
}

// MARK: - OllamaModelManagerViewModel

@Observable
final class OllamaModelManagerViewModel {

    // MARK: - State

    var installedModels: [OllamaModelTag] = []
    var isLoadingModels = false
    var errorMessage: String?

    // Pull
    var pullModelName = ""
    var activePulls: [String: OllamaPullState] = [:]
    var duplicatePullName: String? = nil

    // Delete
    var selectedDeleteModel: String = ""
    var isDeletingModel = false
    var deleteError: String?
    var showDeleteConfirmation = false

    // Create
    var createModelTag = ""
    var createModelfileJSON = ""
    var createState: OllamaCreateState? = nil

    // Experimental section
    var showExperimental = false

    // GGUF upload mode — default to file mode
    var ggufMode: GGUFMode = .file
    var ggufURL = ""

    enum GGUFMode { case url, file }

    // GGUF file upload state
    var isUploadingGGUF = false
    var ggufUploadProgress: Double? = nil   // 0–100
    var ggufUploadStatus: String = ""
    var ggufUploadError: String? = nil
    private var ggufUploadTask: Task<Void, Never>? = nil

    // MARK: - Private

    private var apiClient: APIClient?
    var urlIndex: Int = 0
    private let logger = Logger(subsystem: "com.openui", category: "OllamaModelManager")

    // MARK: - Configure

    func configure(apiClient: APIClient?, urlIdx: Int) {
        self.apiClient = apiClient
        self.urlIndex = urlIdx
    }

    // MARK: - Load Models

    func loadModels() async {
        guard let api = apiClient else { return }
        isLoadingModels = true
        errorMessage = nil

        // Retry up to 2 times to handle sheet-transition cancellations.
        // When the sheet is presented from the Models tab a URLSession task can be
        // cancelled mid-flight by the animation; NetworkManager maps that to
        // APIError.cancelled before it reaches us, so we need to catch all three
        // cancellation representations: CancellationError, URLError(.cancelled),
        // and APIError.cancelled.
        for attempt in 0..<2 {
            if attempt > 0 {
                // Brief pause before retrying so the sheet animation has settled
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if Task.isCancelled { break }
            do {
                installedModels = try await api.getOllamaTags(urlIdx: urlIndex)
                break // success — stop retrying
            } catch {
                if isLoadCancellation(error) {
                    continue // cancelled by transition — retry
                }
                logger.error("Failed to load Ollama tags: \(error)")
                errorMessage = error.localizedDescription
                break
            }
        }
        isLoadingModels = false
    }

    private func isLoadCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlErr = error as? URLError, urlErr.code == .cancelled { return true }
        if let apiErr = error as? APIError, case .cancelled = apiErr { return true }
        return false
    }

    // MARK: - Pull Model

    func pullModel(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let api = apiClient else { return }

        // Duplicate guard
        if activePulls[trimmed] != nil {
            duplicatePullName = trimmed
            return
        }
        duplicatePullName = nil

        var state = OllamaPullState(status: "Starting…")
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = api.streamOllamaPull(name: trimmed, urlIdx: self.urlIndex)
                for try await event in stream {
                    if Task.isCancelled { break }
                    var current = self.activePulls[trimmed] ?? OllamaPullState(status: "")
                    current.status = event.status ?? ""
                    current.error = event.error

                    // Accumulate per-layer byte counts for whole-model progress
                    if let digest = event.digest,
                       let completed = event.completed,
                       let total = event.total,
                       total > 0 {
                        current.layerBytes[digest] = (completed: completed, total: total)
                    }

                    self.activePulls[trimmed] = current

                    if event.status == "success" {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await self.loadModels()
                        self.activePulls.removeValue(forKey: trimmed)
                        return
                    }
                    if let err = event.error {
                        var errState = self.activePulls[trimmed] ?? OllamaPullState(status: "error")
                        errState.error = err
                        self.activePulls[trimmed] = errState
                        return
                    }
                }
            } catch {
                if !Task.isCancelled {
                    var errState = self.activePulls[trimmed] ?? OllamaPullState(status: "error")
                    errState.error = error.localizedDescription
                    self.activePulls[trimmed] = errState
                }
            }
        }
        state.task = task
        activePulls[trimmed] = state
        pullModelName = ""
    }

    func cancelPull(name: String) {
        activePulls[name]?.task?.cancel()
        activePulls.removeValue(forKey: name)
    }

    func dismissPullError(name: String) {
        activePulls.removeValue(forKey: name)
    }

    // MARK: - Update All Models

    func updateAllModels() {
        for model in installedModels {
            pullModel(name: model.name)
        }
    }

    // MARK: - Delete Model

    func deleteModel() async {
        guard let api = apiClient else { return }
        let name = selectedDeleteModel
        guard !name.isEmpty else { return }

        isDeletingModel = true
        deleteError = nil
        do {
            try await api.deleteOllamaModel(name: name, urlIdx: urlIndex)
            await loadModels()
            selectedDeleteModel = ""
        } catch {
            logger.error("Failed to delete model \(name): \(error)")
            deleteError = error.localizedDescription
        }
        isDeletingModel = false
    }

    // MARK: - Create Model

    func createModel() {
        let tag = createModelTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText = createModelfileJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !jsonText.isEmpty else { return }
        guard let api = apiClient else { return }

        createState?.task?.cancel()

        var payload: [String: Any] = [:]
        if let data = jsonText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = parsed
        } else {
            createState = OllamaCreateState(status: "", error: "Invalid JSON in modelfile")
            return
        }

        var state = OllamaCreateState(status: "Starting…")
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = api.streamOllamaCreate(model: tag, payload: payload, urlIdx: self.urlIndex)
                for try await event in stream {
                    if Task.isCancelled { break }
                    var current = self.createState ?? OllamaCreateState(status: "")
                    current.status = event.status ?? ""
                    current.progress = event.progress.map { $0 * 100.0 }
                    current.error = event.error
                    self.createState = current

                    if event.status == "success" {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await self.loadModels()
                        self.createState = nil
                        self.createModelTag = ""
                        self.createModelfileJSON = ""
                        return
                    }
                    if let err = event.error {
                        var errState = self.createState ?? OllamaCreateState(status: "error")
                        errState.error = err
                        self.createState = errState
                        return
                    }
                }
            } catch {
                if !Task.isCancelled {
                    var errState = self.createState ?? OllamaCreateState(status: "error")
                    errState.error = error.localizedDescription
                    self.createState = errState
                }
            }
        }
        state.task = task
        createState = state
    }

    func cancelCreate() {
        createState?.task?.cancel()
        createState = nil
    }

    // MARK: - GGUF via URL (pull with hf.co URL)

    func pullGGUFFromURL() {
        let url = ggufURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        pullModel(name: url)
        ggufURL = ""
    }

    // MARK: - GGUF File Upload

    func uploadGGUFFile(url: URL) {
        guard let api = apiClient else { return }
        ggufUploadTask?.cancel()
        isUploadingGGUF = true
        ggufUploadProgress = nil
        ggufUploadStatus = "Reading file…"
        ggufUploadError = nil

        let urlIdx = urlIndex
        ggufUploadTask = Task { [weak self] in
            do {
                let digest = try await api.uploadOllamaBlob(fileURL: url, urlIdx: urlIdx) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.ggufUploadProgress = fraction * 100.0
                        self.ggufUploadStatus = fraction >= 1.0 ? "Done" : "Uploading…"
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.ggufUploadStatus = "Uploaded (sha256:\(String(digest.prefix(16)))…)"
                self.ggufUploadProgress = 100
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.isUploadingGGUF = false
                self.ggufUploadProgress = nil
                self.ggufUploadStatus = ""
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.ggufUploadError = error.localizedDescription
                self.isUploadingGGUF = false
            }
        }
    }

    func cancelGGUFUpload() {
        ggufUploadTask?.cancel()
        ggufUploadTask = nil
        isUploadingGGUF = false
        ggufUploadProgress = nil
        ggufUploadStatus = ""
        ggufUploadError = nil
    }

    // MARK: - Cancel All on Dismiss

    func cancelAllActiveTasks() {
        for (_, state) in activePulls {
            state.task?.cancel()
        }
        activePulls.removeAll()
        createState?.task?.cancel()
        createState = nil
        ggufUploadTask?.cancel()
        ggufUploadTask = nil
        isUploadingGGUF = false
    }
}
