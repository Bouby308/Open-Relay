import Foundation

// MARK: - Terminal Upload, Search & Compare

extension APIClient {

    /// Uploads a local file (streamed from disk) into `directory` on the terminal.
    /// `fileName` may differ from the local name (e.g. de-duplicated).
    func terminalUploadFile(serverId: String, fileURL: URL, fileName: String, directory: String, sessionId: String?) async throws {
        let boundary = "OpenUI-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: bodyURL)
        let safeName = fileName.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n" +
            "Content-Type: \(mimeType(for: fileName))\r\n\r\n"
        try out.write(contentsOf: Data(header.utf8))
        let input = try FileHandle(forReadingFrom: fileURL)
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try input.close()
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()

        let request = try terminalRequest(serverId: serverId, path: "/files/upload",
                                          method: .post,
                                          queryItems: [URLQueryItem(name: "directory", value: directory)],
                                          contentType: "multipart/form-data; boundary=\(boundary)",
                                          sessionId: sessionId, timeout: 600)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.session.upload(for: request, fromFile: bodyURL)
        } catch {
            throw APIError.from(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Self.terminalError(status: http.statusCode, data: data)
        }
    }

    /// Saves text content to a file (same approach as the web editor — an upload
    /// that overwrites the file in its directory).
    func terminalSaveTextFile(serverId: String, path: String, content: String, sessionId: String?) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = TerminalPath.name(of: path)
        let temp = folder.appendingPathComponent(name)
        try Data(content.utf8).write(to: temp)
        try await terminalUploadFile(serverId: serverId, fileURL: temp, fileName: name,
                                     directory: TerminalPath.parent(of: path), sessionId: sessionId)
    }

    /// Searches file names **and** contents below `path` (`GET /files/matches`).
    func terminalFileMatches(serverId: String, query: String, path: String, showHidden: Bool,
                             offset: Int, sessionId: String?) async throws -> TerminalFileMatchPage {
        let request = try terminalRequest(serverId: serverId, path: "/files/matches", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "show_hidden", value: showHidden ? "true" : "false"),
            URLQueryItem(name: "offset", value: String(offset))
        ], sessionId: sessionId, timeout: 60)
        let json = try await terminalJSON(request) as? [String: Any] ?? [:]
        let results = (json["results"] as? [[String: Any]] ?? []).compactMap(TerminalFileMatch.init(from:))
        return TerminalFileMatchPage(results: results, nextOffset: (json["next_offset"] as? NSNumber)?.intValue)
    }

    func terminalCompareFiles(serverId: String, original: String, revised: String, ignoreWhitespace: Bool,
                              sessionId: String?) async throws -> TerminalComparison {
        let request = try terminalRequest(serverId: serverId, path: "/files/compare", method: .post, body: try terminalJSONBody([
            "original": original, "revised": revised, "ignore_whitespace": ignoreWhitespace
        ]), sessionId: sessionId, timeout: 60)
        do {
            let json = try await terminalJSON(request) as? [String: Any] ?? [:]
            return TerminalComparison(from: json)
        } catch APIError.httpError(let status, let message, _)
                    where status == 405 || (status == 404 && (message == nil || message == "Not Found" || message == "Not found on the terminal.")) {
            throw APIError.httpError(statusCode: status,
                                     message: "File comparison isn't available on this terminal. Update Open Terminal to use Compare.",
                                     data: nil)
        }
    }
}
