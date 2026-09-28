import SwiftUI

// MARK: - Search results, ports, selection bar, banners, actions

extension TerminalBrowserView {

    // MARK: Search

    var searchResultsList: some View {
        List {
            if let error = viewModel.searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .scaledFont(size: 13).foregroundStyle(theme.error)
                    .listRowBackground(Color.clear)
            } else if !viewModel.isSearchLoading && viewModel.searchResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").scaledFont(size: 26, weight: .light).foregroundStyle(theme.textTertiary)
                    Text("No matches in \(TerminalPath.name(of: viewModel.currentPath))")
                        .scaledFont(size: 14, weight: .medium).foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            let names = viewModel.searchResults.filter(\.nameMatch)
            let contents = viewModel.searchResults.filter { !$0.nameMatch }
            if !names.isEmpty {
                Section {
                    ForEach(names) { match in matchRow(match) }
                } header: { sectionHeader("File Names", count: names.count) }
            }
            if !contents.isEmpty {
                Section {
                    ForEach(contents) { match in matchRow(match) }
                } header: { sectionHeader("Contents", count: contents.count) }
            }
            if viewModel.searchNextOffset != nil {
                HStack {
                    Spacer()
                    if viewModel.isLoadingMoreResults { ProgressView() } else {
                        Button("Load More") { Task { await viewModel.loadMoreSearchResults() } }
                            .scaledFont(size: 13, weight: .semibold).foregroundStyle(theme.brandPrimary)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .task { await viewModel.loadMoreSearchResults() }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).scaledFont(size: 12, weight: .semibold)
            Text("\(count)").scaledFont(size: 11).foregroundStyle(theme.textTertiary)
        }
        .foregroundStyle(theme.textSecondary)
    }

    private func matchRow(_ match: TerminalFileMatch) -> some View {
        let item = match.asFileItem
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: item.iconName)
                    .scaledFont(size: 15)
                    .foregroundStyle(terminalIconColor(for: item, theme: theme))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.name).scaledFont(size: 14, weight: .medium).foregroundStyle(theme.textPrimary).lineLimit(1)
                    Text(match.relativePath).scaledFont(size: 11).foregroundStyle(theme.textTertiary).lineLimit(1).truncationMode(.head)
                }
            }
            ForEach(match.contentMatches.prefix(3)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(line.line)").scaledFont(size: 10, design: .monospaced).foregroundStyle(theme.textTertiary)
                        .frame(minWidth: 26, alignment: .trailing)
                    highlighted(line.text.trimmingCharacters(in: .whitespaces))
                        .scaledFont(size: 12, design: .monospaced)
                        .lineLimit(1)
                }
                .padding(.leading, 30)
                .contentShape(Rectangle())
                .onTapGesture { openMatch(match, line: line.line) }
            }
            if match.contentMatches.count > 3 {
                Text("+\(match.contentMatches.count - 3) more").scaledFont(size: 11).foregroundStyle(theme.textTertiary).padding(.leading, 62)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { openMatch(match, line: match.contentMatches.first?.line) }
        .contextMenu { rowMenu(item) }
        .listRowBackground(Color.clear)
    }

    private func highlighted(_ text: String) -> Text {
        let query = viewModel.searchQuery.trimmingCharacters(in: .whitespaces)
        var attributed = AttributedString(text)
        attributed.foregroundColor = theme.textSecondary
        if !query.isEmpty, let range = attributed.range(of: query, options: .caseInsensitive) {
            attributed[range].foregroundColor = theme.textPrimary
            attributed[range].backgroundColor = theme.brandPrimary.opacity(0.22)
        }
        return Text(attributed)
    }

    private func openMatch(_ match: TerminalFileMatch, line: Int?) {
        if match.isDirectory {
            viewModel.searchQuery = ""
            viewModel.navigate(to: match.path)
        } else {
            openedLine = line
            open(match.asFileItem)
        }
    }

    // MARK: Ports

    var portsSection: some View {
        Section {
            ForEach(viewModel.ports) { port in
                HStack(spacing: 10) {
                    Image(systemName: "network").scaledFont(size: 14).foregroundStyle(.green).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("localhost:\(port.port)").scaledFont(size: 14, weight: .medium, design: .monospaced)
                            .foregroundStyle(theme.textPrimary)
                        if let process = port.process {
                            Text(port.pid.map { "\(process) · pid \($0)" } ?? process)
                                .scaledFont(size: 11).foregroundStyle(theme.textTertiary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button { previewPort = port } label: {
                        Image(systemName: "eye").scaledFont(size: 14).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.brandPrimary)
                    .accessibilityLabel("Preview port \(port.port)")
                    Button { if let url = viewModel.portURL(port.port) { UIApplication.shared.open(url) } } label: {
                        Image(systemName: "safari").scaledFont(size: 14).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.textSecondary)
                    .accessibilityLabel("Open port \(port.port) in Safari")
                }
                .contentShape(Rectangle())
                .onTapGesture { previewPort = port }
                .listRowBackground(Color.clear)
            }
        } header: {
            HStack {
                Text("Ports").scaledFont(size: 12, weight: .semibold)
                Text("\(viewModel.ports.count)").scaledFont(size: 11).foregroundStyle(theme.textTertiary)
            }
            .foregroundStyle(theme.textSecondary)
        }
    }

    // MARK: Selection bar

    var selectionBar: some View {
        let count = viewModel.selection.count
        let all = viewModel.visibleItems.map(\.path)
        let allSelected = !all.isEmpty && Set(all).isSubset(of: viewModel.selection)
        return HStack(spacing: 4) {
            Button(allSelected ? "Deselect All" : "Select All") {
                if allSelected { viewModel.selection.removeAll() } else { viewModel.selection.formUnion(all) }
                Haptics.selection()
            }
            .scaledFont(size: 13, weight: .medium)
            Spacer()
            Text(count == 0 ? "Select items" : "\(count) selected")
                .scaledFont(size: 13, weight: .semibold).foregroundStyle(theme.textSecondary)
            Spacer()
            barButton("arrow.down.circle", label: "Download", enabled: count > 0) {
                let paths = Array(viewModel.selection)
                Task {
                    if let file = await viewModel.downloadArchive(of: paths) { present(file, share: true) }
                }
            }
            barButton("folder", label: "Move", enabled: count > 0 && viewModel.isWritable) {
                moving = Array(viewModel.selection)
            }
            barButton("trash", label: "Delete", enabled: count > 0 && viewModel.isWritable, destructive: true) {
                confirmDelete = Array(viewModel.selection)
            }
        }
        .foregroundStyle(theme.brandPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.cardBorder.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func barButton(_ symbol: String, label: String, enabled: Bool, destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol).scaledFont(size: 16, weight: .medium)
                .foregroundStyle(enabled ? (destructive ? theme.error : theme.brandPrimary) : theme.textTertiary.opacity(0.5))
                .frame(width: 36, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Transfer pill & banner

    func transferPill(name: String) -> some View {
        let expected = viewModel.transferExpected
        let received = viewModel.transferReceived
        return HStack(spacing: 10) {
            if expected > 0 {
                ProgressView(value: Double(min(received, expected)), total: Double(expected))
                    .progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).scaledFont(size: 12, weight: .semibold).lineLimit(1).truncationMode(.middle)
                Text(received > 0 ? ByteCountFormatter.string(fromByteCount: received, countStyle: .file) +
                     (expected > 0 ? " of " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : "")
                     : "Preparing…")
                    .scaledFont(size: 11).foregroundStyle(theme.textTertiary).monospacedDigit()
            }
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .frame(maxWidth: 280)
    }

    @ViewBuilder
    var bannerView: some View {
        if let banner = viewModel.banner {
            HStack(spacing: 8) {
                Image(systemName: banner.style == .error ? "exclamationmark.circle.fill"
                      : banner.style == .success ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundStyle(banner.style == .error ? theme.error : banner.style == .success ? .green : theme.brandPrimary)
                Text(banner.message).scaledFont(size: 13, weight: .medium).foregroundStyle(theme.textPrimary)
                    .lineLimit(3).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { withAnimation { viewModel.banner = nil } }
            .id(banner.id)
            .accessibilityAddTraits(.isStaticText)
        }
    }

    // MARK: Actions

    /// Opens a file in the built-in viewer.
    func open(_ item: TerminalFileItem) {
        guard !item.isDirectory else { viewModel.navigate(to: item.path); return }
        searchFocused = false
        openedFile = item
        Haptics.play(.light)
    }

    func quickLook(_ item: TerminalFileItem) {
        Task {
            if let file = await viewModel.download(item) { present(file, share: false) }
        }
    }

    func share(_ item: TerminalFileItem) {
        Task {
            if let file = await viewModel.download(item) { present(file, share: true) }
        }
    }

    func present(_ file: DownloadedTerminalFile, share: Bool) {
        heldFile = file
        if share { shareURL = file.url } else { quickLookURL = file.url }
    }
}
