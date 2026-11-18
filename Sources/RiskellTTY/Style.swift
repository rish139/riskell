import Foundation

/// A terminal colour: a truecolor triple, an entry of the 256-colour palette, one of the 16 base colours, or nothing.
public enum Color: Equatable {
    case none
    case rgb(UInt8, UInt8, UInt8)
    case idx(UInt8)
    case ansi(UInt8)
}

/// Weight, dim and colours for one run of text.
public struct Style: Equatable {
    public var fg: Color
    public var bg: Color
    public var bold: Bool
    public var dim: Bool

    public init(fg: Color = .none, bg: Color = .none, bold: Bool = false, dim: Bool = false) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.dim = dim
    }

    public static let plain = Style()
    /// What turns a style off again.
    public static let reset = "\u{1b}[0m"

    /// The SGR sequence that turns this style on: a reset first, so styles never add up.
    public var sgr: String {
        var codes = ["0"]
        if bold { codes.append("1") }
        if dim { codes.append("2") }
        switch fg {
        case .none: break
        case .rgb(let r, let g, let b): codes.append("38;2;\(r);\(g);\(b)")
        case .idx(let n): codes.append("38;5;\(n)")
        case .ansi(let n): codes.append("\(n < 8 ? 30 + Int(n) : 82 + Int(n))")      // 30-37, then 90-97
        }
        switch bg {
        case .none: break
        case .rgb(let r, let g, let b): codes.append("48;2;\(r);\(g);\(b)")
        case .idx(let n): codes.append("48;5;\(n)")
        case .ansi(let n): codes.append("\(n < 8 ? 40 + Int(n) : 92 + Int(n))")      // 40-47, then 100-107
        }
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }
}
