import SwiftUI

// MARK: - Header (navigation, breadcrumbs, actions, search)

extension TerminalBrowserView {

    var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                headerButton("xmark", label: "Close", action: onDismiss)
                headerButton("chevron.left", label: "Back", enabled: viewModel.canGoBack) { viewModel.goBack() }
                headerButton("chevron.right", label: "Forward", enabled: viewModel.canGoForward) { viewModel.goForward() }
                breadcrumbBar
                if viewModel.isSelecting {
                    Button("Done") { withAnimation(.snappy) { viewModel.isSelecting = false } }
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 6)
                } else {
                    actionsMenu
                }
            }
            .padding(.horizontal, 6)
            .opacity(viewModel.requiresSavedChat ? 0.5 : 1)
            .disabled(viewModel.requiresSavedChat)

            if !viewModel.requiresSavedChat { searchField }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if let progress = viewModel.uploadProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .progressViewStyle(.linear).tint(theme.brandPrimary)
                } else if viewModel.isLoading && !viewModel.items.isEmpty {
                    ProgressView().progressViewStyle(.linear).tint(theme.brandPrimary.opacity(0.6))
                }
                Rectangle().fill(theme.cardBorder.opacity(0.35)).frame(height: 0.5)
            }
        }
    }

    private func headerButton(_ symbol: String, label: String, enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.play(.light)
        } label: {
            Image(systemName: symbol)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(enabled ? theme.textSecondary : theme.textTertiary.opacity(0.4))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var breadcrumbBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let crumbs: [Crumb] = viewModel.breadcrumbs.enumerated().map { Crumb(index: $0.offset, name: $0.element.name, path: $0.element.path) }
                    ForEach(crumbs) { crumb in
                        let index = crumb.index
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .scaledFont(size: 11, weight: .semibold)
                                .foregroundStyle(theme.textTertiary.opacity(0.7))
                        }
                        let isCurrent = crumb.path == viewModel.currentPath
                        Button {
                            viewModel.navigate(to: crumb.path)
                            Haptics.play(.light)
                        } label: {
                            Group {
                                if index == 0 && crumb.name == "/" {
                                    Image(systemName: "externaldrive").scaledFont(size: 12, weight: .medium)
                                } else if crumb.path == viewModel.homePath {
                                    Label(crumb.name, systemImage: "house").labelStyle(.titleAndIcon)
                                } else {
                                    Text(crumb.name)
                                }
                            }
                            .scaledFont(size: 13, weight: isCurrent ? .semibold : .regular)
                            .foregroundStyle(isCurrent ? theme.textPrimary : theme.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(isCurrent ? theme.surfaceContainerHighest.opacity(0.7) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(crumb.path)
                        .dropDestination(for: String.self) { paths, _ in
                            guard viewModel.isWritable else { return false }
                            Task { await viewModel.move(paths, to: crumb.path) }
                            return true
                        }
                        .accessibilityLabel(index == 0 ? "Root folder" : crumb.name)
                    }
                    if !viewModel.isWritable {
                        Text("Read-only")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(theme.surfaceContainerHighest, in: Capsule())
                            .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onAppear { proxy.scrollTo(viewModel.currentPath, anchor: .trailing) }
            .onChange(of: viewModel.currentPath) { _, path in
                withAnimation(.snappy) { proxy.scrollTo(path, anchor: .trailing) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var actionsMenu: some View {
        Menu {
            Section {
                Button { beginCreate(.file) } label: { Label("New File", systemImage: "doc.badge.plus") }
                Button { beginCreate(.folder) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            }
            .disabled(!viewModel.isWritable)
            Section {
                Button { showFilePicker = true } label: { Label("Upload Files", systemImage: "square.and.arrow.up") }
                Button { showPhotoPicker = true } label: { Label("Upload Photos", systemImage: "photo.on.rectangle") }
                Button { showFolderPicker = true } label: { Label("Upload Folder", systemImage: "folder.badge.gearshape") }
            }
            .disabled(!viewModel.isWritable)
            Section {
                Button { downloadCurrentFolder() } label: { Label("Download Folder (ZIP)", systemImage: "arrow.down.doc") }
                Button {
                    NotificationCenter.default.post(name: .terminalInsertPath, object: viewModel.currentPath)
                    Haptics.notify(.success)
                } label: { Label("Insert Path into Chat", systemImage: "text.insert") }
                Button {
                    UIPasteboard.general.string = viewModel.currentPath
                    viewModel.showBanner("Path copied", style: .success)
                } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            }
            Section {
                Menu {
                    ForEach(TerminalBrowserViewModel.SortMode.allCases) { mode in
                        Button { withAnimation(.snappy) { viewModel.setSort(mode) } } label: {
                            if viewModel.sortMode == mode {
                                Label(mode.title, systemImage: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: { Label("Sort By", systemImage: "arrow.up.arrow.down") }
                Toggle(isOn: Binding(get: { viewModel.showHidden },
                                     set: { value in withAnimation(.snappy) { viewModel.showHidden = value } })) {
                    Label("Show Hidden Files", systemImage: "eye")
                }
                Button { withAnimation(.snappy) { viewModel.isSelecting = true } } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .disabled(viewModel.visibleItems.isEmpty)
                Button { viewModel.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .scaledFont(size: 17, weight: .regular)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("File Actions")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
            TextField("Search files and contents", text: $viewModel.searchQuery)
                .scaledFont(size: 14)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if viewModel.isSearchLoading {
                ProgressView().controlSize(.small)
            } else if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill").scaledFont(size: 14).foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
    }

    struct Crumb: Identifiable {
        let index: Int
        let name: String
        let path: String
        var id: String { path }
    }

    func beginCreate(_ kind: CreateKind) {
        createText = ""
        creating = kind
        Haptics.play(.light)
    }

    func downloadCurrentFolder() {
        let folder = TerminalFileItem(name: TerminalPath.name(of: viewModel.currentPath) == "/" ? "root" : TerminalPath.name(of: viewModel.currentPath),
                                      path: viewModel.currentPath, isDirectory: true)
        share(folder)
    }
}
