import SwiftUI

/// Colour for a file's icon, grouped by type.
func terminalIconColor(for item: TerminalFileItem, theme: AppTheme) -> SwiftUI.Color {
    switch item.kind {
    case .directory: return theme.brandPrimary
    case .code:
        switch item.fileExtension {
        case "sh", "bash", "zsh", "fish", "ps1", "bat": return .green
        case "yaml", "yml", "toml", "ini", "cfg", "conf", "env": return .gray
        case "py": return SwiftUI.Color(red: 0.25, green: 0.47, blue: 0.85)
        case "js", "mjs", "cjs", "jsx": return SwiftUI.Color(red: 0.85, green: 0.7, blue: 0.1)
        case "ts", "tsx": return SwiftUI.Color(red: 0.19, green: 0.47, blue: 0.78)
        case "swift", "rs", "java", "kt": return .orange
        case "go": return .cyan
        case "rb": return .red
        default: return .orange
        }
    case .markdown, .text: return theme.textSecondary
    case .json: return .purple
    case .csv: return .green
    case .html: return .orange
    case .svg, .image: return .teal
    case .video: return .pink
    case .audio: return .indigo
    case .pdf: return .red
    case .office: return .blue
    case .archive: return .brown
    case .notebook: return .orange
    case .sqlite: return .mint
    case .binary: return theme.textTertiary
    }
}

/// "3m ago" style relative time (matches the web FileNav).
func terminalRelativeTime(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    switch seconds {
    case ..<60: return "just now"
    case ..<3600: return "\(seconds / 60)m ago"
    case ..<86400: return "\(seconds / 3600)h ago"
    case ..<2_592_000: return "\(seconds / 86400)d ago"
    case ..<31_536_000: return "\(seconds / 2_592_000)mo ago"
    default: return "\(seconds / 31_536_000)y ago"
    }
}

/// One row in the terminal file list.
struct TerminalFileRow: View {
    let item: TerminalFileItem
    let depth: Int
    let isExpanded: Bool
    let isLoadingChildren: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleExpand: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .scaledFont(size: 18)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Disclosure for in-place folder expansion.
            ZStack {
                if item.isDirectory {
                    if isLoadingChildren {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button(action: onToggleExpand) {
                            Image(systemName: "chevron.right")
                                .scaledFont(size: 10, weight: .bold)
                                .foregroundStyle(theme.textTertiary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .frame(width: 22, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isExpanded ? "Collapse \(item.name)" : "Expand \(item.name)")
                    }
                }
            }
            .frame(width: 16)

            Image(systemName: item.iconName)
                .scaledFont(size: 16, weight: .regular)
                .foregroundStyle(terminalIconColor(for: item, theme: theme))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .scaledFont(size: 14, weight: item.isDirectory ? .medium : .regular)
                        .foregroundStyle(item.isHidden ? theme.textSecondary : theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !item.writable {
                        Image(systemName: "lock.fill")
                            .scaledFont(size: 9)
                            .foregroundStyle(theme.textTertiary)
                            .accessibilityLabel("Read-only")
                    }
                }
                if let detail {
                    Text(detail)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.isDirectory ? "Folder" : "File") \(item.name)\(detail.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var detail: String? {
        var parts: [String] = []
        if let size = item.formattedSize { parts.append(size) }
        if let modified = item.modified { parts.append(terminalRelativeTime(modified)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
