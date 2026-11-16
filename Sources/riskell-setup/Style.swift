import Foundation

/// How colour is written: truecolor when the terminal says so, the 256-colour palette otherwise, and no colour at all under NO_COLOR.
enum ColorMode {
    case truecolor, ansi256, mono
}

enum Color: Equatable {
    case none
    case rgb(UInt8, UInt8, UInt8)
    case idx(UInt8)
}

struct Style: Equatable {
    var fg: Color = .none
    var bg: Color = .none
    var bold = false
    var dim = false

    static let plain = Style()
}

/// The palette. One accent (#fabd2f), dim greys for secondary text, red and green only for status marks.
enum Ink {
    static var mode: ColorMode = .truecolor

    /// Hex colours from the theme data, mapped to what the terminal can show.
    static func hex(_ s: String) -> Color {
        guard let (r, g, b) = parseHex(s) else { return .none }
        switch mode {
        case .truecolor: return .rgb(r, g, b)
        case .ansi256: return .idx(nearest256(r, g, b))
        case .mono: return .none
        }
    }

    static var accentColor: Color { mode == .truecolor ? .rgb(250, 189, 47) : .idx(221) }
    static var dimColor: Color { mode == .truecolor ? .rgb(132, 122, 110) : .idx(245) }
    static var okColor: Color { mode == .truecolor ? .rgb(184, 187, 38) : .idx(142) }
    static var badColor: Color { mode == .truecolor ? .rgb(251, 73, 52) : .idx(203) }

    /// The one accent, bold: the wordmark and the selected marker.
    static var accent: Style { Style(fg: mode == .mono ? .none : accentColor, bold: true) }
    /// The accent without weight: a cursor, a tag, a value that is being edited.
    static var accentText: Style { Style(fg: mode == .mono ? .none : accentColor) }
    static var bold: Style { Style(bold: true) }
    static var text: Style { .plain }
    static var dim: Style { Style(fg: mode == .mono ? .none : dimColor, dim: true) }
    static var ok: Style { Style(fg: mode == .mono ? .none : okColor, bold: true) }
    static var bad: Style { Style(fg: mode == .mono ? .none : badColor, bold: true) }

    /// Reads NO_COLOR and COLORTERM; the caller sets `mode` once at start-up.
    static func detectMode(env: [String: String]) -> ColorMode {
        if env["NO_COLOR"] != nil { return .mono }
        let term = env["COLORTERM"]?.lowercased() ?? ""
        return term == "truecolor" || term == "24bit" ? .truecolor : .ansi256
    }

    static func parseHex(_ s: String) -> (UInt8, UInt8, UInt8)? {
        guard s.hasPrefix("#"), s.count == 7 else { return nil }
        let body = Array(s.dropFirst())
        func part(_ i: Int) -> UInt8? { UInt8(String(body[i..<i + 2]), radix: 16) }
        guard let r = part(0), let g = part(2), let b = part(4) else { return nil }
        return (r, g, b)
    }

    /// Nearest entry of the xterm 256-colour palette (the 6x6x6 cube or the grey ramp).
    static func nearest256(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
        let levels: [Int] = [0, 95, 135, 175, 215, 255]
        func cube(_ v: UInt8) -> Int {
            var best = 0
            for (i, l) in levels.enumerated() where abs(Int(v) - l) < abs(Int(v) - levels[best]) { best = i }
            return best
        }
        let ci = (cube(r), cube(g), cube(b))
        let cubeRGB = (levels[ci.0], levels[ci.1], levels[ci.2])
        let cubeIdx = 16 + 36 * ci.0 + 6 * ci.1 + ci.2
        let avg = (Int(r) + Int(g) + Int(b)) / 3
        let greyStep = min(23, max(0, (avg - 8 + 5) / 10))
        let grey = 8 + 10 * greyStep
        func dist(_ x: Int, _ y: Int, _ z: Int) -> Int {
            (Int(r) - x) * (Int(r) - x) + (Int(g) - y) * (Int(g) - y) + (Int(b) - z) * (Int(b) - z)
        }
        let dCube = dist(cubeRGB.0, cubeRGB.1, cubeRGB.2)
        let dGrey = dist(grey, grey, grey)
        return UInt8(dGrey < dCube ? 232 + greyStep : cubeIdx)
    }
}
