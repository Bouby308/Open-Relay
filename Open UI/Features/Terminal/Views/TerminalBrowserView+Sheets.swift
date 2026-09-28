import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

// MARK: - Sheets, alerts and pickers

extension TerminalBrowserView {
    private var vm: TerminalBrowserViewModel { viewModel }

    func applySheets<Content: View>(_ content: Content) -> some View {
        content
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result, !urls.isEmpty { Task { await vm.upload(urls) } }
            }
            .background {
                // A second importer must live on a different view.
                Color.clear.fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result { Task { await vm.uploadFolder(url) } }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 20,
                          matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { await uploadPhotos(items) }
            }
            .alert(creating == .folder ? "New Folder" : "New File",
                   isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })) {
                TextField(creating == .folder ? "Folder name" : "File name", text: $createText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) { creating = nil }
                Button("Create") {
                    let kind = creating, name = createText
                    creating = nil
                    Task {
                        if kind == .folder { await vm.createFolder(name: name) }
                        else if let file = await vm.createFile(name: name) { openedFile = file }
                    }
                }
            } message: {
                Text("In \(TerminalPath.name(of: vm.currentPath))")
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("New name", text: $renameText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    guard let item = renaming else { return }
                    let name = renameText
                    renaming = nil
                    Task { await vm.renameItem(item, to: name) }
                }
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { !confirmDelete.isEmpty },
                                                                   set: { if !$0 { confirmDelete = [] } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let paths = confirmDelete
                    confirmDelete = []
                    Task { await vm.deleteItems(paths) }
                }
            } message: { Text("This can't be undone.") }
            .sheet(isPresented: Binding(get: { !moving.isEmpty }, set: { if !$0 { moving = [] } })) {
                TerminalFolderPickerView(viewModel: vm, sources: moving) { destination in
                    let sources = moving
                    moving = []
                    Task { await vm.move(sources, to: destination) }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $openedFile, onDismiss: { openedLine = nil }) { file in
                TerminalFileViewer(viewModel: vm, file: file, initialLine: openedLine)
            }
            .sheet(item: $comparePair) { pair in
                TerminalCompareView(viewModel: vm, original: pair.original, revised: pair.revised)
            }
            .sheet(item: $previewPort) { port in
                TerminalPortPreviewView(viewModel: vm, port: port)
            }
            .quickLookPreview($quickLookURL)
            .onChange(of: quickLookURL) { _, url in if url == nil && shareURL == nil { heldFile = nil } }
            .sheet(item: $shareURL, onDismiss: { heldFile = nil }) { url in
                ShareSheetView(activityItems: [url])
            }
    }

    private var deleteTitle: String {
        let paths = confirmDelete
        return paths.count == 1 ? "Delete \(TerminalPath.name(of: paths[0]))?" : "Delete \(paths.count) items?"
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-photos-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var urls: [URL] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent("IMG_\(stamp)_\(index + 1).\(ext)")
            if (try? data.write(to: url)) != nil { urls.append(url) }
        }
        if urls.isEmpty { vm.showBanner("Couldn't read the selected photos.", style: .error); return }
        await vm.upload(urls)
    }
}
