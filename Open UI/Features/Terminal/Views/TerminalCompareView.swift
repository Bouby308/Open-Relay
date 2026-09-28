import SwiftUI

/// Unified diff of two terminal files (`POST /files/compare`).
struct TerminalCompareView: View {
    let viewModel: TerminalBrowserViewModel
    let original: TerminalFileItem
    let revised: TerminalFileItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var comparison: TerminalComparison?
    @State private var error: String?
    @State private var ignoreWhitespace = false
    @State private var swapped = false

    private var left: TerminalFileItem { swapped ? revised : original }
    private var right: TerminalFileItem { swapped ? original : revised }

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView {
                        Label("Couldn't compare", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) }
                } else if let comparison {
                    diffList(comparison)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Ignore Whitespace", isOn: $ignoreWhitespace)
                        Button { swapped.toggle() } label: { Label("Swap Sides", systemImage: "arrow.left.arrow.right") }
                    } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
            .safeAreaInset(edge: .top) { summary }
        }
        .task(id: "\(ignoreWhitespace)\(swapped)") { await load() }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("−").foregroundStyle(.red).fontWeight(.bold)
                Text(left.name).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 6) {
                Text("+").foregroundStyle(.green).fontWeight(.bold)
                Text(right.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let comparison {
                    Text("+\(comparison.additions)").foregroundStyle(.green)
                    Text("−\(comparison.deletions)").foregroundStyle(.red)
                }
            }
        }
        .scaledFont(size: 12, design: .monospaced)
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private func diffList(_ comparison: TerminalComparison) -> some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(comparison.notices, id: \.self) { notice in
                    Label(notice, systemImage: "info.circle").scaledFont(size: 12).foregroundStyle(theme.textSecondary).padding(12)
                }
                if comparison.hunks.isEmpty {
                    Text("The files are identical.").scaledFont(size: 14).foregroundStyle(theme.textSecondary).padding(24)
                }
                ForEach(comparison.hunks) { hunk in
                    Text(hunk.header)
                        .scaledFont(size: 11, design: .monospaced)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.brandPrimary.opacity(0.08))
                    ForEach(hunk.lines) { line in lineView(line) }
                }
            }
        }
    }

    private func lineView(_ line: TerminalDiffLine) -> some View {
        let (marker, tint): (String, SwiftUI.Color) = switch line.kind {
        case .added: ("+", .green)
        case .removed: ("−", .red)
        case .context: (" ", .clear)
        }
        var attributed = AttributedString()
        for segment in line.segments {
            var part = AttributedString(segment.text)
            if segment.changed && line.kind != .context { part.backgroundColor = tint.opacity(0.3) }
            attributed += part
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
            Text(marker).foregroundStyle(tint == .clear ? theme.textTertiary : tint).fontWeight(.bold)
            Text(attributed).foregroundStyle(theme.textPrimary).fixedSize()
        }
        .scaledFont(size: 12, design: .monospaced)
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, 8).padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(line.kind == .context ? 0 : 0.1))
    }

    private func load() async {
        error = nil
        do {
            comparison = try await viewModel.compare(left.path, right.path, ignoreWhitespace: ignoreWhitespace)
        } catch {
            self.error = viewModel.describe(error)
        }
    }
}
