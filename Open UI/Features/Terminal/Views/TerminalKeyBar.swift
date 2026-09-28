import UIKit
import SwiftTerm

/// Keyboard accessory row for the terminal: modifiers, arrows and the
/// symbols that are awkward to reach on the iOS keyboard.
///
/// - `ctrl` / `alt` are sticky for the next key (tap again to cancel) and
///   drive SwiftTerm's own modifier state so typed letters are translated.
/// - Arrow keys honour application-cursor mode (vim, less, tmux…) and repeat
///   while held.
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {

    weak var terminalView: TerminalView?
    var onPaste: (() -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var ctrlButton: UIButton?
    private var altButton: UIButton?
    private var repeatTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    var enableInputClicksWhenVisible: Bool { true }

    private enum Key {
        case text(String, send: String)
        case symbol(String, accessibility: String, send: KeyAction)
        case ctrl, alt
    }

    enum KeyAction { case bytes([UInt8]), arrowUp, arrowDown, arrowLeft, arrowRight, paste, dismiss }

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: isPhone ? 44 : 50), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        observers.append(NotificationCenter.default.addObserver(forName: .terminalViewControlModifierReset, object: terminalView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateModifierButtons() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .terminalViewMetaModifierReset, object: terminalView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateModifierButtons() }
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
        scrollView.delaysContentTouches = false
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let dismiss = makeButton(title: nil, symbol: "keyboard.chevron.compact.down", accessibility: "Hide Keyboard")
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

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        for key in keys {
            switch key {
            case .text(let title, let send):
                let button = makeButton(title: title, symbol: nil, accessibility: accessibilityName(title))
                button.addAction(UIAction { [weak self] _ in self?.perform(.bytes(Array(send.utf8))) }, for: .touchUpInside)
                stack.addArrangedSubview(button)
            case .symbol(let symbol, let label, let action):
                let button = makeButton(title: nil, symbol: symbol, accessibility: label)
                switch action {
                case .arrowUp, .arrowDown, .arrowLeft, .arrowRight:
                    button.addAction(UIAction { [weak self] _ in self?.beginRepeat(action) }, for: .touchDown)
                    button.addAction(UIAction { [weak self] _ in self?.endRepeat() }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
                default:
                    button.addAction(UIAction { [weak self] _ in self?.perform(action) }, for: .touchUpInside)
                }
                stack.addArrangedSubview(button)
            case .ctrl:
                let button = makeButton(title: "ctrl", symbol: nil, accessibility: "Control")
                button.addAction(UIAction { [weak self] _ in self?.toggleCtrl() }, for: .touchUpInside)
                ctrlButton = button
                stack.addArrangedSubview(button)
            case .alt:
                let button = makeButton(title: "alt", symbol: nil, accessibility: "Option")
                button.addAction(UIAction { [weak self] _ in self?.toggleAlt() }, for: .touchUpInside)
                altButton = button
                stack.addArrangedSubview(button)
            }
        }
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

    private func makeButton(title: String?, symbol: String?, accessibility: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor.secondarySystemFill
        config.baseForegroundColor = UIColor.label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: title.map { $0.count > 2 ? 10 : 12 } ?? 11,
                                                        bottom: 6, trailing: title.map { $0.count > 2 ? 10 : 12 } ?? 11)
        if let title {
            var attributes = AttributeContainer()
            attributes.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
            config.attributedTitle = AttributedString(title, attributes: attributes)
        }
        if let symbol {
            config.image = UIImage(systemName: symbol,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        }
        let button = UIButton(configuration: config)
        button.accessibilityLabel = accessibility
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        button.configurationUpdateHandler = { [weak self] button in
            guard var config = button.configuration else { return }
            let active = (button === self?.ctrlButton && self?.terminalView?.controlModifier == true)
                || (button === self?.altButton && self?.terminalView?.metaModifier == true)
            config.baseBackgroundColor = active ? button.tintColor : (button.isHighlighted ? UIColor.tertiarySystemFill : UIColor.secondarySystemFill)
            config.baseForegroundColor = active ? .white : .label
            button.configuration = config
        }
        return button
    }

    // MARK: Actions

    private func toggleCtrl() {
        guard let terminalView else { return }
        terminalView.controlModifier.toggle()
        UIDevice.current.playInputClick()
        updateModifierButtons()
    }

    private func toggleAlt() {
        guard let terminalView else { return }
        terminalView.metaModifier.toggle()
        UIDevice.current.playInputClick()
        updateModifierButtons()
    }

    private func updateModifierButtons() {
        ctrlButton?.setNeedsUpdateConfiguration()
        altButton?.setNeedsUpdateConfiguration()
    }

    private func beginRepeat(_ action: KeyAction) {
        perform(action)
        repeatTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.perform(action, click: false) }
        }
        timer.fireDate = Date().addingTimeInterval(0.45)
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
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
        case .dismiss:
            endRepeat()
            _ = terminalView.resignFirstResponder()
        }
        updateModifierButtons()
    }
}
