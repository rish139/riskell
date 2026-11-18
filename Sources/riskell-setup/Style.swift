import RiskellTTY

/// The installer's ink: one accent (#fabd2f), dim greys for secondary text, red and green only for status marks. The colour machinery —
/// hex parsing, the 256-colour fallback, mode detection, SGR — is RiskellTTY's, which `riskell --palette` shares. The four inks keep the
/// 256-colour entries the screens were designed with, because the cube's nearest entry to that yellow is an orange.
enum Ink {
    static var mode: RiskellTTY.Mode = .truecolor

    /// Hex colours from the theme data, mapped to what the terminal can show.
    static func hex(_ s: String) -> Color { RGB8(hex: s)?.color(mode) ?? .none }

    static var accentColor: Color { ink(250, 189, 47, 221) }
    static var dimColor: Color { ink(132, 122, 110, 245) }
    static var okColor: Color { ink(184, 187, 38, 142) }
    static var badColor: Color { ink(251, 73, 52, 203) }

    /// The one accent, bold: the wordmark and the selected marker.
    static var accent: Style { Style(fg: accentColor, bold: true) }
    /// The accent without weight: a cursor, a tag, a value that is being edited.
    static var accentText: Style { Style(fg: accentColor) }
    static var bold: Style { Style(bold: true) }
    static var text: Style { .plain }
    static var dim: Style { Style(fg: dimColor, dim: true) }
    static var ok: Style { Style(fg: okColor, bold: true) }
    static var bad: Style { Style(fg: badColor, bold: true) }

    /// A colour and the 256-colour entry designed for it; the base colours keep that same entry.
    private static func ink(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ ansi256: UInt8) -> Color {
        switch mode {
        case .truecolor: return .rgb(r, g, b)
        case .ansi256, .ansi16: return .idx(ansi256)
        case .none: return .none
        }
    }
}
