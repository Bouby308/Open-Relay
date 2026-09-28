import Foundation

// MARK: - Downloads, Reading & Saving

extension TerminalBrowserViewModel {

    /// Downloads a file (or a folder as ZIP) to a private temp location with
    /// progress. The returned object owns the file; it's deleted when released.
    func download(_ item: TerminalFileItem, asArchive: Bool? = nil) async -> DownloadedTerminalFile? {
        guard let apiClient, let scope = apiClient.network.conversationCacheScope else { return nil }
        let archive = asArchive ?? item.isDirectory
        let name = archive ? "\(item.name).zip" : item.name
        transferName = name
        transferReceived = 0
        transferExpected = item.isDirectory ? -1 : (item.size ?? -1)
        defer { transferName = nil }
        do {
            let request = archive
                ? try apiClient.terminalArchiveRequest(serverId: serverId, paths: [item.path], sessionId: chatId)
                : try apiClient.terminalViewRequest(serverId: serverId, path: item.path, sessionId: chatId)
            // Version the cache key by mtime/size so edited files aren't served stale.
            let version = "\(item.modified?.timeIntervalSince1970 ?? 0):\(item.size ?? -1):\(archive ? Date().timeIntervalSince1970 : 0)"
            let identity = ["browser", serverId, chatId ?? "", item.path, version].joined(separator: "\0")
            return try await TerminalFileDownloads.shared.file(
                request: request, session: apiClient.network.session, scope: scope,
                identity: identity, name: name
            ) { [box = WeakBrowserBox(self)] received, expected in
                Task { @MainActor in
                    guard let self = box.value, self.transferName == name else { return }
                    self.transferReceived = received
                    if expected > 0 { self.transferExpected = expected }
                }
            }
        } catch is CancellationError {
            return nil
        } catch {
            showBanner("Download failed: \(describe(error))", style: .error)
            return nil
        }
    }

    /// Zips several entries into one archive.
    func downloadArchive(of paths: [String]) async -> DownloadedTerminalFile? {
        guard let apiClient, let scope = apiClient.network.conversationCacheScope, !paths.isEmpty else { return nil }
        let name = paths.count == 1 ? "\(TerminalPath.name(of: paths[0])).zip" : "\(TerminalPath.name(of: currentPath) == "/" ? "files" : TerminalPath.name(of: currentPath)).zip"
        transferName = name
        transferReceived = 0
        transferExpected = -1
        defer { transferName = nil }
        do {
            let request = try apiClient.terminalArchiveRequest(serverId: serverId, paths: paths, sessionId: chatId)
            let identity = ["archive", serverId, chatId ?? "", paths.joined(separator: "|"), "\(Date().timeIntervalSince1970)"].joined(separator: "\0")
            return try await TerminalFileDownloads.shared.file(
                request: request, session: apiClient.network.session, scope: scope, identity: identity, name: name
            ) { [box = WeakBrowserBox(self)] received, _ in
                Task { @MainActor in
                    guard let self = box.value, self.transferName == name else { return }
                    self.transferReceived = received
                }
            }
        } catch {
            showBanner("Download failed: \(describe(error))", style: .error)
            return nil
        }
    }

    /// Reads a text file for the viewer/editor.
    func readText(_ path: String) async throws -> String? {
        guard let apiClient else { throw URLError(.notConnectedToInternet) }
        return try await apiClient.terminalReadFile(serverId: serverId, path: path, sessionId: chatId)
    }

    func saveText(_ path: String, content: String) async throws {
        guard let apiClient else { throw URLError(.notConnectedToInternet) }
        try await apiClient.terminalSaveTextFile(serverId: serverId, path: path, content: content, sessionId: chatId)
        // Keep the listing's size/date fresh if the file is visible.
        if TerminalPath.parent(of: path) == currentPath { Task { await reload() } }
    }

    func previewPDF(_ path: String) async -> Data? {
        guard let apiClient else { return nil }
        return try? await apiClient.terminalPreviewPDF(serverId: serverId, path: path, sessionId: chatId)
    }

    func compare(_ original: String, _ revised: String, ignoreWhitespace: Bool) async throws -> TerminalComparison {
        guard let apiClient else { throw URLError(.notConnectedToInternet) }
        return try await apiClient.terminalCompareFiles(serverId: serverId, original: original, revised: revised,
                                                        ignoreWhitespace: ignoreWhitespace, sessionId: chatId)
    }

    func portURL(_ port: Int, path: String = "") -> URL? {
        apiClient?.terminalPortProxyURL(serverId: serverId, port: port, path: path)
    }

    // MARK: - Search

    /// Debounced search of names and contents under the current folder.
    func searchQueryChanged() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let apiClient else {
            searchResults = []
            searchError = nil
            searchNextOffset = nil
            isSearchLoading = false
            return
        }
        isSelecting = false
        isSearchLoading = true
        searchError = nil
        let server = serverId, chat = chatId, path = currentPath, hidden = showHidden
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let page = try await apiClient.terminalFileMatches(serverId: server, query: query, path: path,
                                                                   showHidden: hidden, offset: 0, sessionId: chat)
                guard let self, !Task.isCancelled else { return }
                self.searchResults = page.results
                self.searchNextOffset = page.nextOffset
                self.isSearchLoading = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.searchResults = []
                self.searchError = "Search failed: \(self.describe(error))"
                self.isSearchLoading = false
            }
        }
    }

    func loadMoreSearchResults() async {
        guard let apiClient, let offset = searchNextOffset, !isLoadingMoreResults, !isSearchLoading else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoadingMoreResults = true
        defer { isLoadingMoreResults = false }
        do {
            let page = try await apiClient.terminalFileMatches(serverId: serverId, query: query, path: currentPath,
                                                               showHidden: showHidden, offset: offset, sessionId: chatId)
            guard query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            let known = Set(searchResults.map(\.path))
            searchResults += page.results.filter { !known.contains($0.path) }
            searchNextOffset = page.nextOffset
        } catch {
            searchNextOffset = nil
        }
    }

    // MARK: - Ports

    func startPortPolling() {
        portsTask?.cancel()
        guard apiClient != nil, !requiresSavedChat else { return }
        portsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadPorts()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopPortPolling() {
        portsTask?.cancel()
        portsTask = nil
    }

    func loadPorts() async {
        guard let apiClient, isConfigured else { return }
        isLoadingPorts = true
        let fetched = (try? await apiClient.terminalListeningPorts(serverId: serverId, sessionId: chatId)) ?? []
        isLoadingPorts = false
        if fetched != ports { ports = fetched.sorted { $0.port < $1.port } }
    }

    // MARK: - Chat Events

    /// Reacts to `terminal:*` socket events from the model's tool calls.
    func handleChatEvent(type: String, path: String?) {
        guard isConfigured else { return }
        switch type {
        case "terminal:display_file":
            guard let path, !path.isEmpty else { return }
            let file = TerminalFileItem(name: TerminalPath.name(of: path), path: TerminalPath.directory(path), isDirectory: false)
            pendingOpenFile = file
            let parent = TerminalPath.parent(of: file.path)
            if !didBootstrap {
                // Bootstrap starts in the pending file's folder.
                Task { await bootstrap() }
            } else if parent != currentPath {
                Task { await load(path: clampToRoot(parent), recordHistory: true) }
            }
        case "terminal:write_file", "terminal:replace_file_content":
            guard let path else { refresh(); return }
            let parent = TerminalPath.parent(of: TerminalPath.directory(path))
            if parent == currentPath || expandedDirs.contains(parent) || TerminalPath.isInside(currentPath, parent) { refresh() }
        case "terminal:run_command":
            refresh()
            processes.refreshSoon()
        default:
            break
        }
    }
}

/// Sendable weak reference for progress callbacks from background queues.
nonisolated final class WeakBrowserBox: @unchecked Sendable {
    weak var value: TerminalBrowserViewModel?
    init(_ value: TerminalBrowserViewModel) { self.value = value }
}
