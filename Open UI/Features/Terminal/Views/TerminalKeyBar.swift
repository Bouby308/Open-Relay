import UIKit
import SwiftTerm

/// Keyboard accessory row for the terminal: modifiers, arrows and the
/// symbols that are awkward to reach on the iOS keyboard.
///
/// Keys are plain views (not `UIControl`s). One tap recognizer and one
/// long-press recognizer on the scroll view decide which key was hit, so a
/// horizontal swipe always scrolls the bar instead of pressing a key.
///
/// - `ctrl` / `alt` are sticky for the next key (tap again to cancel) and
///   drive SwiftTerm's own modifier state so typed letters are translated.
/// - Arrow keys honour application-cursor mode (vim, less, tmux…) and repeat
///   while held.
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback, UIGestureRecognizerDelegate {

    weak var terminalView: TerminalView?
    var onPaste: (() -> Void)?

    private let scrollView = KeyBarScrollView()
    private let stack = UIStackView()
    private var keyViews: [KeyCapView] = []
    private var ctrlKey: KeyCapView?
    private var altKey: KeyCapView?
    private var repeatTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    var enableInputClicksWhenVisible: Bool { true }

    private enum Key {
        case text(String, send: String)
        case symbol(String, accessibility: String, send: KeyAction)
        case ctrl, alt
    }

    enum KeyAction { case bytes([UInt8]), arrowUp, arrowDown, arrowLeft, arrowRight, paste, dismiss, ctrl, alt }

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: isPhone ? 44 : 50), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        observers.append(NotificationCenter.default.addObserver(forName: .terminalViewControlModifierReset, object: terminalView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateModifierKeys() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .terminalViewMetaModifierReset, object: terminalView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateModifierKeys() }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIDevice.current.userInterfaceIdiom == .phone ? 44 : 50)
    }

    private var keys: [Key] {
        [
            .text("esc", send: "\u{1B}"),
            .text("tab", send: "\t"),
            .ctrl, .alt,
            .symbol("arrow.left", accessibility: "Left", send: .arrowLeft),
            .symbol("arrow.up", accessibility: "Up", send: .arrowUp),
            .symbol("arrow.down", accessibility: "Down", send: .arrowDown),
            .symbol("arrow.right", accessibility: "Right", send: .arrowRight),
            .text("^C", send: "\u{03}"),
            .text("|", send: "|"), .text("~", send: "~"), .text("/", send: "/"), .text("-", send: "-"),
            .text("_", send: "_"), .text("*", send: "*"), .text("&", send: "&"), .text("$", send: "$"),
            .text("\"", send: "\""), .text("'", send: "'"), .text("`", send: "`"),
            .text("<", send: "<"), .text(">", send: ">"), .text("[", send: "["), .text("]", send: "]"),
            .text("{", send: "{"), .text("}", send: "}"), .text("\\", send: "\\"), .text("=", send: "="),
            .text("^D", send: "\u{04}"), .text("^Z", send: "\u{1A}"), .text("^L", send: "\u{0C}"), .text("^R", send: "\u{12}"),
            .text("home", send: "\u{1B}[H"), .text("end", send: "\u{1B}[F"),
            .text("pgup", send: "\u{1B}[5~"), .text("pgdn", send: "\u{1B}[6~"),
            .symbol("doc.on.clipboard", accessibility: "Paste", send: .paste)
        ]
    }

    private func build() {
        backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.onBeginScroll = { [weak self] in self?.cancelPress() }
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false // touches are resolved by the recognizers below
        scrollView.addSubview(stack)

        let dismiss = UIButton(configuration: Self.dismissConfiguration())
        dismiss.accessibilityLabel = "Hide Keyboard"
        dismiss.addAction(UIAction { [weak self] _ in self?.perform(.dismiss) }, for: .touchUpInside)
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dismiss)

        let divider = UIView()
        divider.backgroundColor = UIColor.separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -4),
            divider.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            divider.heightAnchor.constraint(equalToConstant: 22),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -4),
            dismiss.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismiss.heightAnchor.constraint(equalToConstant: 32),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        for key in keys {
            let view: KeyCapView
            switch key {
            case .text(let title, let send):
                view = KeyCapView(title: title, symbol: nil, action: .bytes(Array(send.utf8)))
                view.accessibilityLabel = accessibilityName(title)
            case .symbol(let symbol, let label, let action):
                view = KeyCapView(title: nil, symbol: symbol, action: action)
                view.accessibilityLabel = label
                switch action {
                case .arrowUp, .arrowDown, .arrowLeft, .arrowRight: view.repeats = true
                default: break
                }
            case .ctrl:
                view = KeyCapView(title: "ctrl", symbol: nil, action: .ctrl)
                view.accessibilityLabel = "Control"
                ctrlKey = view
            case .alt:
                view = KeyCapView(title: "alt", symbol: nil, action: .alt)
                view.accessibilityLabel = "Option"
                altKey = view
            }
            view.onAccessibilityActivate = { [weak self] action in self?.fire(action) }
            keyViews.append(view)
            stack.addArrangedSubview(view)
        }

        // Touch-down highlight + tap + hold-to-repeat, all yielding to scrolling.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = 10
        press.cancelsTouchesInView = false
        press.delegate = self
        scrollView.addGestureRecognizer(press)
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
    }

    // MARK: Touch handling

    private var pressedKey: KeyCapView?
    private var pressStart: Date?
    private var didRepeat = false
    private var holdTimer: Timer?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func key(at recognizer: UIGestureRecognizer) -> KeyCapView? {
        let point = recognizer.location(in: stack)
        // Generous hit area: nearest key horizontally within its slot.
        return keyViews.first { $0.frame.insetBy(dx: -3, dy: -8).contains(point) }
    }

    @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard let key = key(at: recognizer) else { return }
            pressedKey = key
            key.isPressed = true
            didRepeat = false
            if key.repeats {
                holdTimer?.invalidate()
                let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.startRepeating() }
                }
                RunLoop.main.add(timer, forMode: .common)
                holdTimer = timer
            }
        case .ended:
            guard let key = pressedKey else { return }
            let repeated = didRepeat
            cancelPress()
            if !repeated { fire(key.action) }
        case .cancelled, .failed:
            cancelPress()
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began || recognizer.state == .changed { cancelPress() }
    }

    private func startRepeating() {
        guard let key = pressedKey else { return }
        didRepeat = true
        fire(key.action)
        endRepeat()
        let timer = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let key = self.pressedKey else { return }
                self.perform(key.action, click: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func cancelPress() {
        holdTimer?.invalidate(); holdTimer = nil
        endRepeat()
        pressedKey?.isPressed = false
        pressedKey = nil
    }

    private func fire(_ action: KeyAction) {
        switch action {
        case .ctrl: toggleCtrl()
        case .alt: toggleAlt()
        default: perform(action)
        }
    }

    private static func dismissConfiguration() -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor.secondarySystemFill
        config.baseForegroundColor = UIColor.label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11)
        config.image = UIImage(systemName: "keyboard.chevron.compact.down",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        return config
    }

    private func accessibilityName(_ title: String) -> String {
        switch title {
        case "esc": "Escape"
        case "tab": "Tab"
        case "^C": "Control C"
        case "^D": "Control D"
        case "^Z": "Control Z"
        case "^L": "Control L"
        case "^R": "Control R"
        case "pgup": "Page Up"
        case "pgdn": "Page Down"
        default: title
        }
    }

    // MARK: Actions

    private func toggleCtrl() {
        guard let terminalView else { return }
        terminalView.controlModifier.toggle()
        UIDevice.current.playInputClick()
        updateModifierKeys()
    }

    private func toggleAlt() {
        guard let terminalView else { return }
        terminalView.metaModifier.toggle()
        UIDevice.current.playInputClick()
        updateModifierKeys()
    }

    private func updateModifierKeys() {
        ctrlKey?.isLatched = terminalView?.controlModifier == true
        altKey?.isLatched = terminalView?.metaModifier == true
    }

    private func endRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    func perform(_ action: KeyAction, click: Bool = true) {
        guard let terminalView else { return }
        if click { UIDevice.current.playInputClick() }
        let app = terminalView.getTerminal().applicationCursor
        switch action {
        case .bytes(let bytes):
            var bytes = bytes
            // Apply a pending ctrl to single printable characters (e.g. ctrl + "[").
            if terminalView.controlModifier, bytes.count == 1, let c = bytes.first, c >= 0x40, c < 0x7F {
                bytes = [c & 0x1F]
                terminalView.controlModifier = false
            }
            if terminalView.metaModifier {
                bytes.insert(0x1B, at: 0)
                terminalView.metaModifier = false
            }
            terminalView.send(data: bytes[...])
        case .arrowUp: terminalView.send(data: (app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)[...])
        case .arrowDown: terminalView.send(data: (app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)[...])
        case .arrowLeft: terminalView.send(data: (app ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)[...])
        case .arrowRight: terminalView.send(data: (app ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)[...])
        case .paste: onPaste?()
        case .ctrl: toggleCtrl(); return
        case .alt: toggleAlt(); return
        case .dismiss:
            endRepeat()
            _ = terminalView.resignFirstResponder()
        }
        updateModifierKeys()
    }
}

/// A single key on the bar. Purely visual — touches are handled by the bar.
final class KeyCapView: UIView {
    let action: TerminalKeyBar.KeyAction
    var repeats = false
    var onAccessibilityActivate: ((TerminalKeyBar.KeyAction) -> Void)?
    private let label = UILabel()
    private let imageView = UIImageView()

    var isPressed = false { didSet { updateAppearance() } }
    var isLatched = false { didSet { updateAppearance() } }

    init(title: String?, symbol: String?, action: TerminalKeyBar.KeyAction) {
        self.action = action
        super.init(frame: .zero)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        translatesAutoresizingMaskIntoConstraints = false

        let content: UIView
        if let title {
            label.text = title
            label.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
            label.textAlignment = .center
            content = label
        } else {
            imageView.image = UIImage(systemName: symbol ?? "questionmark",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            imageView.contentMode = .center
            content = imageView
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let padding: CGFloat = (title?.count ?? 0) > 2 ? 10 : 12
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: title == nil ? 11 : padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(title == nil ? 11 : padding)),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateAppearance()
    }

    override func accessibilityActivate() -> Bool {
        onAccessibilityActivate?(action)
        return true
    }

    private func updateAppearance() {
        let background: UIColor = isLatched ? tintColor : (isPressed ? .tertiarySystemFill : .secondarySystemFill)
        let foreground: UIColor = isLatched ? .white : .label
        backgroundColor = background
        label.textColor = foreground
        imageView.tintColor = foreground
        transform = isPressed ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
        accessibilityTraits = isLatched ? [.keyboardKey, .selected] : .keyboardKey
    }
}

/// Horizontal scroller for the key bar. `UIScrollView` refuses to cancel
/// touches on `UIControl`s by default, so once the bar is full of buttons a
/// swipe that starts on a key never scrolls. Allowing cancellation for
/// controls makes every drag scroll while taps stay instant.
final class KeyBarScrollView: UIScrollView, UIScrollViewDelegate {
    var onBeginScroll: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private let fade = CAGradientLayer()

    override func layoutSubviews() {
        super.layoutSubviews()
        // Soft fade at whichever edge has more keys to scroll to.
        let canLeft = contentOffset.x > 1
        let canRight = contentOffset.x + bounds.width < contentSize.width - 1
        let edge = min(0.08, 16 / max(bounds.width, 1))
        fade.frame = bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.black.withAlphaComponent(canLeft ? 0 : 1).cgColor, UIColor.black.cgColor,
                       UIColor.black.cgColor, UIColor.black.withAlphaComponent(canRight ? 0 : 1).cgColor]
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        if layer.mask !== fade { layer.mask = fade }
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UIControl { return true }
        return super.touchesShouldCancel(in: view)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onBeginScroll?()
    }
}
