import Foundation

/// Open Terminal endpoints, proxied through `/api/v1/terminals/{server_id}/…`.
///
/// Every call accepts an optional `sessionId` (the chat ID). It is forwarded as
/// `X-Session-Id` — exactly like the web FileNav — so the backend resolves the
/// chat's working directory and, for chat-scoped terminals, the chat's own
/// isolated workspace. Without it chat-scoped servers answer 409.
extension APIClient {

    // MARK: - Request Helpers

    static func encodeTerminalSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? value
    }

    func terminalAPIPath(_ serverId: String, _ path: String) -> String {
        "/api/v1/terminals/\(Self.encodeTerminalSegment(serverId))\(path)"
    }

    /// Builds an authenticated terminal request with the session header applied.
    func terminalRequest(
        serverId: String,
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        contentType: String? = "application/json",
        sessionId: String?,
        timeout: TimeInterval = 60
    ) throws -> URLRequest {
        var request = try network.buildRequest(
            path: terminalAPIPath(serverId, path),
            method: method,
            queryItems: queryItems,
            body: body,
            contentType: contentType,
            authenticated: true,
            timeout: timeout
        )
        if let sessionId, !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "X-Session-Id")
        }
        return request
    }

    /// Performs a terminal request and validates the status, surfacing the
    /// server's `detail` / `error` message when present.
    @discardableResult
    func terminalSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.session.data(for: request)
        } catch {
            throw APIError.from(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknown(underlying: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.terminalError(status: http.statusCode, data: data)
        }
        return (data, http)
    }

    static func terminalError(status: Int, data: Data) -> APIError {
        var message: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? String { message = detail }
            else if let error = json["error"] as? String { message = error }
            else if let detail = json["detail"] as? [[String: Any]], let first = detail.first?["msg"] as? String { message = first }
        }
        if message == nil {
            switch status {
            case 401, 403: message = "You don't have access to this terminal."
            case 404: message = "Not found on the terminal."
            case 409: message = "This terminal needs a saved chat. Send a message first."
            case 502, 503: message = "The terminal server is unreachable."
            default: break
            }
        }
        return .httpError(statusCode: status, message: message, data: data)
    }

    func terminalJSON(_ request: URLRequest) async throws -> Any {
        let (data, _) = try await terminalSend(request)
        if data.isEmpty { return [String: Any]() }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    func terminalJSONBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Server Info

    func getTerminalConfig(serverId: String) async throws -> TerminalConfig {
        let request = try terminalRequest(serverId: serverId, path: "/api/config", sessionId: nil, timeout: 15)
        let json = try await terminalJSON(request) as? [String: Any] ?? [:]
        return TerminalConfig(from: json)
    }

    func terminalGetCwd(serverId: String, sessionId: String?) async throws -> TerminalCwd {
        let request = try terminalRequest(serverId: serverId, path: "/files/cwd", sessionId: sessionId, timeout: 15)
        return TerminalCwd(from: try await terminalJSON(request) as? [String: Any] ?? [:])
    }

    func terminalSetCwd(serverId: String, path: String, sessionId: String?) async throws {
        let request = try terminalRequest(serverId: serverId, path: "/files/cwd", method: .post,
                                          body: try terminalJSONBody(["path": path]), sessionId: sessionId, timeout: 15)
        try await terminalSend(request)
    }

    // MARK: - Ports

    func terminalListeningPorts(serverId: String, sessionId: String?) async throws -> [TerminalListeningPort] {
        let request = try terminalRequest(serverId: serverId, path: "/ports", sessionId: sessionId, timeout: 15)
        let json = try await terminalJSON(request) as? [String: Any] ?? [:]
        return (json["ports"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let port = (entry["port"] as? NSNumber)?.intValue else { return nil }
            return TerminalListeningPort(port: port, pid: (entry["pid"] as? NSNumber)?.intValue,
                                         process: entry["process"] as? String)
        }
    }

    /// Absolute URL of the terminal's port proxy (`…/proxy/{port}/{path}`).
    func terminalPortProxyURL(serverId: String, port: Int, path: String = "") -> URL? {
        var base = baseURL
        if base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + terminalAPIPath(serverId, "/proxy/\(port)/\(path)"))
    }
}
