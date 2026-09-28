import Foundation

// MARK: - Terminal File Operations

extension APIClient {

    func terminalListFiles(serverId: String, path: String, sessionId: String?) async throws -> TerminalDirectoryListing {
        let request = try terminalRequest(serverId: serverId, path: "/files/list",
                                          queryItems: [URLQueryItem(name: "directory", value: path)],
                                          sessionId: sessionId, timeout: 30)
        let json = try await terminalJSON(request)
        if let object = json as? [String: Any], let entries = object["entries"] as? [[String: Any]] {
            let dir = object["dir"] as? String ?? path
            return TerminalDirectoryListing(
                items: entries.map { TerminalFileItem(from: $0, basePath: dir) },
                writable: object["writable"] as? Bool ?? true
            )
        }
        if let array = json as? [[String: Any]] {
            return TerminalDirectoryListing(items: array.map { TerminalFileItem(from: $0, basePath: path) }, writable: true)
        }
        return TerminalDirectoryListing(items: [], writable: true)
    }

    /// Reads a text file. Returns `nil` when the server reports a binary file.
    func terminalReadFile(serverId: String, path: String, sessionId: String?) async throws -> String? {
        let request = try terminalRequest(serverId: serverId, path: "/files/read",
                                          queryItems: [URLQueryItem(name: "path", value: path)],
                                          sessionId: sessionId, timeout: 60)
        let (data, response) = try await terminalSend(request)
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.hasPrefix("image/") || contentType.hasPrefix("application/octet") { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json["content"] as? String
        }
        return String(data: data, encoding: .utf8)
    }

    func terminalMkdir(serverId: String, path: String, sessionId: String?) async throws {
        let request = try terminalRequest(serverId: serverId, path: "/files/mkdir", method: .post,
                                          body: try terminalJSONBody(["path": path]), sessionId: sessionId)
        try await terminalSend(request)
    }

    func terminalDeleteFile(serverId: String, path: String, sessionId: String?) async throws {
        let request = try terminalRequest(serverId: serverId, path: "/files/delete", method: .delete,
                                          queryItems: [URLQueryItem(name: "path", value: path)],
                                          contentType: nil, sessionId: sessionId)
        try await terminalSend(request)
    }

    /// Moves or renames an entry. Sends both the current (`source`/`destination`)
    /// and legacy (`src_path`/`dst_path`) field names so every Open Terminal
    /// version accepts it.
    func terminalMoveFile(serverId: String, sourcePath: String, destinationPath: String, sessionId: String?) async throws {
        let body: [String: Any] = [
            "source": sourcePath, "destination": destinationPath,
            "src_path": sourcePath, "dst_path": destinationPath
        ]
        let request = try terminalRequest(serverId: serverId, path: "/files/move", method: .post,
                                          body: try terminalJSONBody(body), sessionId: sessionId)
        try await terminalSend(request)
    }

    /// Request for `/files/view` — used with the streamed downloader so large
    /// files go straight to disk with progress instead of sitting in memory.
    func terminalViewRequest(serverId: String, path: String, preview: Bool = false, sessionId: String?) throws -> URLRequest {
        var items = [URLQueryItem(name: "path", value: path)]
        if preview { items.append(URLQueryItem(name: "preview", value: "true")) }
        var request = try terminalRequest(serverId: serverId, path: "/files/view", queryItems: items,
                                          contentType: nil, sessionId: sessionId, timeout: 300)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    /// Request for `POST /files/archive` — returns a ZIP of the given paths.
    func terminalArchiveRequest(serverId: String, paths: [String], sessionId: String?) throws -> URLRequest {
        var request = try terminalRequest(serverId: serverId, path: "/files/archive", method: .post,
                                          body: try terminalJSONBody(["paths": paths]), sessionId: sessionId, timeout: 300)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    /// Server-rendered PDF preview of an Office document, or `nil` when the
    /// server can't convert it.
    func terminalPreviewPDF(serverId: String, path: String, sessionId: String?) async throws -> Data? {
        let request = try terminalViewRequest(serverId: serverId, path: path, preview: true, sessionId: sessionId)
        let (data, response) = try await terminalSend(request)
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        return type.contains("application/pdf") ? data : nil
    }
}
