import Foundation

/// How a cell sits in its column.
public enum Align: Equatable {
    case left, right
}

/// One cell of a row: its text, how it lines up with the cells above and below, and its style.
public struct Cell: Equatable {
    public var text: String
    public var align: Align
    public var style: Style

    public init(_ text: String, _ align: Align = .left, _ style: Style = .plain) {
        self.text = text
        self.align = align
        self.style = style
    }
}

/// The four marks a command prints beside a result.
public enum Mark: String, CaseIterable {
    case ok = "✓", warn = "!", fail = "✗", info = "·"
}

/// Writes the command line's output: headings, label and value lines, aligned rows, marks, and the three text tones.
///
/// Two invariants hold for every method. A style is written only when `mode` is not `none`, and a pipe is `none`, so escape sequences never
/// reach a file: `strip` gives the plain text a reader sees, which is what a golden test compares. And a line is never wider than `width`
/// (COLUMNS, else 80) once its escapes are removed: a cell that does not fit is cut. One Character is one column.
public struct Tty: Equatable {
    /// The space between two columns.
    public static let gutter = 2

    public let mode: Mode
    public let width: Int
    public let palette: Palette

    public init(mode: Mode, width: Int = 80, palette: Palette) {
        self.mode = mode
        self.width = max(1, width)
        self.palette = palette
    }

    /// The terminal this process writes to: the mode from the environment, the width from COLUMNS.
    /// The terminal this process writes to: the mode from the environment, the width from COLUMNS.
    public static func detect(palette: Palette, env: [String: String] = ProcessInfo.processInfo.environment) -> Tty {
        make(palette: palette, env: env, isTTY: isatty(1) == 1)
    }

    /// The same, with the pipe rule overridden: an explicit `--format ansi` asks for escapes even when stdout is a pipe or a file.
    public static func forced(palette: Palette, env: [String: String] = ProcessInfo.processInfo.environment) -> Tty {
        make(palette: palette, env: env, isTTY: true)
    }

    private static func make(palette: Palette, env: [String: String], isTTY: Bool) -> Tty {
        let columns = Int(env["COLUMNS"] ?? "") ?? 80
        return Tty(mode: Mode.detect(env: env, isTTY: isTTY), width: columns > 0 ? columns : 80, palette: palette)
    }

    // MARK: styling

    /// `text` in `style`, or `text` alone when nothing is styled (a pipe, or the plain style).
    public func styling(_ text: String, _ style: Style) -> String {
        guard mode != .none, style != .plain else { return text }
        return style.sgr + text + Style.reset
    }

    /// The dimmest text: a label, a hint, a secondary value.
    public func dim(_ text: String) -> String { styling(text, Style(fg: palette.color(.text4, mode))) }
    public func bold(_ text: String) -> String { styling(text, Style(bold: true)) }
    /// The theme's accent, bold: a title, the thing being pointed at.
    public func accent(_ text: String) -> String { styling(text, Style(fg: palette.color(.accent, mode), bold: true)) }
    /// A token's own colour, for showing a palette.
    public func tone(_ text: String, _ token: Palette.Token) -> String { styling(text, Style(fg: palette.color(token, mode))) }

    // MARK: lines

    /// A heading: the accent, bold, cut to the width.
    public func heading(_ title: String) -> String { accent(clip(title, width)) }

    /// One label and its value, the label dim.
    public func label(_ key: String, _ value: String) -> String {
        rows([[Cell(key, .left, Style(fg: palette.color(.text4, mode))), Cell(value)]]).first ?? ""
    }

    /// A mark and its text: ✓ in ok, ! in warn, ✗ in crit, · in info.
    public func mark(_ mark: Mark, _ text: String) -> String {
        var token = Palette.Token.info
        switch mark {
        case .ok: token = .ok
        case .warn: token = .warn
        case .fail: token = .crit
        case .info: token = .info
        }
        return styling(mark.rawValue, Style(fg: palette.color(token, mode), bold: true)) + " " + clip(text, width - 2)
    }

    /// Rows of cells lined up into columns: each column is as wide as its widest cell, columns are a gutter apart, and right-aligned
    /// cells (numbers, units) are padded on the left. A cell that does not fit is cut, so no line is wider than `width`.
    public func rows(_ cells: [[Cell]]) -> [String] {
        let columns = cells.map(\.count).max() ?? 0
        guard columns > 0 else { return [] }
        var widths = [Int](repeating: 0, count: columns)
        for row in cells {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.text.count) }
        }
        return cells.map { row in
            var line = ""
            var left = width
            for (i, cell) in row.enumerated() where left > 0 {
                let gap = min(i > 0 ? Tty.gutter : 0, left)
                line += String(repeating: " ", count: gap)
                left -= gap
                let text = clip(cell.text, left)
                left -= text.count
                let slack = max(0, widths[i] - text.count)
                if cell.align == .right {
                    let lead = min(slack, left)
                    line += String(repeating: " ", count: lead)
                    left -= lead
                }
                line += styling(text, cell.style)
                if cell.align == .left, i < row.count - 1 {
                    let trail = min(slack, left)
                    line += String(repeating: " ", count: trail)
                    left -= trail
                }
            }
            return line
        }
    }

    // MARK: reading back

    /// The plain text of a line: every escape sequence removed. What a golden test compares.
    public static func strip(_ line: String) -> String {
        var out = ""
        var state = 0      // 0 in text, 1 after ESC, 2 inside a CSI sequence
        for ch in line {
            switch state {
            case 0:
                if ch == "\u{1b}" { state = 1 } else { out.append(ch) }
            case 1:
                state = ch == "[" ? 2 : 0
            default:
                if let v = ch.unicodeScalars.first?.value, v >= 0x40, v <= 0x7e { state = 0 }
            }
        }
        return out
    }

    private func clip(_ text: String, _ room: Int) -> String {
        guard room > 0 else { return "" }
        return text.count <= room ? text : String(text.prefix(room))
    }
}
