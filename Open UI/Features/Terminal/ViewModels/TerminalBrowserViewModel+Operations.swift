import Foundation
import UIKit

// MARK: - File Operations

extension TerminalBrowserViewModel {

    /// Validates a single path component typed by the user.
    static func validateName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        return name
    }

    func createFolder(name raw: String) async {
        guard let apiClient, let name = Self.validateName(raw) else {
            if !raw.trimmingCharacters(in: .whitespaces).isEmpty { showBanner("That isn't a valid folder name.", style: .error) }
            return
        }
        do {
            try await apiClient.terminalMkdir(serverId: serverId, path: TerminalPath.join(currentPath, name), sessionId: chatId)
            Haptics.notify(.success)
            await reload()
        } catch {
            showBanner("Couldn't create folder: \(describe(error))", style: .error)
        }
    }

    /// Creates an empty file and returns it so the caller can open it in the editor.
    @discardableResult
    func createFile(name raw: String) async -> TerminalFileItem? {
        guard let apiClient, let name = Self.validateName(raw) else {
            if !raw.trimmingCharacters(in: .whitespaces).isEmpty { showBanner("That isn't a valid file name.", style: .error) }
            return nil
        }
        if items.contains(where: { $0.name == name }) {
            showBanner("\(name) already exists.", style: .error)
            return nil
        }
        let path = TerminalPath.join(currentPath, name)
        do {
            try await apiClient.terminalSaveTextFile(serverId: serverId, path: path, content: "", sessionId: chatId)
            Haptics.notify(.success)
            await reload()
            return item(at: path) ?? TerminalFileItem(name: name, path: path, isDirectory: false, size: 0)
        } catch {
            showBanner("Couldn't create file: \(describe(error))", style: .error)
            return nil
        }
    }

    func renameItem(_ item: TerminalFileItem, to raw: String) async {
        guard let apiClient, let name = Self.validateName(raw) else {
            if !raw.trimmingCharacters(in: .whitespaces).isEmpty { showBanner("That isn't a valid name.", style: .error) }
            return
        }
        guard name != item.name else { return }
        let destination = TerminalPath.join(TerminalPath.parent(of: item.path), name)
        do {
            try await apiClient.terminalMoveFile(serverId: serverId, sourcePath: item.path, destinationPath: destination, sessionId: chatId)
            Haptics.notify(.success)
            await reload()
        } catch {
            showBanner("Couldn't rename: \(describe(error))", style: .error)
        }
    }

    /// Moves entries into `folder`. Skips no-ops and moving a folder into itself.
    func move(_ paths: [String], to folder: String) async {
        guard let apiClient else { return }
        let destinationFolder = TerminalPath.directory(folder)
        var moved = 0
        var failures: [String] = []
        for source in paths {
            let name = TerminalPath.name(of: source)
            let destination = TerminalPath.join(destinationFolder, name)
            guard destination != TerminalPath.directory(source),
                  !TerminalPath.isInside(destinationFolder, source) else { continue }
            do {
                try await apiClient.terminalMoveFile(serverId: serverId, sourcePath: source, destinationPath: destination, sessionId: chatId)
                moved += 1
            } catch {
                failures.append("\(name): \(describe(error))")
            }
        }
        isSelecting = false
        if !failures.isEmpty {
            showBanner("Couldn't move \(failures.count) item\(failures.count == 1 ? "" : "s"). \(failures.first ?? "")", style: .error)
        } else if moved > 0 {
            Haptics.notify(.success)
            showBanner("Moved \(moved) item\(moved == 1 ? "" : "s") to \(TerminalPath.name(of: destinationFolder))", style: .success)
        }
        await reload()
    }

    func deleteItems(_ paths: [String]) async {
        guard let apiClient, !paths.isEmpty else { return }
        var removed = Set<String>()
        var failures = 0
        var lastError = ""
        for path in paths {
            do {
                try await apiClient.terminalDeleteFile(serverId: serverId, path: path, sessionId: chatId)
                removed.insert(path)
            } catch {
                failures += 1
                lastError = describe(error)
            }
        }
        items.removeAll { removed.contains($0.path) }
        for key in Array(childCache.keys) { childCache[key]?.removeAll { removed.contains($0.path) } }
        isSelecting = false
        if failures > 0 {
            showBanner("Couldn't delete \(failures) item\(failures == 1 ? "" : "s"): \(lastError)", style: .error)
            await reload()
        } else {
            Haptics.notify(.success)
        }
    }

    func deleteItem(_ item: TerminalFileItem) async { await deleteItems([item.path]) }

    // MARK: Upload

    /// Uploads local files into the current folder. Names that already exist
    /// get a " (1)" suffix, like the web client.
    func upload(_ urls: [URL], into directory: String? = nil) async {
        guard let apiClient, !urls.isEmpty else { return }
        let target = directory.map(TerminalPath.directory) ?? currentPath
        var existing = Set((target == currentPath ? items : (childCache[target] ?? items)).map(\.name))
        uploadProgress = (0, urls.count)
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = Self.uniqueName(url.lastPathComponent, existing: existing)
            existing.insert(name)
            do {
                try await apiClient.terminalUploadFile(serverId: serverId, fileURL: url, fileName: name,
                                                       directory: target, sessionId: chatId)
            } catch {
                failures.append("\(name): \(describe(error))")
            }
            uploadProgress = (index + 1, urls.count)
        }
        uploadProgress = nil
        if failures.isEmpty {
            Haptics.notify(.success)
            showBanner(urls.count == 1 ? "Uploaded \(urls[0].lastPathComponent)" : "Uploaded \(urls.count) files", style: .success)
        } else {
            showBanner("Upload failed — \(failures.first ?? "")", style: .error)
        }
        await reload()
    }

    /// Uploads a whole local folder, recreating its structure below the current folder.
    func uploadFolder(_ folderURL: URL) async {
        guard let apiClient else { return }
        let scoped = folderURL.startAccessingSecurityScopedResource()
        defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let rootName = Self.uniqueName(folderURL.lastPathComponent, existing: Set(items.map(\.name)))
        let remoteRoot = TerminalPath.join(currentPath, rootName)
        guard let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsPackageDescendants]) else { return }
        var directories: [String] = [remoteRoot]
        var files: [(URL, String)] = []
        let basePath = folderURL.standardizedFileURL.path
        for case let url as URL in enumerator.allObjects {
            let relative = String(url.standardizedFileURL.path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty, !relative.split(separator: "/").contains(where: { $0 == ".." }) else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let remote = remoteRoot + "/" + relative
            if isDir { directories.append(remote) } else { files.append((url, remote)) }
        }
        uploadProgress = (0, files.count)
        var failures = 0
        for dir in directories {
            do { try await apiClient.terminalMkdir(serverId: serverId, path: dir, sessionId: chatId) } catch { failures += 1 }
        }
        for (index, (url, remote)) in files.enumerated() {
            do {
                try await apiClient.terminalUploadFile(serverId: serverId, fileURL: url, fileName: TerminalPath.name(of: remote),
                                                       directory: TerminalPath.parent(of: remote), sessionId: chatId)
            } catch { failures += 1 }
            uploadProgress = (index + 1, files.count)
        }
        uploadProgress = nil
        if failures == 0 {
            Haptics.notify(.success)
            showBanner("Uploaded \(rootName) (\(files.count) file\(files.count == 1 ? "" : "s"))", style: .success)
        } else {
            showBanner("Uploaded \(rootName) with \(failures) error\(failures == 1 ? "" : "s")", style: .error)
        }
        await reload()
    }

    /// Uploads in-memory data (e.g. photos) via a temporary file.
    func upload(data: Data, fileName: String) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-pick-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(fileName)
        do { try data.write(to: url) } catch { showBanner("Couldn't read \(fileName)", style: .error); return }
        await upload([url])
    }

    static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ns = name as NSString
        let ext = name.hasPrefix(".") && ns.pathExtension == String(name.dropFirst()) ? "" : ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }
}
