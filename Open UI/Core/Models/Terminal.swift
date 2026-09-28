import Foundation

// MARK: - Terminal Server

/// Represents a terminal server available to the user.
///
/// Open Terminal is a separate service (typically a Docker container) that
/// provides shell access, file management, and command execution to AI models.
struct TerminalServer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// True when the admin scoped this terminal per chat (`contexts.chat.context_id == "chat_id"`).
    /// Such terminals need a saved chat before files or a shell can be used.
    var isChatScoped: Bool = false
    /// True when the admin disabled this terminal inside chats (`contexts.chat == false`).
    var isHiddenInChats: Bool = false

    /// Display name — falls back to ID if name is empty.
    var displayName: String {
        name.isEmpty ? id : name
    }
}

// MARK: - Terminal Config

/// Response from `GET /api/v1/terminals/{server_id}/api/config`.
struct TerminalConfig: Sendable {
    let terminal: Bool
    let notebooks: Bool

    init(from json: [String: Any]) {
        let features = json["features"] as? [String: Any] ?? [:]
        // Mirrors the web client: the interactive shell is on unless explicitly disabled.
        terminal = features["terminal"] as? Bool ?? true
        notebooks = features["notebooks"] as? Bool ?? false
    }
}

// MARK: - Paths

/// Path helpers mirroring the web FileNav normalisation rules.
enum TerminalPath {
    /// Normalises backslashes and collapses duplicate separators.
    static func normalize(_ path: String) -> String {
        var result = path.replacingOccurrences(of: "\\", with: "/")
        while result.contains("//") { result = result.replacingOccurrences(of: "//", with: "/") }
        return result.isEmpty ? "/" : result
    }

    /// Directory form without a trailing slash (except root).
    static func directory(_ path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" { return "/" }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    static func join(_ parent: String, _ child: String) -> String {
        let cleanChild = child.split(separator: "/").last.map(String.init) ?? child
        let base = directory(parent)
        return base == "/" ? "/\(cleanChild)" : "\(base)/\(cleanChild)"
    }

    static func parent(of path: String) -> String {
        let dir = directory(path)
        guard dir != "/" else { return "/" }
        let parent = (dir as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func name(of path: String) -> String {
        let dir = directory(path)
        return dir == "/" ? "/" : (dir as NSString).lastPathComponent
    }

    /// True when `path` equals `ancestor` or sits somewhere below it.
    static func isInside(_ path: String, _ ancestor: String) -> Bool {
        let p = directory(path), a = directory(ancestor)
        return a == "/" || p == a || p.hasPrefix(a + "/")
    }
}

// MARK: - Terminal Cwd

/// Response from `GET /files/cwd` — the session working directory.
struct TerminalCwd: Sendable {
    let cwd: String?
    let home: String?
    /// Optional browsing root the server restricts the file browser to.
    let rootPath: String?
    let rootLabel: String?

    init(from json: [String: Any]) {
        cwd = json["cwd"] as? String
        home = json["home"] as? String
        let root = json["root"] as? [String: Any]
        rootPath = root?["path"] as? String
        rootLabel = root?["label"] as? String
    }
}

// MARK: - Directory Listing

struct TerminalDirectoryListing: Sendable {
    let items: [TerminalFileItem]
    /// False when the server reports the directory is read-only.
    let writable: Bool
}

// MARK: - Terminal File Kind

/// Coarse file classification used for icons and choosing a previewer.
enum TerminalFileKind: Sendable {
    case directory, code, markdown, json, csv, html, svg, image, video, audio, pdf, office, archive, notebook, sqlite, text, binary

    static let codeExtensions: Set<String> = [
        "py", "js", "ts", "jsx", "tsx", "mjs", "cjs", "swift", "dart", "java", "kt", "kts", "cpp", "cc", "cxx", "c", "h", "hpp",
        "m", "mm", "rb", "go", "rs", "php", "cs", "scala", "lua", "r", "pl", "sh", "bash", "zsh", "fish", "ps1", "sql",
        "css", "scss", "sass", "less", "vue", "svelte", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "gradle",
        "env", "gitignore", "graphql", "proto", "tf", "zig", "ex", "exs", "erl", "hs", "clj", "elm", "nim", "bat", "cmake"
    ]
    static let textExtensions: Set<String> = ["txt", "log", "text", "rst", "lock", "properties", "gitattributes", "editorconfig", "out"]

    static func of(name: String, isDirectory: Bool) -> TerminalFileKind {
        if isDirectory { return .directory }
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ext.isEmpty {
            if ["dockerfile", "makefile", "gemfile", "procfile", "rakefile", "vagrantfile"].contains(lower) { return .code }
            return lower.hasPrefix(".") ? .code : .text
        }
        switch ext {
        case "md", "markdown", "mdx": return .markdown
        case "json", "jsonl", "geojson", "webmanifest": return .json
        case "csv", "tsv": return .csv
        case "html", "htm": return .html
        case "svg": return .svg
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "ico", "tiff", "tif": return .image
        case "mp4", "mov", "m4v", "webm", "mkv", "avi": return .video
        case "mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "aiff": return .audio
        case "pdf": return .pdf
        case "docx", "doc", "xlsx", "xls", "pptx", "ppt", "odt", "ods", "odp", "rtf", "pages", "numbers", "key": return .office
        case "zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz", "zst": return .archive
        case "ipynb": return .notebook
        case "sqlite", "sqlite3", "db": return .sqlite
        default:
            if codeExtensions.contains(ext) { return .code }
            if textExtensions.contains(ext) { return .text }
            return .binary
        }
    }

    /// Whether the content can be shown and edited as plain text.
    var isTextual: Bool {
        switch self {
        case .code, .markdown, .json, .csv, .html, .svg, .text, .notebook: return true
        default: return false
        }
    }
}

// MARK: - Terminal File Item

/// Represents a file or directory in the terminal's filesystem.
struct TerminalFileItem: Identifiable, Sendable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let permissions: String?
    /// False when the server marks this entry read-only.
    let writable: Bool

    var id: String { path }

    /// File extension (lowercased) for icon resolution.
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isHidden: Bool { name.hasPrefix(".") }
    var kind: TerminalFileKind { TerminalFileKind.of(name: name, isDirectory: isDirectory) }

    /// Human-readable file size.
    var formattedSize: String? {
        guard let size, !isDirectory else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// SF Symbol name for this file type.
    var iconName: String {
        switch kind {
        case .directory: return "folder.fill"
        case .markdown: return "text.alignleft"
        case .json: return "curlybraces"
        case .csv: return "tablecells"
        case .html: return "globe"
        case .svg, .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .office: return "doc.text"
        case .archive: return "archivebox"
        case .notebook: return "book.closed"
        case .sqlite: return "cylinder.split.1x2"
        case .text: return "doc.plaintext"
        case .binary: return "doc"
        case .code:
            switch fileExtension {
            case "sh", "bash", "zsh", "fish", "ps1", "bat": return "terminal"
            case "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "gitignore", "editorconfig": return "gearshape"
            case "css", "scss", "sass", "less": return "paintbrush"
            case "sql": return "cylinder"
            default: return name.lowercased() == "dockerfile" ? "shippingbox" : "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    /// Parses a file item from the terminal server's JSON response.
    init(from json: [String: Any], basePath: String) {
        let rawName = json["name"] as? String ?? ""
        // Some servers return nested names ("dir/file"); keep only the last component.
        let cleaned = TerminalPath.normalize(rawName).split(separator: "/").last.map(String.init) ?? rawName
        name = cleaned
        let typeStr = json["type"] as? String
        isDirectory = json["is_dir"] as? Bool ?? json["isDir"] as? Bool ?? (typeStr == "directory")
        size = (json["size"] as? NSNumber)?.int64Value
        permissions = json["permissions"] as? String
        writable = json["writable"] as? Bool ?? true
        path = TerminalPath.join(basePath, cleaned)

        if let ts = (json["modified"] as? NSNumber)?.doubleValue {
            modified = Date(timeIntervalSince1970: ts)
        } else if let dateStr = json["modified"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            modified = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
        } else {
            modified = nil
        }
    }

    /// Manual initializer for previews/testing and synthetic entries.
    init(name: String, path: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil,
         permissions: String? = nil, writable: Bool = true) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.writable = writable
    }
}

// MARK: - Search

/// A line inside a file that matched the content search.
struct TerminalContentMatch: Identifiable, Sendable, Hashable {
    let line: Int
    let column: Int
    let text: String
    var id: String { "\(line):\(column)" }
}

/// One result from `GET /files/matches` — a file whose name and/or contents matched.
struct TerminalFileMatch: Identifiable, Sendable, Hashable {
    let path: String
    let relativePath: String
    let name: String
    let isDirectory: Bool
    let nameMatch: Bool
    let contentMatches: [TerminalContentMatch]
    var id: String { path }

    init?(from json: [String: Any]) {
        guard let path = json["path"] as? String else { return nil }
        self.path = path
        relativePath = json["relative_path"] as? String ?? path
        name = json["name"] as? String ?? (path as NSString).lastPathComponent
        isDirectory = (json["type"] as? String) == "directory"
        nameMatch = json["name_match"] as? Bool ?? false
        contentMatches = (json["content_matches"] as? [[String: Any]] ?? []).compactMap { m in
            guard let line = (m["line"] as? NSNumber)?.intValue else { return nil }
            return TerminalContentMatch(line: line, column: (m["column"] as? NSNumber)?.intValue ?? 0,
                                        text: m["text"] as? String ?? "")
        }
    }

    var asFileItem: TerminalFileItem {
        TerminalFileItem(name: name, path: path, isDirectory: isDirectory)
    }
}

struct TerminalFileMatchPage: Sendable {
    let results: [TerminalFileMatch]
    let nextOffset: Int?
}

// MARK: - Ports

/// A TCP port a process is listening on inside the terminal (`GET /ports`).
struct TerminalListeningPort: Identifiable, Sendable, Hashable {
    let port: Int
    let pid: Int?
    let process: String?
    var id: Int { port }
}

// MARK: - Background Processes

/// A command started through `/execute` (usually by the model).
struct TerminalProcess: Identifiable, Sendable, Hashable {
    enum Status: String, Sendable { case running, done, killed }
    let id: String
    let command: String
    let status: Status
    let exitCode: Int?

    init?(from json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        command = json["command"] as? String ?? ""
        status = Status(rawValue: json["status"] as? String ?? "") ?? .done
        exitCode = (json["exit_code"] as? NSNumber)?.intValue
    }
}

// MARK: - Compare

struct TerminalDiffSegment: Sendable, Hashable {
    let text: String
    let changed: Bool
}

struct TerminalDiffLine: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable { case added, removed, context }
    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let content: String
    let segments: [TerminalDiffSegment]
}

struct TerminalDiffHunk: Identifiable, Sendable, Hashable {
    let id: Int
    let header: String
    let lines: [TerminalDiffLine]
}

/// Response from `POST /files/compare`.
struct TerminalComparison: Sendable {
    let originalName: String
    let revisedName: String
    let notices: [String]
    let additions: Int
    let deletions: Int
    let hunks: [TerminalDiffHunk]

    init(from json: [String: Any]) {
        let original = json["original"] as? [String: Any] ?? [:]
        let revised = json["revised"] as? [String: Any] ?? [:]
        originalName = original["name"] as? String ?? ""
        revisedName = revised["name"] as? String ?? ""
        notices = (original["notices"] as? [String] ?? []) + (revised["notices"] as? [String] ?? [])
        additions = (json["additions"] as? NSNumber)?.intValue ?? 0
        deletions = (json["deletions"] as? NSNumber)?.intValue ?? 0
        var lineId = 0
        var parsed: [TerminalDiffHunk] = []
        for (index, hunk) in (json["hunks"] as? [[String: Any]] ?? []).enumerated() {
            var lines: [TerminalDiffLine] = []
            for line in hunk["lines"] as? [[String: Any]] ?? [] {
                lineId += 1
                let content = line["content"] as? String ?? ""
                let segments = (line["segments"] as? [[String: Any]] ?? []).map {
                    TerminalDiffSegment(text: $0["text"] as? String ?? "", changed: $0["changed"] as? Bool ?? false)
                }
                lines.append(TerminalDiffLine(
                    id: lineId,
                    kind: TerminalDiffLine.Kind(rawValue: line["type"] as? String ?? "") ?? .context,
                    oldNumber: (line["oldNumber"] as? NSNumber)?.intValue,
                    newNumber: (line["newNumber"] as? NSNumber)?.intValue,
                    content: content,
                    segments: segments.isEmpty ? [TerminalDiffSegment(text: content, changed: false)] : segments
                ))
            }
            parsed.append(TerminalDiffHunk(id: index, header: hunk["header"] as? String ?? "", lines: lines))
        }
        hunks = parsed
    }
}

// MARK: - Terminal Command Result

/// Result of executing a command on the terminal server.
struct TerminalCommandResult: Sendable {
    let id: String
    let command: String
    let output: String
    let exitCode: Int?
    let isRunning: Bool
    /// The next offset to pass for incremental output polling.
    let nextOffset: Int

    init(from json: [String: Any]) {
        id = json["id"] as? String ?? UUID().uuidString
        command = json["command"] as? String ?? ""
        exitCode = json["exit_code"] as? Int ?? json["exitCode"] as? Int
        isRunning = json["status"] as? String == "running"
            || json["is_running"] as? Bool == true
        nextOffset = json["next_offset"] as? Int ?? 0

        // The Open Terminal API returns `output` as an array of
        // {type: "stdout"|"stderr"|"output", data: "..."} objects.
        // Join all `data` fields into a single string for display.
        if let outputArray = json["output"] as? [[String: Any]] {
            output = outputArray.compactMap { $0["data"] as? String }.joined()
        } else if let outputStr = json["output"] as? String {
            // Fallback for any server that returns a plain string
            output = outputStr
        } else {
            output = ""
        }
    }
}
