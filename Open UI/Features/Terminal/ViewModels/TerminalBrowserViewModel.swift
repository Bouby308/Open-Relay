import Foundation
import UIKit
import os.log

/// State for the terminal side panel: file browser, search, selection,
/// ports and the embedded shell/process dock.
///
/// Mirrors the web `FileNav` behaviour:
/// - Starts in the chat's working directory (`GET /files/cwd`) and persists
///   every navigation back to the server (`POST /files/cwd`).
/// - Every request carries the chat id (`X-Session-Id`) so chat-scoped
///   terminals show the same workspace the model is using.
/// - Refreshes itself when the model writes files or runs commands.
@MainActor @Observable
final class TerminalBrowserViewModel {

    enum SortMode: String, CaseIterable, Identifiable {
        case name, size, date
        var id: String { rawValue }
        var title: String {
            switch self { case .name: "Name"; case .size: "Size"; case .date: "Date Modified" }
        }
    }

    /// A row in the (possibly tree-expanded) listing.
    struct Row: Identifiable, Hashable {
        let item: TerminalFileItem
        let depth: Int
        var id: String { item.path }
    }

    /// Short-lived message shown as a banner at the top of the panel.
    struct Banner: Equatable, Identifiable {
        enum Style { case success, error, info }
        let id = UUID()
        let message: String
        let style: Style
    }

    // MARK: - Browser State

    var currentPath: String = "/"
    var items: [TerminalFileItem] = []
    var isWritable = true
    var isLoading = false
    /// Set when the directory itself failed to load (full-screen error).
    var loadError: String?
    var banner: Banner?

    /// Optional root the server restricts browsing to.
    var rootPath: String?
    var rootLabel: String?
    var homePath: String?

    // History
    var backStack: [String] = []
    var forwardStack: [String] = []

    // Tree expansion
    var expandedDirs: Set<String> = []
    var childCache: [String: [TerminalFileItem]] = [:]
    var loadingDirs: Set<String> = []

    // Sorting & filtering (persisted like the web's localStorage flags)
    var sortMode: SortMode = SortMode(rawValue: UserDefaults.standard.string(forKey: "terminal.sortMode") ?? "") ?? .name {
        didSet { UserDefaults.standard.set(sortMode.rawValue, forKey: "terminal.sortMode") }
    }
    var sortAscending: Bool = UserDefaults.standard.object(forKey: "terminal.sortAscending") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sortAscending, forKey: "terminal.sortAscending") }
    }
    var showHidden: Bool = UserDefaults.standard.bool(forKey: "terminal.showHidden") {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "terminal.showHidden")
            if isSearchActive { searchQueryChanged() }
        }
    }

    // Selection
    var isSelecting = false {
        didSet { if !isSelecting { selection.removeAll() } }
    }
    var selection: Set<String> = []

    // Search
    var searchQuery = ""
    var searchResults: [TerminalFileMatch] = []
    var isSearchLoading = false
    var isLoadingMoreResults = false
    var searchError: String?
    var searchNextOffset: Int?
    var isSearchActive: Bool { !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // Transfers
    var uploadProgress: (done: Int, total: Int)?
    var transferName: String?
    var transferReceived: Int64 = 0
    var transferExpected: Int64 = -1

    // Ports
    var ports: [TerminalListeningPort] = []
    var isLoadingPorts = false

    // Server capabilities
    var shellAvailable = true
    /// True when the terminal is chat-scoped and this chat hasn't been saved yet.
    var requiresSavedChat = false
    var isConfigured = false
    var serverName = ""

    /// A file the panel should open in the viewer (set by display_file events).
    var pendingOpenFile: TerminalFileItem?

    // Shell + background processes (shared with the dock)
    let shell = TerminalShellViewModel()
    let processes = TerminalProcessesViewModel()

    /// Whether the shell/process dock is expanded below the file list.
    var isTerminalExpanded = false {
        didSet {
            guard isTerminalExpanded != oldValue else { return }
            processes.setActive(isTerminalExpanded && isPanelOpen)
        }
    }

    // MARK: - Private

    @ObservationIgnored var apiClient: APIClient?
    @ObservationIgnored var serverId = ""
    @ObservationIgnored var chatId: String?
    @ObservationIgnored var didBootstrap = false
    @ObservationIgnored var currentLoadToken = 0
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var portsTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored var isPanelOpen = false
    @ObservationIgnored let logger = Logger(subsystem: "com.openui", category: "TerminalBrowser")

    // MARK: - Setup

    /// Points the panel at a terminal server for a chat. Re-configuring with
    /// the same server + chat is a no-op, so this is safe to call often.
    func configure(apiClient: APIClient, server: TerminalServer, chatId: String?) {
        let savedChatId = Self.savedChatId(chatId)
        let changed = serverId != server.id || self.chatId != savedChatId || !isConfigured
        self.apiClient = apiClient
        serverName = server.displayName
        requiresSavedChat = server.isChatScoped && savedChatId == nil
        guard changed else { return }
        serverId = server.id
        self.chatId = savedChatId
        isConfigured = true
        didBootstrap = false
        resetBrowsingState()
        shell.configure(apiClient: apiClient, serverId: server.id, chatId: savedChatId)
        processes.configure(apiClient: apiClient, serverId: server.id, chatId: savedChatId)
        if isPanelOpen {
            Task { await bootstrap() }
            startPortPolling()
            if isTerminalExpanded {
                // The chat got its real id (or the server changed) while the
                // dock was open — reconnect the shell to the right workspace.
                if shellAvailable && !requiresSavedChat { shell.start() }
                processes.setActive(true)
            }
        }
    }

    /// Full teardown when leaving the chat.
    func reset() {
        shell.reset()
        processes.reset()
        stopPortPolling()
        searchTask?.cancel()
        apiClient = nil
        serverId = ""
        chatId = nil
        isConfigured = false
        didBootstrap = false
        requiresSavedChat = false
        isPanelOpen = false
        isTerminalExpanded = false
        resetBrowsingState()
    }

    private func resetBrowsingState() {
        currentLoadToken += 1
        currentPath = "/"
        items = []
        isWritable = true
        isLoading = false
        loadError = nil
        banner = nil
        rootPath = nil
        rootLabel = nil
        homePath = nil
        backStack = []
        forwardStack = []
        expandedDirs = []
        childCache = [:]
        loadingDirs = []
        isSelecting = false
        searchQuery = ""
        searchResults = []
        searchError = nil
        searchNextOffset = nil
        ports = []
        uploadProgress = nil
        transferName = nil
        shellAvailable = true
        pendingOpenFile = nil
    }

    /// Mirrors the web `isSavedChatId`: temporary/local/channel ids aren't sent.
    static func savedChatId(_ id: String?) -> String? {
        guard let id, !id.isEmpty, !id.hasPrefix("local:"), !id.hasPrefix("temporary:"), !id.hasPrefix("channel:") else { return nil }
        return id
    }

    // MARK: - Banner

    func showBanner(_ message: String, style: Banner.Style = .info) {
        bannerTask?.cancel()
        let banner = Banner(message: message, style: style)
        self.banner = banner
        if style == .error { Haptics.notify(.error) }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: style == .error ? 4_500_000_000 : 2_500_000_000)
            guard let self, !Task.isCancelled, self.banner?.id == banner.id else { return }
            self.banner = nil
        }
    }

    func describe(_ error: Error) -> String {
        if let api = error as? APIError, case .httpError(_, let message?, _) = api { return message }
        return error.localizedDescription
    }

    func bumpLoadToken() -> Int {
        currentLoadToken += 1
        return currentLoadToken
    }
}
