import SwiftUI

// MARK: - Glass Message Menu
//
// Replaces the ReactionContextMenu package for channel messages: a themed blur
// scrim, the pressed bubble lifted in place, a glass reaction capsule above it
// and a glass action card below. Positions itself to stay on-screen.

/// One action in the menu.
struct MessageMenuAction: Identifiable {
    enum Style { case normal, destructive }
    let id: String
    let title: String
    let icon: String
    var style: Style = .normal
    let action: () -> Void
}

/// What to present: the lifted preview, its global frame, and the menu content.
struct MessageMenuContent {
    let messageId: String
    let preview: AnyView
    let sourceFrame: CGRect
    let alignTrailing: Bool
    let header: String?
    /// Emoji (Unicode) already used by the current user on this message.
    let ownReactions: Set<String>
    let showsReactions: Bool
    /// Large quick buttons (Reply / Thread / Copy / Pin).
    let quickActions: [MessageMenuAction]
    /// Grouped list rows; each inner array is a section.
    let sections: [[MessageMenuAction]]
    let onReact: (String) -> Void
    let onMoreReactions: () -> Void
}

@MainActor
@Observable
final class MessageMenuPresenter {
    var content: MessageMenuContent?
    var isVisible = false

    func present(_ content: MessageMenuContent) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Haptics.play(.medium)
        self.content = content
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { isVisible = true }
    }

    func dismiss(then action: (() -> Void)? = nil) {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
            isVisible = false
        } completion: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.content = nil
        }
        if let action {
            // Run after the dismissal starts so sheets/keyboards don't fight the overlay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: action)
        }
    }
}

/// Frequently used reactions — starts from sensible defaults and learns.
enum RecentReactions {
    private static let key = "channel.recentReactions"
    static let defaults = ["👍", "❤️", "😂", "🎉", "😮", "🙏"]

    static var top: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        var result = stored
        for d in defaults where !result.contains(d) { result.append(d) }
        return Array(result.prefix(6))
    }

    static func record(_ emoji: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == emoji }
        list.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(list.prefix(12)), forKey: key)
    }
}

/// Attach once at the screen root (channel column / thread) to host the menu.
struct MessageMenuHost: ViewModifier {
    let presenter: MessageMenuPresenter

    func body(content: Content) -> some View {
        content.overlay {
            if let menu = presenter.content {
                MessageMenuOverlay(presenter: presenter, content: menu)
                    .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Overlay

private struct MessageMenuOverlay: View {
    let presenter: MessageMenuPresenter
    let content: MessageMenuContent

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reactionsSize: CGSize = .zero
    @State private var menuSize: CGSize = .zero
    @State private var dragDown: CGFloat = 0
    @State private var cardContentHeight: CGFloat = 0

    private let gap: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let screen = geo.size
            // The overlay ignores the safe area, so GeometryReader reports zero insets.
            // Use the window's real insets (keyboard excluded — the menu dismisses it).
            let safe = Self.windowSafeInsets
            let layout = computeLayout(screen: screen, safe: safe)
            let shown = presenter.isVisible

            ZStack(alignment: .topLeading) {
                // Scrim: blur + theme tint
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(theme.background.opacity(theme.isDark ? 0.45 : 0.25))
                    .opacity(shown ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { presenter.dismiss() }
                    .accessibilityLabel("Dismiss menu")
                    .accessibilityAddTraits(.isButton)

                // Lifted preview
                content.preview
                    .frame(width: content.sourceFrame.width, height: content.sourceFrame.height,
                           alignment: .bottom)
                    .frame(height: layout.previewHeight, alignment: .bottom)
                    .clipped()
                    .scaleEffect(shown ? 1.02 : 1, anchor: content.alignTrailing ? .trailing : .leading)
                    .shadow(color: .black.opacity(shown ? 0.18 : 0), radius: 18, y: 8)
                    .position(x: content.sourceFrame.midX, y: layout.previewMidY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if content.showsReactions {
                    reactionBar
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { reactionsSize = $0 }
                        .scaleEffect(shown ? 1 : 0.6, anchor: content.alignTrailing ? .bottomTrailing : .bottomLeading)
                        .opacity(shown ? 1 : 0)
                        .position(x: layout.panelX(width: reactionsSize.width, screen: screen),
                                  y: layout.reactionsMidY)
                }

                actionCard(maxHeight: layout.menuMaxHeight)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { menuSize = $0 }
                    .scaleEffect(shown ? 1 : 0.7, anchor: content.alignTrailing ? .topTrailing : .topLeading)
                    .opacity(shown ? 1 : 0)
                    .position(x: layout.panelX(width: menuSize.width, screen: screen),
                              y: layout.menuMidY)
            }
            .offset(y: dragDown)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in dragDown = max(0, v.translation.height) * 0.5 }
                    .onEnded { v in
                        if v.translation.height > 80 || v.velocity.height > 600 { presenter.dismiss() }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragDown = 0 }
                    }
            )
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.8),
                       value: shown)
        }
        .accessibilityAction(.escape) { presenter.dismiss() }
    }

    // MARK: Layout

    private struct Layout {
        let previewMidY: CGFloat
        let previewHeight: CGFloat
        let reactionsMidY: CGFloat
        let menuMidY: CGFloat
        let menuMaxHeight: CGFloat
        let alignTrailing: Bool
        let sourceFrame: CGRect

        func panelX(width: CGFloat, screen: CGSize) -> CGFloat {
            let margin: CGFloat = 12
            let x = alignTrailing ? sourceFrame.maxX - width / 2 : sourceFrame.minX + width / 2
            return min(max(x, margin + width / 2), screen.width - margin - width / 2)
        }
    }

    @MainActor
    static var windowSafeInsets: EdgeInsets {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        let i = window?.safeAreaInsets ?? .zero
        return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
    }

    /// Places reactions above and the card below the lifted preview, keeping the
    /// whole block between the status bar and the home indicator. When it can't
    /// fit, the preview is clipped (latest content kept) and the card scrolls.
    private func computeLayout(screen: CGSize, safe: EdgeInsets) -> Layout {
        let src = content.sourceFrame
        let rH: CGFloat = content.showsReactions ? max(reactionsSize.height, 52) : 0
        let rBlock = rH > 0 ? rH + gap : 0
        let top = safe.top + 16
        let bottom = screen.height - max(safe.bottom, 12) - 16
        let available = max(bottom - top, 200)

        // The card gets priority; keep at least a sliver of the preview visible.
        let minPreview = min(src.height, 56)
        let menuMax = max(available - rBlock - minPreview - gap, 120)
        let mH = min(max(menuSize.height, 200), menuMax)
        let previewH = min(src.height, screen.height * 0.45,
                           max(available - rBlock - gap - mH, minPreview))

        var previewTop = src.maxY - previewH   // clipped previews keep their bottom edge
        let blockBottom = previewTop + previewH + gap + mH
        if blockBottom > bottom { previewTop -= blockBottom - bottom }
        if previewTop - rBlock < top { previewTop = top + rBlock }

        return Layout(
            previewMidY: previewTop + previewH / 2,
            previewHeight: previewH,
            reactionsMidY: previewTop - gap - rH / 2,
            menuMidY: previewTop + previewH + gap + mH / 2,
            menuMaxHeight: menuMax,
            alignTrailing: content.alignTrailing,
            sourceFrame: src
        )
    }

    // MARK: Reaction bar

    private var reactionBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(RecentReactions.top.enumerated()), id: \.element) { index, emoji in
                let isOwn = content.ownReactions.contains(emoji)
                Button {
                    RecentReactions.record(emoji)
                    Haptics.play(.light)
                    let react = content.onReact
                    presenter.dismiss { react(emoji) }
                } label: {
                    Text(emoji)
                        .font(.system(size: 26))
                        .frame(width: 42, height: 42)
                        .background(isOwn ? theme.brandPrimary.opacity(0.22) : .clear, in: Circle())
                        .scaleEffect(presenter.isVisible ? 1 : 0.3)
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.62)
                                .delay(Double(index) * 0.03),
                            value: presenter.isVisible
                        )
                }
                .buttonStyle(MenuPressStyle())
                .accessibilityLabel("React with \(emoji)")
            }
            Button {
                let more = content.onMoreReactions
                presenter.dismiss { more() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(theme.textTertiary.opacity(0.15), in: Circle())
            }
            .buttonStyle(MenuPressStyle())
            .accessibilityLabel("More reactions")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .chatControlGlass(in: Capsule(), fallback: .regularMaterial)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private func run(_ item: MessageMenuAction) {
        Haptics.play(.light)
        let action = item.action
        presenter.dismiss { action() }
    }

    // MARK: Action card

    /// Card that scrolls only when it's taller than the space left on screen
    /// (large Dynamic Type, short windows).
    private func actionCard(maxHeight: CGFloat) -> some View {
        let measured = actionCardContent
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardContentHeight = $0 }
        return Group {
            if cardContentHeight > maxHeight {
                ScrollView { measured }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: maxHeight)
            } else {
                measured
            }
        }
        .frame(width: 260)
        .chatControlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fallback: .regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }

    private var actionCardContent: some View {
        VStack(spacing: 0) {
            if let header = content.header {
                Text(header)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
            if !content.quickActions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(content.quickActions) { item in
                        Button { run(item) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(height: 22)
                                Text(item.title)
                                    .scaledFont(size: 11, weight: .medium)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .foregroundStyle(theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(theme.textTertiary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(MenuPressStyle())
                        .accessibilityLabel(item.title)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, content.header == nil ? 10 : 4)
                .padding(.bottom, content.sections.isEmpty ? 10 : 6)
            }
            ForEach(Array(content.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 || !content.quickActions.isEmpty {
                    Divider().padding(.horizontal, 14).opacity(0.6)
                }
                VStack(spacing: 0) {
                    ForEach(section) { item in
                        Button { run(item) } label: {
                            HStack(spacing: 12) {
                                Text(item.title)
                                    .scaledFont(size: 15)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: item.icon)
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(width: 22)
                            }
                            .foregroundStyle(item.style == .destructive ? Color.red : theme.textPrimary)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MenuRowStyle())
                        .accessibilityLabel(item.title)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 260)
    }
}

// MARK: - Button styles

private struct MenuPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
    }
}
