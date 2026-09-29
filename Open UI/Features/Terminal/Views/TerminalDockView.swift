import SwiftUI
import UIKit

/// The shell + process tabs area at the bottom of the terminal panel.
/// Mirrors the web `TerminalDock`: a `Shell` tab plus one read-only tab per
/// command the model runs.
struct TerminalDockView: View {
    @Bindable var viewModel: TerminalBrowserViewModel
    var isFullscreen: Bool
    var onToggleFullscreen: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(TerminalPreferences.themeKey) private var themeRaw = TerminalThemeOption.app.rawValue
    @AppStorage(TerminalPreferences.fontSizeKey) private var fontSize = TerminalPreferences.defaultFontSize
    @State private var copiedFlash = false

    private var shell: TerminalShellViewModel { viewModel.shell }
    private var processes: TerminalProcessesViewModel { viewModel.processes }
    private var themeOption: TerminalThemeOption { TerminalThemeOption(rawValue: themeRaw) ?? .app }
    private var palette: TerminalThemeOption.Palette { themeOption.palette(isDark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ZStack {
                Color(uiColor: palette.background)
                content
            }
            .clipped()
        }
        .onAppear { startShellIfNeeded() }
        .onChange(of: processes.activeTab) { _, _ in startShellIfNeeded() }
        .onChange(of: viewModel.shellAvailable) { _, _ in startShellIfNeeded() }
        .onChange(of: viewModel.requiresSavedChat) { _, _ in startShellIfNeeded() }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if viewModel.shellAvailable {
                        tabChip(id: TerminalProcessesViewModel.shellTab, title: shellTitle, icon: "terminal",
                                dot: shellDotColor, closable: false)
                    }
                    ForEach(processes.tabs) { tab in
                        tabChip(id: tab.id, title: tab.command, icon: nil,
                                dot: tab.isRunning ? .green : theme.textTertiary.opacity(0.6),
                                closable: !tab.isRunning, subtitle: tab.isRunning ? nil : tab.statusText)
                    }
                }
                .padding(.horizontal, 8)
            }
            if processes.activeTab == TerminalProcessesViewModel.shellTab && viewModel.shellAvailable {
                inputModeChip
            }
            actionsMenu
            Button(action: onToggleFullscreen) {
                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFullscreen ? "Exit Full Screen" : "Full Screen Terminal")
            .padding(.trailing, 6)
        }
        .frame(height: 38)
        .background(theme.surfaceContainer.opacity(0.6))
    }

    private var shellTitle: String {
        let title = shell.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Shell" : title
    }

    private var shellDotColor: SwiftUI.Color {
        switch shell.state {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .failed: theme.error
        case .idle, .ended: theme.textTertiary.opacity(0.6)
        }
    }

    private func tabChip(id: String, title: String, icon: String?, dot: SwiftUI.Color,
                         closable: Bool, subtitle: String? = nil) -> some View {
        let selected = processes.activeTab == id
        return HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
                .overlay {
                    if dot == .orange {
                        Circle().stroke(dot.opacity(0.5), lineWidth: 2).frame(width: 10, height: 10)
                            .modifier(TerminalPulseModifier())
                    }
                }
            if let icon {
                Image(systemName: icon).scaledFont(size: 10, weight: .semibold)
            }
            Text(title)
                .scaledFont(size: 12, weight: selected ? .semibold : .medium, design: icon == nil ? .monospaced : .default)
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
            if let subtitle {
                Text(subtitle).scaledFont(size: 10).foregroundStyle(theme.textTertiary).lineLimit(1)
            }
            if closable {
                Button {
                    withAnimation(.snappy) { processes.dismiss(id) }
                } label: {
                    Image(systemName: "xmark").scaledFont(size: 8, weight: .bold)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss \(title)")
            }
        }
        .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule().fill(selected ? theme.cardBackground : Color.clear)
                .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 2, y: 1)
        }
        .contentShape(Capsule())
        .onTapGesture {
            Haptics.selection()
            withAnimation(.snappy(duration: 0.2)) { processes.select(id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Shows whether typing is edited locally (Line) or sent per key (Live).
    private var inputModeChip: some View {
        let line = shell.lineModeEnabled && !shell.liveModeDetected
        return Button {
            shell.lineModeEnabled.toggle()
            Haptics.selection()
        } label: {
            Text(line ? "Line" : "Live")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(line ? theme.brandPrimary : theme.textSecondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background((line ? theme.brandPrimary : theme.textTertiary).opacity(0.14), in: Capsule())
                .contentTransition(.opacity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line ? "Line editing: typing stays local until Return" : "Live typing: each key is sent")
        .accessibilityHint("Double-tap to switch")
    }

    // MARK: Menu

    private var actionsMenu: some View {
        Menu {
            if processes.activeTab == TerminalProcessesViewModel.shellTab {
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                Button { copyAll() } label: { Label("Copy All Output", systemImage: "doc.on.doc") }
                Button { shell.clearScreen(); Haptics.play(.light) } label: { Label("Clear Screen", systemImage: "eraser") }
                Button { shell.restart(); Haptics.play(.medium) } label: { Label("Restart Shell", systemImage: "arrow.clockwise") }
                Toggle(isOn: Binding(get: { shell.lineModeEnabled }, set: { shell.lineModeEnabled = $0 })) {
                    Label("Local Line Editing", systemImage: "text.cursor")
                }
                Divider()
            }
            Menu {
                Button { adjustFont(1) } label: { Label("Larger", systemImage: "textformat.size.larger") }
                    .disabled(fontSize >= TerminalPreferences.fontRange.upperBound)
                Button { adjustFont(-1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                    .disabled(fontSize <= TerminalPreferences.fontRange.lowerBound)
                Button { fontSize = TerminalPreferences.defaultFontSize } label: { Label("Default Size", systemImage: "arrow.uturn.backward") }
            } label: { Label("Text Size (\(Int(fontSize)) pt)", systemImage: "textformat.size") }
            Picker(selection: $themeRaw) {
                ForEach(TerminalThemeOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            } label: { Label("Theme", systemImage: "paintpalette") }
            .pickerStyle(.menu)
        } label: {
            Image(systemName: copiedFlash ? "checkmark" : "ellipsis")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(copiedFlash ? .green : theme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel("Terminal Options")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let active = processes.activeTab
        ZStack {
            // Keep the shell view alive while other tabs are shown so the
            // session and scrollback survive tab switches.
            if viewModel.shellAvailable {
                TerminalEmulatorView(source: .shell, shell: shell, processes: processes,
                                     palette: palette, fontSize: $fontSize)
                    .padding(.leading, 6)
                    .opacity(active == TerminalProcessesViewModel.shellTab ? 1 : 0)
                    .allowsHitTesting(active == TerminalProcessesViewModel.shellTab)
                    .accessibilityHidden(active != TerminalProcessesViewModel.shellTab)
                if active == TerminalProcessesViewModel.shellTab {
                    shellOverlay
                }
            }
            ForEach(processes.tabs.filter { $0.id == active }) { tab in
                TerminalEmulatorView(source: .process(tab.id), shell: shell, processes: processes,
                                     palette: palette, fontSize: $fontSize)
                    .padding(.leading, 6)
                    .id(tab.id)
            }
            if !viewModel.shellAvailable && processes.tabs.isEmpty {
                placeholder(icon: "terminal", title: "Shell unavailable",
                            message: "This terminal server doesn't allow interactive shells. Commands the model runs will appear here.")
            }
        }
    }

    @ViewBuilder
    private var shellOverlay: some View {
        switch shell.state {
        case .idle, .connecting:
            statusCapsule(text: "Connecting…", showSpinner: true)
        case .reconnecting(let attempt):
            statusCapsule(text: shell.queuedCount > 0 ? "Offline — input queued" : "Reconnecting… (\(attempt))",
                          showSpinner: true)
        case .failed(let message):
            placeholder(icon: "exclamationmark.triangle", title: "Terminal unavailable", message: message,
                        action: ("Try Again", { shell.restart() }))
        case .ended:
            VStack {
                Spacer()
                Button { shell.restart(); Haptics.play(.medium) } label: {
                    Label("Restart Shell", systemImage: "arrow.clockwise")
                        .scaledFont(size: 13, weight: .semibold)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.brandPrimary)
                .padding(.bottom, 14)
            }
        case .connected:
            EmptyView()
        }
    }

    private func statusCapsule(text: String, showSpinner: Bool) -> some View {
        VStack {
            HStack(spacing: 8) {
                if showSpinner { ProgressView().controlSize(.mini) }
                Text(text).scaledFont(size: 12, weight: .medium)
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 10)
            Spacer()
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private func placeholder(icon: String, title: String, message: String,
                             action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).scaledFont(size: 24, weight: .regular).foregroundStyle(theme.textTertiary)
            Text(title).scaledFont(size: 14, weight: .semibold).foregroundStyle(theme.textPrimary)
            Text(message).scaledFont(size: 12).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            if let action {
                Button(action.0) { action.1(); Haptics.play(.light) }
                    .buttonStyle(.bordered)
                    .tint(theme.brandPrimary)
                    .scaledFont(size: 13, weight: .semibold)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: palette.background))
    }

    // MARK: Actions

    private func startShellIfNeeded() {
        if !viewModel.shellAvailable, processes.activeTab == TerminalProcessesViewModel.shellTab,
           let first = processes.tabs.first {
            processes.select(first.id)
            return
        }
        guard viewModel.shellAvailable, !viewModel.requiresSavedChat,
              processes.activeTab == TerminalProcessesViewModel.shellTab else { return }
        shell.start()
    }

    private func paste() {
        guard let text = UIPasteboard.general.string else { return }
        shell.paste(text)
        Haptics.play(.light)
    }

    private func copyAll() {
        let text = shell.allText()
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        Haptics.notify(.success)
        withAnimation { copiedFlash = true }
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); withAnimation { copiedFlash = false } }
    }

    private func adjustFont(_ delta: Double) {
        fontSize = min(TerminalPreferences.fontRange.upperBound, max(TerminalPreferences.fontRange.lowerBound, fontSize + delta))
        Haptics.selection()
    }
}

/// Subtle pulsing ring for "connecting" indicators.
private struct TerminalPulseModifier: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.4 : 0.8)
            .opacity(on ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true } }
    }
}
