import Foundation

// MARK: - Terminal Shell & Processes

extension APIClient {

    /// Lists commands started through `/execute` for this session.
    func terminalListProcesses(serverId: String, sessionId: String?) async throws -> [TerminalProcess] {
        let request = try terminalRequest(serverId: serverId, path: "/execute", sessionId: sessionId, timeout: 15)
        return (try await terminalJSON(request) as? [[String: Any]] ?? []).compactMap(TerminalProcess.init(from:))
    }

    struct TerminalProcessOutput: Sendable {
        let process: TerminalProcess?
        let output: String
        let nextOffset: Int
        let truncated: Bool
    }

    /// Reads a process' output from `offset` without blocking (`wait=0`).
    func terminalProcessOutput(serverId: String, processId: String, offset: Int,
                               sessionId: String?) async throws -> TerminalProcessOutput {
        let request = try terminalRequest(serverId: serverId, path: "/execute/\(Self.encodeTerminalSegment(processId))/status", queryItems: [
            URLQueryItem(name: "wait", value: "0"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "tail", value: "1000")
        ], sessionId: sessionId, timeout: 20)
        let json = try await terminalJSON(request) as? [String: Any] ?? [:]
        let output = (json["output"] as? [[String: Any]] ?? []).compactMap { $0["data"] as? String }.joined()
        return TerminalProcessOutput(process: TerminalProcess(from: json), output: output,
                                     nextOffset: (json["next_offset"] as? NSNumber)?.intValue ?? offset,
                                     truncated: json["truncated"] as? Bool ?? false)
    }

    /// Creates a new interactive PTY session. Returns the session ID used to
    /// open the WebSocket (`POST /api/terminals`).
    func terminalCreateSession(serverId: String, sessionId: String?) async throws -> String {
        let request = try terminalRequest(serverId: serverId, path: "/api/terminals", method: .post,
                                          body: Data("{}".utf8), sessionId: sessionId, timeout: 30)
        guard let json = try await terminalJSON(request) as? [String: Any], let id = json["id"] as? String else {
            throw APIError.responseDecoding(
                underlying: NSError(domain: "Terminal", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Missing session id in response"]),
                data: nil)
        }
        return id
    }

    /// Best-effort delete of a PTY session (used when a session is abandoned).
    func terminalDeleteSession(serverId: String, terminalId: String, sessionId: String?) async {
        guard let request = try? terminalRequest(serverId: serverId, path: "/api/terminals/\(Self.encodeTerminalSegment(terminalId))",
                                                 method: .delete, contentType: nil, sessionId: sessionId, timeout: 10) else { return }
        _ = try? await terminalSend(request)
    }

    /// WebSocket URL for an interactive PTY session.
    func terminalWebSocketURL(serverId: String, terminalId: String) -> URL? {
        var base = baseURL
        if base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("https://") { base = "wss://" + base.dropFirst("https://".count) }
        else if base.hasPrefix("http://") { base = "ws://" + base.dropFirst("http://".count) }
        return URL(string: base + terminalAPIPath(serverId, "/api/terminals/\(Self.encodeTerminalSegment(terminalId))"))
    }
}
