import SwiftUI
import UIKit
import SwiftTerm

/// Terminal colour themes. The default follows the app's light/dark theme so
/// the shell feels native; the others match classic terminals.
enum TerminalThemeOption: String, CaseIterable, Identifiable {
    case app, openWebUI, solarizedDark, dracula

    var id: String { rawValue }
    var title: String {
        switch self {
        case .app: "Match App"
        case .openWebUI: "Classic Dark"
        case .solarizedDark: "Solarized"
        case .dracula: "Dracula"
        }
    }

    struct Palette {
        let background: UIColor
        let foreground: UIColor
        let cursor: UIColor
        let selection: UIColor
        let ansi: [UInt32] // 16 colours, 0xRRGGBB
        let isDark: Bool
    }

    func palette(isDark: Bool) -> Palette {
        switch self {
        case .app:
            return isDark
                ? Palette(background: UIColor(red: 0.075, green: 0.075, blue: 0.08, alpha: 1),
                          foreground: UIColor(white: 0.9, alpha: 1), cursor: .white,
                          selection: UIColor.systemBlue.withAlphaComponent(0.35), ansi: Self.darkANSI, isDark: true)
                : Palette(background: UIColor(red: 0.985, green: 0.985, blue: 0.99, alpha: 1),
                          foreground: UIColor(white: 0.13, alpha: 1), cursor: UIColor(white: 0.15, alpha: 1),
                          selection: UIColor.systemBlue.withAlphaComponent(0.22), ansi: Self.lightANSI, isDark: false)
        case .openWebUI:
            return Palette(background: .black, foreground: UIColor(white: 0.753, alpha: 1), cursor: .white,
                           selection: UIColor(white: 0.267, alpha: 1), ansi: Self.darkANSI, isDark: true)
        case .solarizedDark:
            return Palette(background: UIColor(terminalHex: 0x002B36), foreground: UIColor(terminalHex: 0x93A1A1), cursor: UIColor(terminalHex: 0x93A1A1),
                           selection: UIColor(terminalHex: 0x073642),
                           ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                                  0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3], isDark: true)
        case .dracula:
            return Palette(background: UIColor(terminalHex: 0x282A36), foreground: UIColor(terminalHex: 0xF8F8F2), cursor: UIColor(terminalHex: 0xF8F8F2),
                           selection: UIColor(terminalHex: 0x44475A),
                           ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                                  0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF], isDark: true)
        }
    }

    /// Tuned for dark backgrounds (similar to the macOS Terminal "Pro" palette).
    static let darkANSI: [UInt32] = [
        0x2E3436, 0xF1564B, 0x4EC96C, 0xE5C15A, 0x5C9DFF, 0xC678DD, 0x3DC6D4, 0xD3D7CF,
        0x6B7178, 0xFF7B72, 0x7EE787, 0xF2D675, 0x79B8FF, 0xD2A8FF, 0x76E3EA, 0xFFFFFF
    ]
    /// Darker variants that stay readable on a light background.
    static let lightANSI: [UInt32] = [
        0x1F2328, 0xCF222E, 0x116329, 0x9A6700, 0x0550AE, 0x8250DF, 0x1B7C83, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0x7D4E00, 0x0969DA, 0x6639BA, 0x3192AA, 0x8C959F
    ]
}

extension UIColor {
    convenience init(terminalHex hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// User-adjustable terminal preferences (persisted).
enum TerminalPreferences {
    static let themeKey = "terminal.theme"
    static let fontSizeKey = "terminal.fontSize"
    static let heightKey = "terminal.dockHeightFraction"
    static let defaultFontSize: Double = 12
    static let fontRange: ClosedRange<Double> = 8...22

    static func font(size: Double) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }
}

extension TerminalView {
    /// Applies a palette + font to a SwiftTerm view.
    func applyAppearance(_ palette: TerminalThemeOption.Palette, fontSize: Double) {
        let newFont = TerminalPreferences.font(size: fontSize)
        if font.pointSize != newFont.pointSize { font = newFont }
        installColors(palette.ansi.map {
            SwiftTerm.Color(red8: UInt16(($0 >> 16) & 0xFF), green8: UInt16(($0 >> 8) & 0xFF), blue8: UInt16($0 & 0xFF))
        })
        nativeForegroundColor = palette.foreground
        nativeBackgroundColor = palette.background
        layer.backgroundColor = palette.background.cgColor
        backgroundColor = palette.background
        caretColor = palette.cursor
        selectedTextBackgroundColor = palette.selection
        keyboardAppearance = palette.isDark ? .dark : .light
        indicatorStyle = palette.isDark ? .white : .black
        setNeedsDisplay()
    }
}
