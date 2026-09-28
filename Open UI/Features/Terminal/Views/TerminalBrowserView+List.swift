import SwiftUI

// MARK: - File list, search results, ports

extension TerminalBrowserView {

    @ViewBuilder
    var browserBody: some View {
        ZStack(alignment: .bottom) {
            Group {
                if viewModel.isSearchActive {
                    searchResultsList
                } else if viewModel.isLoading && viewModel.items.isEmpty && viewModel.loadError == nil {
                    loadingState
                } else if let error = viewModel.loadError {
                    stateView(icon: "exclamationmark.triangle", tint: theme.error, title: "Couldn't open folder",
                              message: error, actionTitle: "Retry") { viewModel.refresh() }
                } else {
                    fileList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.isSelecting && !viewModel.isSearchActive {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let name = viewModel.transferName {
                transferPill(name: name)
                    .padding(.bottom, viewModel.isSelecting ? 64 : 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: viewModel.isSelecting)
        .animation(.snappy(duration: 0.25), value: viewModel.transferName)
    }

    // MARK: List

    private var fileList: some View {
        List {
            let rows = viewModel.rows
            if rows.isEmpty {
                emptyFolderRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(rows) { row in
                fileRow(row)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    .listRowBackground(rowBackground(row.item))
                    .listRowSeparatorTint(theme.cardBorder.opacity(0.25))
            }
            if !viewModel.ports.isEmpty && !viewModel.isSelecting {
                portsSection
            }
            Color.clear.frame(height: viewModel.isSelecting ? 56 : 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await viewModel.reload() }
        .animation(.snappy(duration: 0.22), value: viewModel.rows)
    }

    private func rowBackground(_ item: TerminalFileItem) -> some View {
        (viewModel.isSelecting && viewModel.selection.contains(item.path)) ? theme.brandPrimary.opacity(0.1) : Color.clear
    }

    private func fileRow(_ row: TerminalBrowserViewModel.Row) -> some View {
        let item = row.item
        let base = TerminalFileRow(
            item: item,
            depth: row.depth,
            isExpanded: viewModel.expandedDirs.contains(item.path),
            isLoadingChildren: viewModel.loadingDirs.contains(item.path),
            isSelecting: viewModel.isSelecting,
            isSelected: viewModel.selection.contains(item.path),
            onToggleExpand: {
                withAnimation(.snappy(duration: 0.22)) { viewModel.toggleExpanded(item) }
                Haptics.selection()
            }
        )
        .onTapGesture { tap(item) }
        return withSwipeActions(withDragAndDrop(base, item: item), item: item)
            .contextMenu { rowContextMenu(item) } preview: { rowPreview(item) }
    }

    private func withDragAndDrop<V: View>(_ view: V, item: TerminalFileItem) -> some View {
        view
            .draggable(item.path) {
                Label(item.name, systemImage: item.iconName)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .dropDestination(for: String.self) { paths, _ in
                dropMove(paths, onto: item)
            }
    }

    private func dropMove(_ paths: [String], onto item: TerminalFileItem) -> Bool {
        guard item.isDirectory, item.writable, viewModel.isWritable else { return false }
        let sources = paths.filter { $0 != item.path }
        guard !sources.isEmpty else { return false }
        Task { await viewModel.move(sources, to: item.path) }
        return true
    }

    private func withSwipeActions<V: View>(_ view: V, item: TerminalFileItem) -> some View {
        view
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { trailingSwipe(item) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipe(item) }
    }

    @ViewBuilder
    private func trailingSwipe(_ item: TerminalFileItem) -> some View {
        if !viewModel.isSelecting {
            if item.writable && viewModel.isWritable {
                Button(role: .destructive) { confirmDelete = [item.path] } label: { Label("Delete", systemImage: "trash") }
            }
            Button { share(item) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .tint(theme.brandPrimary)
        }
    }

    @ViewBuilder
    private func leadingSwipe(_ item: TerminalFileItem) -> some View {
        if !viewModel.isSelecting {
            Button {
                NotificationCenter.default.post(name: .terminalInsertPath, object: item.path)
                Haptics.notify(.success)
            } label: { Label("Insert", systemImage: "text.insert") }
            .tint(.indigo)
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ item: TerminalFileItem) -> some View {
        if !viewModel.isSelecting { rowMenu(item) }
    }

    private func rowPreview(_ item: TerminalFileItem) -> some View {
        TerminalFileRow(item: item, depth: 0, isExpanded: false, isLoadingChildren: false,
                        isSelecting: false, isSelected: false, onToggleExpand: {})
            .padding(12).frame(width: 280).background(theme.background)
    }

    private func tap(_ item: TerminalFileItem) {
        if viewModel.isSelecting {
            if viewModel.selection.contains(item.path) { viewModel.selection.remove(item.path) } else { viewModel.selection.insert(item.path) }
            Haptics.selection()
        } else if item.isDirectory {
            viewModel.navigate(to: item.path)
            Haptics.play(.light)
        } else {
            open(item)
        }
    }

    @ViewBuilder
    func rowMenu(_ item: TerminalFileItem) -> some View {
        let canMutate = item.writable && viewModel.isWritable
        Section {
            if item.isDirectory {
                Button { viewModel.navigate(to: item.path) } label: { Label("Open", systemImage: "folder") }
            } else {
                Button { open(item) } label: { Label("Open", systemImage: "doc.text.magnifyingglass") }
                Button { quickLook(item) } label: { Label("Quick Look", systemImage: "eye") }
            }
            Button { share(item) } label: {
                Label(item.isDirectory ? "Download as ZIP" : "Share / Save", systemImage: "square.and.arrow.up")
            }
        }
        Section {
            Button {
                NotificationCenter.default.post(name: .terminalInsertPath, object: item.path)
                Haptics.notify(.success)
            } label: { Label("Insert Path into Chat", systemImage: "text.insert") }
            Button {
                UIPasteboard.general.string = item.path
                viewModel.showBanner("Path copied", style: .success)
            } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            if !item.isDirectory {
                if let source = compareSource, source.path != item.path {
                    Button { comparePair = ComparePair(original: source, revised: item); compareSource = nil } label: {
                        Label("Compare with \(source.name)", systemImage: "arrow.left.arrow.right")
                    }
                }
                Button { compareSource = item; viewModel.showBanner("Long-press another file to compare with \(item.name)") } label: {
                    Label("Select for Compare", systemImage: "arrow.left.arrow.right.square")
                }
            }
        }
        if canMutate {
            Section {
                Button { renameText = item.name; renaming = item } label: { Label("Rename", systemImage: "pencil") }
                Button { moving = [item.path] } label: { Label("Move To…", systemImage: "folder.badge.questionmark") }
                Button(role: .destructive) { confirmDelete = [item.path] } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private var emptyFolderRow: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder").scaledFont(size: 30, weight: .light).foregroundStyle(theme.textTertiary)
            Text(viewModel.items.isEmpty ? "This folder is empty" : "Only hidden files here")
                .scaledFont(size: 14, weight: .medium).foregroundStyle(theme.textSecondary)
            HStack(spacing: 10) {
                if !viewModel.items.isEmpty && !viewModel.showHidden {
                    Button("Show Hidden") { withAnimation { viewModel.showHidden = true } }
                }
                if viewModel.isWritable {
                    Button("New File") { beginCreate(.file) }
                    Button("Upload") { showFilePicker = true }
                }
            }
            .buttonStyle(.bordered)
            .tint(theme.brandPrimary)
            .scaledFont(size: 13, weight: .medium)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
        }
    }

    func stateView(icon: String, tint: SwiftUI.Color, title: String, message: String,
                   actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).scaledFont(size: 28).foregroundStyle(tint)
            Text(title).scaledFont(size: 15, weight: .semibold).foregroundStyle(theme.textPrimary)
            Text(message).scaledFont(size: 13).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered).tint(theme.brandPrimary)
                    .scaledFont(size: 13, weight: .semibold)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
