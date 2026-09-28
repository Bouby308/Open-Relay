import SwiftUI

/// Lets the user pick a destination folder for "Move To…".
struct TerminalFolderPickerView: View {
    let viewModel: TerminalBrowserViewModel
    let sources: [String]
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var path: String = "/"
    @State private var folders: [TerminalFileItem] = []
    @State private var writable = true
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if path != (viewModel.rootPath ?? "/") {
                    Button { load(TerminalPath.parent(of: path)) } label: {
                        Label("Up to \(TerminalPath.name(of: TerminalPath.parent(of: path)))", systemImage: "arrow.turn.left.up")
                    }
                }
                if let error {
                    Text(error).scaledFont(size: 13).foregroundStyle(theme.error)
                } else if !loading && folders.isEmpty {
                    Text("No subfolders").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                }
                ForEach(folders) { folder in
                    let blocked = sources.contains { TerminalPath.isInside(folder.path, $0) }
                    Button { load(folder.path) } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(theme.brandPrimary)
                            Text(folder.name).foregroundStyle(blocked ? theme.textTertiary : theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").scaledFont(size: 11, weight: .semibold).foregroundStyle(theme.textTertiary)
                        }
                    }
                    .disabled(blocked)
                }
            }
            .overlay { if loading && folders.isEmpty { ProgressView() } }
            .navigationTitle(TerminalPath.name(of: path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move Here") { onPick(path); dismiss() }
                        .disabled(!writable || sources.allSatisfy { TerminalPath.parent(of: $0) == path }
                                  || sources.contains { TerminalPath.isInside(path, $0) })
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(sources.count == 1 ? "Moving \(TerminalPath.name(of: sources[0]))" : "Moving \(sources.count) items")
                    .scaledFont(size: 12).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(10).background(.bar)
            }
        }
        .task { load(viewModel.currentPath) }
    }

    private func load(_ target: String) {
        guard let apiClient = viewModel.apiClient else { return }
        let destination = viewModel.clampToRoot(target)
        loading = true
        error = nil
        Task {
            do {
                let listing = try await apiClient.terminalListFiles(serverId: viewModel.serverId, path: destination, sessionId: viewModel.chatId)
                path = destination
                writable = listing.writable
                folders = listing.items.filter { $0.isDirectory && (viewModel.showHidden || !$0.isHidden) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } catch {
                self.error = viewModel.describe(error)
            }
            loading = false
        }
    }
}
