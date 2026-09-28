import SwiftUI
import PhotosUI

// MARK: - Channel Input Field
//
// Shared glass composer used by:
//   • ChannelDetailView  (main channel message input)
//   • ThreadDetailSheet  (thread reply input)
//
// Visual language matches ChatInputField: an interactive Liquid Glass shell on
// iOS 26 (frosted material on earlier iOS) with press feedback, a bare plus glyph,
// optional dictation button and a filled send circle. Context chips (reply target,
// @model mention, "model will respond") live *inside* the glass shell.

/// A contextual chip shown at the top of the channel composer.
struct ChannelComposerChip: Identifiable {
    enum Style { case reply, model }
    let id: String
    let style: Style
    let icon: String
    let title: String
    let subtitle: String?
    let onTap: (() -> Void)?
    let onRemove: (() -> Void)?
}

struct ChannelInputField: View {

    // MARK: - Required

    @Binding var text: String
    @Binding var attachments: [ChatAttachment]
    var placeholder: String = "Message"
    var isEnabled: Bool = true
    var onSend: () async -> Void
    var canSend: Bool

    // MARK: - Context chips (reply / model mention)

    var chips: [ChannelComposerChip] = []

    // MARK: - Attachment callbacks

    var onAttachmentTapped: (() -> Void)?
    var onPasteAttachments: (([ChatAttachment]) -> Void)?
    var onRemoveAttachment: ((ChatAttachment) -> Void)?

    // MARK: - Text change callback (for typing indicators)

    /// Called whenever the text field content changes.
    /// Used by ChannelDetailView to emit typing indicators to the server.
    var onTextChange: (() -> Void)?

    // MARK: - Mention / channel-link / prompt trigger callbacks

    var onAtTrigger: ((String) -> Void)?
    var onAtDismiss: (() -> Void)?
    var onHashTrigger: ((String) -> Void)?
    var onHashDismiss: (() -> Void)?
    var onSlashTrigger: ((String) -> Void)?
    var onSlashDismiss: (() -> Void)?

    // MARK: - Dictation (same service + overlay as the main chat)

    var dictationService: DictationService? = nil
    var onDictationStart: (() -> Void)?
    var onDictationStop: (() -> Void)?
    var onDictationCancel: (() -> Void)?

    // MARK: - Environment

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityScale) private var accessibilityScale

    /// UI chrome scale (buttons, icons, touch targets) — mirrors AccessibilityManager.uiScale.
    private var uiScale: CGFloat { accessibilityScale.scale(for: .ui) }

    // MARK: - User preference

    @AppStorage("sendOnEnter") private var sendOnEnter = true

    // MARK: - Font

    /// Base font size matching ChatInputField.
    private static let inputBaseFontSize: CGFloat = 14

    private var scaledInputFont: UIFont {
        let scale = accessibilityScale.scale(for: .input)
        let size = round(Self.inputBaseFontSize * scale * 10) / 10
        let base = UIFont.systemFont(ofSize: size, weight: .regular)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: rounded, size: size)
        }
        return base
    }

    private var cornerRadius: CGFloat {
        (text.contains("\n") || text.count > 60 || !chips.isEmpty || !attachments.isEmpty) ? 20 : 22
    }

    private var isDictating: Bool {
        guard let svc = dictationService else { return false }
        return svc.isActive || svc.showsRecovery
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let svc = dictationService, isDictating {
                DictationOverlayView(
                    service: svc,
                    onStop: { onDictationStop?() },
                    onCancel: { onDictationCancel?() }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            } else {
                composerShell
                    .padding(.horizontal, Spacing.screenPadding)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.15), value: canSend)
        .animation(.easeOut(duration: 0.2), value: attachments.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: chips.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDictating)
        // Fire onTextChange whenever text changes — used by ChannelDetailView to emit typing indicators.
        .onChange(of: text) { _, _ in
            onTextChange?()
        }
    }

    // MARK: - Glass Shell

    private var composerShell: some View {
        VStack(spacing: 0) {
            if !chips.isEmpty {
                VStack(spacing: 4) {
                    ForEach(chips) { chip in
                        chipRow(chip)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if !attachments.isEmpty {
                attachmentStrip
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            HStack(alignment: .bottom, spacing: 8) {
                if let onAttachmentTapped {
                    Button {
                        onAttachmentTapped()
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: "plus")
                            .scaledFont(size: 15 * uiScale, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: 28 * uiScale, height: 28 * uiScale)
                    }
                    .buttonStyle(.plain)
                    .composerHitTarget()
                    .disabled(!isEnabled)
                    .opacity(isEnabled ? 1.0 : 0.4)
                    .accessibilityLabel("Add attachment")
                }

                PasteableTextView(
                    text: $text,
                    placeholder: placeholder,
                    font: scaledInputFont,
                    textColor: UIColor(theme.textPrimary),
                    placeholderColor: UIColor(theme.textTertiary),
                    tintColor: UIColor(theme.brandPrimary),
                    isEnabled: isEnabled,
                    onPasteAttachments: { pasted in
                        withAnimation(.easeOut(duration: 0.15)) {
                            onPasteAttachments?(pasted)
                        }
                        Haptics.play(.light)
                    },
                    onSubmit: {
                        // Respect the sendOnEnter toggle: only send on Return when enabled
                        if sendOnEnter && canSend {
                            Task { await onSend() }
                        }
                    },
                    onHashTrigger: onHashTrigger,
                    onHashDismiss: onHashDismiss,
                    onAtTrigger: onAtTrigger,
                    onAtDismiss: onAtDismiss,
                    onSlashTrigger: onSlashTrigger,
                    onSlashDismiss: onSlashDismiss,
                    sendOnReturn: sendOnEnter
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 28 * uiScale)
                .accessibilityLabel(placeholder)

                trailingControls
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Whole-box tap target: any tap not consumed by a control focuses the input.
        .background {
            Color.clear
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onTapGesture {
                    guard isEnabled else { return }
                    NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
                }
        }
        .modifier(ComposerGlassModifier(
            cornerRadius: cornerRadius,
            borderColor: Color(uiColor: .separator),
            shadowColor: Color.black.opacity(theme.isDark ? 0.2 : 0.08),
            isDark: theme.isDark
        ))
        .modifier(ComposerPressFeedback(isEnabled: isEnabled))
    }

    private var trailingControls: some View {
        HStack(spacing: 8) {
            if onDictationStart != nil && !canSend {
                Button {
                    Haptics.play(.medium)
                    onDictationStart?()
                } label: {
                    Image(systemName: "mic")
                        .scaledFont(size: 13 * uiScale, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 28 * uiScale, height: 28 * uiScale)
                }
                .buttonStyle(.plain)
                .composerHitTarget()
                .disabled(!isEnabled)
                .accessibilityLabel("Start dictation")
                .transition(.scale.combined(with: .opacity))
            }

            Button {
                Task { await onSend() }
                Haptics.play(.light)
            } label: {
                Circle()
                    .fill(canSend ? theme.brandPrimary : theme.textTertiary.opacity(0.15))
                    .frame(width: 28 * uiScale, height: 28 * uiScale)
                    .overlay(
                        Image(systemName: "arrow.up")
                            .scaledFont(size: 12 * uiScale, weight: .bold)
                            .foregroundStyle(canSend ? theme.brandOnPrimary : theme.textTertiary)
                    )
            }
            .buttonStyle(.plain)
            .composerHitTarget()
            .disabled(!canSend || !isEnabled)
            .accessibilityLabel("Send message")
        }
    }

    // MARK: - Context Chip

    private func chipRow(_ chip: ChannelComposerChip) -> some View {
        let tint: Color = chip.style == .model ? theme.mentionModelText : theme.replyBorder
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            Image(systemName: chip.icon)
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(chip.title)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let subtitle = chip.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let onRemove = chip.onRemove {
                Button {
                    onRemove()
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 22, height: 22)
                        .background(theme.textTertiary.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .composerHitTarget()
                .accessibilityLabel("Remove")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { chip.onTap?() }
    }

    // MARK: - Attachment Strip

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentThumbnail(attachment)
                }
            }
            .padding(.top, 4)
            .padding(.trailing, 4)
        }
    }

    private func attachmentThumbnail(_ attachment: ChatAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = attachment.thumbnail {
                    thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: 2) {
                        if attachment.isUploading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "doc")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textTertiary)
                        }
                        Text(attachment.name)
                            .scaledFont(size: 7)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .padding(.horizontal, 3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.surfaceContainer.opacity(0.6))
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if attachment.isUploading && attachment.thumbnail != nil {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.black.opacity(0.35))
                        .overlay(ProgressView().controlSize(.small).tint(.white))
                }
            }

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    onRemoveAttachment?(attachment)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 17)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 5, y: -5)
            .accessibilityLabel("Remove \(attachment.name)")
        }
    }
}
