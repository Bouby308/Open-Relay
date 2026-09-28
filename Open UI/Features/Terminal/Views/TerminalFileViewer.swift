import SwiftUI
import PDFKit
import AVKit
import QuickLook

/// Built-in viewer / editor for terminal files.
struct TerminalFileViewer: View {
    let viewModel: TerminalBrowserViewModel
    let file: TerminalFileItem
    var initialLine: Int? = nil

    enum Loaded {
        case text(String)
        case image(UIImage)
        case pdf(Data)
        case media(URL)
        case external(URL)
        case binary
    }

    enum Mode: String, CaseIterable, Identifiable {
        case preview = "Preview", source = "Source"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) var dismiss
    @Environment(\.theme) var theme
    @State var loaded: Loaded?
    @State var loadError: String?
    @State var held: DownloadedTerminalFile?
    @State var mode: Mode = .preview
    @State var wrap = true
    @State var isEditing = false
    @State var draft = ""
    @State var isSaving = false
    @State var confirmDiscard = false
    @State var shareURL: URL?
    @State var quickLookURL: URL?
    @State var webLoading = false

    var kind: TerminalFileKind { file.kind }
    var hasRichPreview: Bool { [.markdown, .json, .csv, .html, .svg].contains(kind) }
    private var originalText: String? { if case .text(let t) = loaded { return t }; return nil }
    private var isDirty: Bool { isEditing && draft != (originalText ?? "") }
    private var canEdit: Bool { file.writable && viewModel.isWritable && originalText != nil }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.background)
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .safeAreaInset(edge: .top) {
                    if hasRichPreview && originalText != nil && !isEditing {
                        Picker("Mode", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(.bar)
                    }
                }
        }
        .interactiveDismissDisabled(isDirty)
        .task { await load() }
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { isEditing = false; draft = originalText ?? "" }
            Button("Keep Editing", role: .cancel) {}
        }
        .sheet(item: $shareURL) { url in ShareSheetView(activityItems: [url]) }
        .quickLookPreview($quickLookURL)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if isEditing {
                Button("Cancel", systemImage: "xmark") { if isDirty { confirmDiscard = true } else { isEditing = false } }
                    .labelStyle(.iconOnly).tint(.secondary)
            } else {
                Button("Done", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).tint(.secondary)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if isEditing {
                if isSaving { ProgressView() } else {
                    Button("Save", systemImage: "checkmark") { Task { await save() } }
                        .labelStyle(.iconOnly).disabled(!isDirty)
                }
            } else {
                if canEdit {
                    Button { draft = originalText ?? ""; isEditing = true; mode = .source } label: { Image(systemName: "pencil") }
                        .accessibilityLabel("Edit")
                }
                Menu {
                    if originalText != nil {
                        Toggle(isOn: $wrap) { Label("Wrap Lines", systemImage: "text.word.spacing") }
                        Button { UIPasteboard.general.string = originalText; Haptics.notify(.success) } label: {
                            Label("Copy Contents", systemImage: "doc.on.doc")
                        }
                    }
                    Button { UIPasteboard.general.string = file.path; Haptics.notify(.success) } label: {
                        Label("Copy Path", systemImage: "link")
                    }
                    Button {
                        NotificationCenter.default.post(name: .terminalInsertPath, object: file.path)
                        Haptics.notify(.success)
                        dismiss()
                    } label: { Label("Insert Path into Chat", systemImage: "text.insert") }
                    Divider()
                    Button { Task { await exportFile(share: true) } } label: { Label("Share / Save", systemImage: "square.and.arrow.up") }
                    Button { Task { await exportFile(share: false) } } label: { Label("Open in Quick Look", systemImage: "eye") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView {
                Label("Couldn't open file", systemImage: "exclamationmark.triangle")
            } description: { Text(loadError) } actions: {
                Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
            }
        } else if let loaded {
            switch loaded {
            case .text(let text):
                if isEditing {
                    TerminalCodeEditor(text: $draft, wrap: wrap)
                } else if mode == .preview && hasRichPreview {
                    richPreview(text)
                } else {
                    TerminalCodeView(text: text, wrap: wrap, highlightLine: initialLine)
                }
            case .image(let image):
                TerminalZoomableImage(image: image)
            case .pdf(let data):
                TerminalPDFView(data: data)
            case .media(let url):
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea(edges: .bottom)
            case .external(let url):
                externalFallback(url)
            case .binary:
                externalFallback(nil)
            }
        } else {
            VStack(spacing: 12) {
                if viewModel.transferName != nil, viewModel.transferExpected > 0 {
                    ProgressView(value: Double(viewModel.transferReceived), total: Double(viewModel.transferExpected))
                        .frame(width: 180)
                    Text("\(ByteCountFormatter.string(fromByteCount: viewModel.transferReceived, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: viewModel.transferExpected, countStyle: .file))")
                        .scaledFont(size: 12).foregroundStyle(theme.textTertiary).monospacedDigit()
                } else {
                    ProgressView()
                    Text("Loading…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func richPreview(_ text: String) -> some View {
        switch kind {
        case .markdown:
            ScrollView {
                StreamingMarkdownView(content: text, isStreaming: false)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .json:
            TerminalCodeView(text: Self.prettyJSON(text) ?? text, wrap: wrap, highlightLine: nil)
        case .csv:
            TerminalCSVTable(text: text, delimiter: file.fileExtension == "tsv" ? "\t" : ",")
        case .html, .svg:
            ZStack {
                Color.white
                TerminalWebView(content: .html(kind == .svg ? Self.svgPage(text) : text, baseURL: nil), isLoading: $webLoading)
            }
        default:
            TerminalCodeView(text: text, wrap: wrap, highlightLine: nil)
        }
    }

    private func externalFallback(_ url: URL?) -> some View {
        ContentUnavailableView {
            Label(file.name, systemImage: file.iconName)
        } description: {
            Text([file.formattedSize, "This file can't be previewed here."].compactMap { $0 }.joined(separator: " · "))
        } actions: {
            Button { Task { await exportFile(share: false) } } label: { Label("Quick Look", systemImage: "eye") }
                .buttonStyle(.borderedProminent).tint(theme.brandPrimary)
            Button { Task { await exportFile(share: true) } } label: { Label("Share / Save", systemImage: "square.and.arrow.up") }
                .buttonStyle(.bordered)
        }
    }
}
