import SwiftUI
import UIKit

// MARK: - Loading & saving

extension TerminalFileViewer {
    /// Text files above this size open read-only as plain text for responsiveness.
    static let maxEditableBytes: Int64 = 2 * 1024 * 1024

    func load() async {
        loadError = nil
        loaded = nil
        do {
            switch kind {
            case .image:
                guard let file = await viewModel.download(self.file) else { throw URLError(.cannotOpenFile) }
                held = file
                if let image = UIImage(contentsOfFile: file.url.path) { loaded = .image(image) } else { loaded = .external(file.url) }
            case .pdf:
                guard let file = await viewModel.download(self.file) else { throw URLError(.cannotOpenFile) }
                held = file
                loaded = .pdf(try Data(contentsOf: file.url))
            case .video, .audio:
                guard let file = await viewModel.download(self.file) else { throw URLError(.cannotOpenFile) }
                held = file
                loaded = .media(file.url)
            case .office:
                if let pdf = await viewModel.previewPDF(self.file.path) {
                    loaded = .pdf(pdf)
                } else {
                    guard let file = await viewModel.download(self.file) else { throw URLError(.cannotOpenFile) }
                    held = file
                    loaded = .external(file.url)
                }
            case .archive, .sqlite, .directory:
                loaded = .binary
            case .binary, .code, .markdown, .json, .csv, .html, .svg, .text, .notebook:
                if let size = self.file.size, size > 20 * 1024 * 1024 {
                    loaded = .binary
                } else if let text = try await viewModel.readText(self.file.path) {
                    loaded = .text(text)
                    if !hasRichPreview { mode = .source }
                } else {
                    loaded = .binary
                }
            }
        } catch {
            loadError = viewModel.describe(error)
        }
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await viewModel.saveText(file.path, content: draft)
            loaded = .text(draft)
            isEditing = false
            Haptics.notify(.success)
            viewModel.showBanner("Saved \(file.name)", style: .success)
        } catch {
            Haptics.notify(.error)
            loadError = nil
            viewModel.showBanner("Couldn't save: \(viewModel.describe(error))", style: .error)
        }
    }

    func exportFile(share: Bool) async {
        if held == nil { held = await viewModel.download(file) }
        guard let held else { return }
        if share { shareURL = held.url } else { quickLookURL = held.url }
    }

    static func prettyJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    static func svgPage(_ svg: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;display:flex;align-items:center;justify-content:center;background:#fff}
        svg{max-width:100%;max-height:100%;height:auto}</style></head><body>\(svg)</body></html>
        """
    }
}
