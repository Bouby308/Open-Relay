import Foundation
import os.log

// MARK: - Lifecycle, Navigation & Listing

extension TerminalBrowserViewModel {

    // MARK: Panel lifecycle

    /// Call when the panel slides on screen.
    func handlePanelOpened() {
        isPanelOpen = true
        if isTerminalExpanded {
            shell.panelDidAppear()
            processes.setActive(true)
        }
        startPortPolling()
        Task { await bootstrap() }
    }

    /// Call when the panel is hidden. The shell socket is closed but the PTY
    /// is kept so it can resume.
    func handlePanelClosed() {
        isPanelOpen = false
        shell.panelDidDisappear()
        processes.setActive(false)
        stopPortPolling()
    }

    func handleAppBackground() {
        shell.appDidEnterBackground()
        processes.setActive(false)
        stopPortPolling()
    }

    func handleAppForeground() {
        guard isPanelOpen else { return }
        if isTerminalExpanded {
            shell.appWillEnterForeground()
            processes.setActive(true)
        }
        startPortPolling()
        refresh()
    }

    /// Reloads the current directory (bootstrapping first if needed).
    func refresh() {
        guard didBootstrap else { Task { await bootstrap() }; return }
        Task { await reload() }
    }

    /// Discovers server features and the session cwd, then loads it. Runs once
    /// per server/chat configuration.
    func bootstrap() async {
        guard let apiClient, isConfigured, !requiresSavedChat, !didBootstrap else { return }
        didBootstrap = true
        isLoading = true
        let server = serverId, chat = chatId, token = currentLoadToken

        async let configTask = try? apiClient.getTerminalConfig(serverId: server)
        async let cwdTask = try? apiClient.terminalGetCwd(serverId: server, sessionId: chat)
        let (config, cwd) = await (configTask, cwdTask)
        guard token == currentLoadToken, server == serverId else { return }

        shellAvailable = config?.terminal ?? true
        homePath = cwd?.home.map(TerminalPath.directory)
        rootPath = cwd?.rootPath.map(TerminalPath.directory)
        rootLabel = cwd?.rootLabel
        let start = pendingOpenFile.map { TerminalPath.parent(of: $0.path) } ?? cwd?.cwd ?? cwd?.home ?? rootPath ?? "/"
        await load(path: clampToRoot(start), recordHistory: false, persistCwd: false)
    }

    // MARK: Navigation

    func navigate(to path: String) {
        let target = clampToRoot(path)
        guard target != currentPath || loadError != nil else { return }
        Task { await load(path: target, recordHistory: true) }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentPath != (rootPath ?? "/") }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        Task { await load(path: previous, recordHistory: false) }
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        Task { await load(path: next, recordHistory: false) }
    }

    func goUp() { navigate(to: TerminalPath.parent(of: currentPath)) }

    func goHome() { navigate(to: homePath ?? rootPath ?? "/") }

    /// Breadcrumb segments, starting at the browsing root (or `/`).
    var breadcrumbs: [(name: String, path: String)] {
        let root = rootPath ?? "/"
        var crumbs: [(name: String, path: String)] = [(root == "/" ? "/" : (rootLabel ?? TerminalPath.name(of: root)), root)]
        guard currentPath != root, TerminalPath.isInside(currentPath, root) else { return crumbs }
        let relative = root == "/" ? currentPath : String(currentPath.dropFirst(root.count))
        var accumulated = root == "/" ? "" : root
        for component in relative.split(separator: "/") {
            accumulated += "/\(component)"
            crumbs.append((String(component), accumulated))
        }
        return crumbs
    }

    func clampToRoot(_ path: String) -> String {
        let normalized = TerminalPath.directory(path)
        guard let rootPath else { return normalized }
        return TerminalPath.isInside(normalized, rootPath) ? normalized : rootPath
    }

    // MARK: Loading

    func reload() async {
        await load(path: currentPath, recordHistory: false, persistCwd: false, preserveTree: true)
    }

    func load(path: String, recordHistory: Bool, persistCwd: Bool = true, preserveTree: Bool = false) async {
        guard let apiClient, isConfigured else { return }
        let directory = TerminalPath.directory(path)
        let token = bumpLoadToken()
        let previous = currentPath
        isLoading = true
        do {
            let listing = try await apiClient.terminalListFiles(serverId: serverId, path: directory, sessionId: chatId)
            guard token == currentLoadToken else { return }
            if recordHistory, directory != previous {
                backStack.append(previous)
                if backStack.count > 50 { backStack.removeFirst() }
                forwardStack.removeAll()
            }
            if directory != previous {
                isSelecting = false
                if !preserveTree { expandedDirs = []; childCache = [:] }
            }
            currentPath = directory
            items = listing.items
            isWritable = listing.writable
            loadError = nil
            isLoading = false
            if preserveTree { await refreshExpanded() }
            if persistCwd {
                // Keep the server's session cwd in sync (fire-and-forget, like the web).
                let server = serverId, chat = chatId
                Task { try? await apiClient.terminalSetCwd(serverId: server, path: directory, sessionId: chat) }
            }
        } catch {
            guard token == currentLoadToken else { return }
            isLoading = false
            logger.error("List failed at \(directory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if directory == previous || items.isEmpty {
                currentPath = directory
                items = []
                loadError = describe(error)
            } else {
                // Keep the current listing; just report the failure.
                showBanner("Couldn't open \(TerminalPath.name(of: directory)): \(describe(error))", style: .error)
            }
        }
    }

    // MARK: Tree expansion

    func toggleExpanded(_ item: TerminalFileItem) {
        guard item.isDirectory else { return }
        if expandedDirs.contains(item.path) {
            expandedDirs.remove(item.path)
            return
        }
        expandedDirs.insert(item.path)
        Task { await fetchChildren(item.path) }
    }

    private func fetchChildren(_ path: String) async {
        guard let apiClient else { return }
        loadingDirs.insert(path)
        defer { loadingDirs.remove(path) }
        do {
            let listing = try await apiClient.terminalListFiles(serverId: serverId, path: path, sessionId: chatId)
            childCache[path] = listing.items
        } catch {
            expandedDirs.remove(path)
            showBanner("Couldn't load \(TerminalPath.name(of: path))", style: .error)
        }
    }

    private func refreshExpanded() async {
        for dir in expandedDirs.sorted() { await fetchChildren(dir) }
    }

    /// Flattened, sorted, filtered rows including expanded sub-trees.
    var rows: [Row] {
        var result: [Row] = []
        func append(_ list: [TerminalFileItem], depth: Int) {
            for item in sorted(filtered(list)) {
                result.append(Row(item: item, depth: depth))
                if item.isDirectory, expandedDirs.contains(item.path), let children = childCache[item.path], depth < 12 {
                    append(children, depth: depth + 1)
                }
            }
        }
        append(items, depth: 0)
        return result
    }

    /// Top-level visible items (used for select-all and empty states).
    var visibleItems: [TerminalFileItem] { sorted(filtered(items)) }

    /// Every item currently known (top level + expanded children).
    func item(at path: String) -> TerminalFileItem? {
        if let hit = items.first(where: { $0.path == path }) { return hit }
        for children in childCache.values { if let hit = children.first(where: { $0.path == path }) { return hit } }
        return nil
    }

    private func filtered(_ list: [TerminalFileItem]) -> [TerminalFileItem] {
        showHidden ? list : list.filter { !$0.isHidden }
    }

    private func sorted(_ list: [TerminalFileItem]) -> [TerminalFileItem] {
        let asc = sortAscending
        let mode = sortMode
        return list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let byName = a.name.localizedStandardCompare(b.name)
            switch mode {
            case .name:
                return asc ? byName == .orderedAscending : byName == .orderedDescending
            case .size:
                let sa = a.size ?? 0, sb = b.size ?? 0
                if sa == sb { return byName == .orderedAscending }
                return asc ? sa < sb : sa > sb
            case .date:
                let da = a.modified ?? .distantPast, db = b.modified ?? .distantPast
                if da == db { return byName == .orderedAscending }
                return asc ? da < db : da > db
            }
        }
    }

    func setSort(_ mode: SortMode) {
        if sortMode == mode { sortAscending.toggle() } else { sortMode = mode; sortAscending = mode == .name }
    }
}
