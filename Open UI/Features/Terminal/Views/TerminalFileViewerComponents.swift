import SwiftUI
import UIKit
import PDFKit

/// Read-only monospaced text with line numbers, optional wrapping, and an
/// optional highlighted line (used when opening a content-search match).
/// Backed by UITextView so large files scroll smoothly.
struct TerminalCodeView: UIViewRepresentable {
    let text: String
    let wrap: Bool
    let highlightLine: Int?
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 12)
        view.dataDetectorTypes = []
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let key = "\(text.hashValue)|\(wrap)|\(highlightLine ?? -1)|\(colorScheme)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        view.textContainer.widthTracksTextView = wrap
        view.textContainer.size = wrap ? CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)
                                       : CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer.lineBreakMode = wrap ? .byCharWrapping : .byClipping
        view.attributedText = Self.render(text, highlight: highlightLine)
        if let line = highlightLine, line > 1 {
            DispatchQueue.main.async {
                let lines = text.components(separatedBy: "\n")
                let gutter = String(lines.count).count + 2
                let offset = lines.prefix(line - 1).reduce(0) { $0 + ($1 as NSString).length + gutter + 1 }
                let range = NSRange(location: min(offset, (view.attributedText.length)), length: 0)
                view.scrollRangeToVisible(range)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var key = "" }

    static func render(_ text: String, highlight: Int?) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let gutterFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let lines = text.components(separatedBy: "\n")
        let width = String(lines.count).count
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        // Limit the rendered size for giant files (still scrollable, but fast).
        let limit = min(lines.count, 20_000)
        for index in 0..<limit {
            let number = String(index + 1)
            let padded = String(repeating: " ", count: width - number.count) + number + "  "
            result.append(NSAttributedString(string: padded, attributes: [
                .font: gutterFont, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: paragraph
            ]))
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
            if highlight == index + 1 { attrs[.backgroundColor] = UIColor.systemYellow.withAlphaComponent(0.3) }
            result.append(NSAttributedString(string: lines[index] + (index < limit - 1 ? "\n" : ""), attributes: attrs))
        }
        if limit < lines.count {
            result.append(NSAttributedString(string: "\n\n… \(lines.count - limit) more lines. Share the file to see all of it.",
                                             attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
        }
        return result
    }
}

/// Plain-text code editor (no autocorrect / smart quotes).
struct TerminalCodeEditor: UIViewRepresentable {
    @Binding var text: String
    let wrap: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardType = .asciiCapable
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 40, right: 10)
        view.delegate = context.coordinator
        view.text = text
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        view.textContainer.widthTracksTextView = wrap
        if !wrap { view.textContainer.size = CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude) }
        view.textContainer.lineBreakMode = wrap ? .byCharWrapping : .byClipping
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ textView: UITextView) { text.wrappedValue = textView.text }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText string: String) -> Bool {
            // Insert a real tab-width indent and keep the previous line's indentation on return.
            if string == "\n" {
                let ns = textView.text as NSString
                let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
                let line = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                guard !indent.isEmpty, let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                      let end = textView.position(from: start, offset: range.length),
                      let textRange = textView.textRange(from: start, to: end) else { return true }
                textView.replace(textRange, withText: "\n" + indent)
                return false
            }
            return true
        }
    }
}

/// Scrollable CSV/TSV table with a sticky header row.
struct TerminalCSVTable: View {
    let text: String
    let delimiter: Character
    @Environment(\.theme) private var theme

    var body: some View {
        let rows = Self.parse(text, delimiter: delimiter)
        let columns = rows.map(\.count).max() ?? 0
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(rows.dropFirst().prefix(5000).enumerated()), id: \.offset) { index, row in
                        rowView(row, columns: columns, header: false)
                            .background(index.isMultiple(of: 2) ? Color.clear : theme.surfaceContainer.opacity(0.5))
                    }
                } header: {
                    if let first = rows.first { rowView(first, columns: columns, header: true).background(theme.surfaceContainerHighest) }
                }
            }
            .padding(8)
        }
    }

    private func rowView(_ row: [String], columns: Int, header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<columns, id: \.self) { column in
                Text(column < row.count ? row[column] : "")
                    .scaledFont(size: 12, weight: header ? .semibold : .regular, design: .monospaced)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .frame(width: 140, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .overlay(alignment: .trailing) { Rectangle().fill(theme.cardBorder.opacity(0.3)).frame(width: 0.5) }
            }
        }
    }

    /// RFC-4180-ish parser: quoted fields, escaped quotes, newlines in quotes.
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        while let c = iterator.next() {
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            if next == delimiter { row.append(field); field = "" }
                            else if next == "\n" || next == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
                            else if next != "\r" { field.append(next) }
                        }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" {
                row.append(field); rows.append(row); row = []; field = ""
            } else if c != "\r" {
                field.append(c)
            }
            if rows.count > 5001 { break }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

/// Pinch/double-tap zoomable image.
struct TerminalZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.delegate = context.coordinator
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ view: UIScrollView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true) } else {
                let point = recognizer.location(in: imageView)
                scroll.zoom(to: CGRect(x: point.x - 60, y: point.y - 60, width: 120, height: 120), animated: true)
            }
        }
    }
}

struct TerminalPDFView: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(data: data)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}
