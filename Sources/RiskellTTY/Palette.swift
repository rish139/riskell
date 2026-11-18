import Foundation

/// An 8-bit RGB triple: a theme token on its way to a terminal.
public struct RGB8: Equatable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `#rrggbb` or `rrggbb`; nil for anything else.
    public init?(hex: String) {
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard body.count == 6, let v = UInt32(body, radix: 16) else { return nil }
        self.init(UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff))
    }

    public var hex: String { String(format: "#%02x%02x%02x", r, g, b) }

    /// The nearest entry of the xterm 256-colour palette (the 6x6x6 cube or the grey ramp).
    public var ansi256: UInt8 {
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
        return UInt8(dist(grey, grey, grey) < dist(cubeRGB.0, cubeRGB.1, cubeRGB.2) ? 232 + greyStep : cubeIdx)
    }

    /// The nearest of the 16 base ANSI colours (the xterm values: 0-7, then their bright versions).
    public var ansi16: UInt8 {
        let base: [(Int, Int, Int)] = [(0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0), (0, 0, 128), (128, 0, 128), (0, 128, 128),
                                       (192, 192, 192), (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0), (0, 0, 255),
                                       (255, 0, 255), (0, 255, 255), (255, 255, 255)]
        var best = 0, bestDistance = Int.max
        for (i, c) in base.enumerated() {
            let d = (Int(r) - c.0) * (Int(r) - c.0) + (Int(g) - c.1) * (Int(g) - c.1) + (Int(b) - c.2) * (Int(b) - c.2)
            if d < bestDistance { best = i; bestDistance = d }
        }
        return UInt8(best)
    }

    /// What this colour is in `mode`.
    public func color(_ mode: Mode) -> Color {
        switch mode {
        case .none: return .none
        case .truecolor: return .rgb(r, g, b)
        case .ansi256: return .idx(ansi256)
        case .ansi16: return .ansi(ansi16)
        }
    }
}

/// A theme's tokens. The cases are in the kit's `Theme.signature` order, the canonical one: hex, json and ansi output all follow it.
public struct Palette: Equatable {
    public enum Token: String, CaseIterable {
        case bg, tile, canvas, text1, text2, text3, text4, accent, ok, warn, crit, info, critInk, prov, amberDim
    }

    /// Nothing is hardcoded here: a palette is built from the theme in force, or from hex strings.
    private let values: [String: RGB8]

    /// Every token by key; one that is missing or is not a hex colour is mid grey, as the theme resolution does for a missing slot.
    public init(hex: [String: String]) {
        values = Token.allCases.reduce(into: [:]) { out, token in
            out[token.rawValue] = RGB8(hex: hex[token.rawValue] ?? "") ?? Palette.midGrey
        }
    }

    public subscript(_ token: Token) -> RGB8 { values[token.rawValue] ?? Palette.midGrey }

    /// What this token is in `mode`.
    public func color(_ token: Token, _ mode: Mode) -> Color { self[token].color(mode) }

    private static let midGrey = RGB8(0x80, 0x80, 0x80)
}
