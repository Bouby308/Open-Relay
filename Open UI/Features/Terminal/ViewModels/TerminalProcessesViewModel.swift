import Foundation
import SwiftTerm

/// Tracks commands the model runs via `/execute` and streams their output
/// into read-only tabs next to the interactive shell (web `TerminalDock`).
@MainActor @Observable
final class TerminalProcessesViewModel {

    struct Tab: Identifiable, Equatable {
        let id: String
        var command: String
        var status: TerminalProcess.Status
        var exitCode: Int?
        /// False once the server no longer knows the process.
        var available: Bool
        var offset: Int = 0
        var loaded = false
        var finished = false

        var isRunning: Bool { available && status == .running }
        var statusText: String {
            if !available { return "Unavailable" }
            switch status {
            case .running: return "Running"
            case .killed: return "Stopped"
            case .done: return exitCode.map { "Exit \($0)" } ?? "Done"
            }
        }
    }

    /// `"shell"` or a process id.
    static let shellTab = "shell"

    private(set) var tabs: [Tab] = []
    var activeTab: String = TerminalProcessesViewModel.shellTab
    private(set) var error: String?

    var runningCount: Int { tabs.filter(\.isRunning).count }

    @ObservationIgnored private var apiClient: APIClient?
    @ObservationIgnored private var serverId = ""
    @ObservationIgnored private var chatId: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var dismissed = Set<String>()
    @ObservationIgnored private var polling = false
    /// Output buffered per process (replayed when its view attaches).
    @ObservationIgnored private var buffers: [String: [UInt8]] = [:]
    @ObservationIgnored private var views: [String: TerminalView] = [:]

    func configure(apiClient: APIClient, serverId: String, chatId: String?) {
        let changed = self.serverId != serverId || self.chatId != chatId
        self.apiClient = apiClient
        guard changed else { return }
        reset()
        self.serverId = serverId
        self.chatId = chatId
    }

    func reset() {
        pollTask?.cancel()
        pollTask = nil
        tabs = []
        activeTab = Self.shellTab
        error = nil
        dismissed = []
        buffers = [:]
        views = [:]
    }

    /// Polls once a second while the dock is visible.
    func setActive(_ active: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard active, apiClient != nil, !serverId.isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func refreshSoon() {
        Task { await poll() }
    }

    func select(_ id: String) {
        activeTab = id
        Task { await poll() }
    }

    func dismiss(_ id: String) {
        dismissed.insert(id)
        tabs.removeAll { $0.id == id }
        buffers[id] = nil
        views[id] = nil
        if activeTab == id { activeTab = Self.shellTab }
    }

    func attach(_ view: TerminalView, to id: String) {
        guard views[id] !== view else { return }
        views[id] = view
        if let pending = buffers[id], !pending.isEmpty {
            view.feed(byteArray: pending[...])
        }
    }

    private func poll() async {
        guard let apiClient, !polling else { return }
        polling = true
        defer { polling = false }
        do {
            let processes = try await apiClient.terminalListProcesses(serverId: serverId, sessionId: chatId)
            error = nil
            let live = Dictionary(processes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            tabs = tabs.map { tab in
                var tab = tab
                if let p = live[tab.id] {
                    tab.status = p.status
                    tab.exitCode = p.exitCode
                    tab.command = p.command
                    tab.available = true
                } else {
                    tab.available = false
                }
                return tab
            }
            let known = Set(tabs.map(\.id))
            for p in processes where !known.contains(p.id) && !dismissed.contains(p.id) {
                tabs.append(Tab(id: p.id, command: p.command, status: p.status, exitCode: p.exitCode, available: true))
            }
            await fetchOutput(for: activeTab)
        } catch {
            if !(error is CancellationError) { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func fetchOutput(for id: String) async {
        guard let apiClient, id != Self.shellTab,
              let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].available, !tabs[index].finished else { return }
        let tab = tabs[index]
        guard let result = try? await apiClient.terminalProcessOutput(serverId: serverId, processId: id,
                                                                      offset: tab.offset, sessionId: chatId),
              let current = tabs.firstIndex(where: { $0.id == id }) else { return }
        var chunk = ""
        if !tabs[current].loaded {
            chunk += "\u{1B}[2m$ " + tab.command.replacingOccurrences(of: "\n", with: "\r\n") + "\u{1B}[0m\r\n"
        }
        if result.truncated && !tabs[current].loaded { chunk += "\u{1B}[2m[Earlier output omitted]\u{1B}[0m\r\n" }
        chunk += result.output.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        tabs[current].loaded = true
        tabs[current].offset = result.nextOffset
        if let p = result.process {
            tabs[current].status = p.status
            tabs[current].exitCode = p.exitCode
            tabs[current].finished = p.status != .running
            if tabs[current].finished {
                let code = p.exitCode.map { "exit \($0)" } ?? p.status.rawValue
                chunk += "\r\n\u{1B}[2m[\(code)]\u{1B}[0m\r\n"
            }
        }
        guard !chunk.isEmpty else { return }
        let bytes = Array(chunk.utf8)
        if let view = views[id] {
            view.feed(byteArray: bytes[...])
        }
        buffers[id, default: []].append(contentsOf: bytes)
        if (buffers[id]?.count ?? 0) > 1_000_000 { buffers[id]?.removeFirst(200_000) }
    }
}
