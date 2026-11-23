import Foundation

/// How a check turned out: fine, worth a look, broken, or something to know. The kit picks the mark and the colour from it.
public enum Tone: Equatable, CaseIterable {
    case ok, warn, crit, note
}

/// What the bar behind a command is doing: running, stopped, or no answer at all. The string is the dim text printed after the dot.
public enum MastheadState: Equatable {
    case running(String)
    case stopped(String)
    case unknown(String)

    /// The dim text, whichever state it is.
    var detail: String {
        switch self {
        case .running(let text), .stopped(let text), .unknown(let text): return text
        }
    }
}

/// The screens a `risk` command prints: a masthead, sections, check rows, a gauge, the next thing to do, and an error.
///
/// Every method returns `[String]` of styled lines, or one String for a single line, and prints nothing: the caller decides where they go.
/// A line already starts at the left margin (two spaces) except `section`, which returns the title and its rule so that the rule, not the
/// margin, is what fills `contentWidth`. With `mode` none the escapes are gone and the text still lines up, because every width is counted
/// in characters, not in bytes.
extension Tty {
    // MARK: tones and width

    /// The mark a tone draws, in this terminal's set.
    public func glyph(for tone: Tone) -> String {
        switch tone {
        case .ok: return glyphs.ok
        case .warn: return glyphs.warn
        case .crit: return glyphs.crit
        case .note: return glyphs.note
        }
    }

    /// The colour a tone draws in: the palette's own token.
    public func color(for tone: Tone) -> Color {
        palette.color(token(for: tone), mode)
    }

    private func token(for tone: Tone) -> Palette.Token {
        switch tone {
        case .ok: return .ok
        case .warn: return .warn
        case .crit: return .crit
        case .note: return .text4
        }
    }

    /// What every rule and every wrap fills: the terminal's width less the two-space left margin, between 40 and 72 columns.
    public var contentWidth: Int { min(72, max(40, width - 2)) }

    // MARK: masthead

    /// The three rows at the top of a screen: the logo, what this machine is, and what the agent is doing.
    ///
    /// Narrower than 56 columns the logo does not fit beside the words, so it is dropped and one line says the same thing.
    public func masthead(version: String, lines: [String], state: MastheadState) -> [String] {
        let mark: Palette.Token
        switch state {
        case .running: mark = .ok
        case .stopped: mark = .crit
        case .unknown: mark = .text4
        }
        let dot = ink(glyphs.dot, mark) + " "
        if contentWidth < 56 {
            return ["  " + ink("riskell", .text1, bold: true) + " " + ink(version, .text4) + "  " + dot + ink(state.detail, .text3)]
        }
        let strip = "  " + ink(glyphs.logoStrip, .accent) + " "
        let islandCells = String(repeating: " ", count: Logo.island)
        return [
            strip + ink(String(repeating: glyphs.islandTop, count: Logo.island), island) + String(repeating: " ", count: Logo.gap)
                + ink("riskell", .text1, bold: true) + " " + ink(version, .text4),
            strip + islandCells + String(repeating: " ", count: Logo.gap) + ink(lines.first ?? "", .text3),
            strip + ink(String(repeating: glyphs.islandBottom, count: Logo.island), island) + String(repeating: " ", count: Logo.gap)
                + dot + ink(state.detail, .text3),
        ]
    }

    /// The logo is two islands ten cells wide, with three cells of air before the words beside them.
    private enum Logo {
        static let island = 10
        static let gap = 3
    }

    /// The islands are drawn between the tile and the dimmest text: a shape, not a word.
    private var island: Color {
        let tile = palette[.tile], text = palette[.text4]
        let mid = RGB8((tile.r &+ text.r) / 2, (tile.g &+ text.g) / 2, (tile.b &+ text.b) / 2)
        return mid.color(mode)
    }

    // MARK: sections and checks

    /// A section heading: the title, a space, then a rule of the terminal's rule character filling to `contentWidth - 2`.
    /// Returned without the left margin, so the caller prints two spaces and then this, and the line is exactly `contentWidth`.
    public func section(_ title: String) -> String {
        let room = max(0, contentWidth - 2 - title.count - 1)
        return ink(title, .text2) + " " + ink(String(repeating: glyphs.ruleChar, count: room), .text4)
    }

    /// One check: its mark, its key in a column, and its value. `hint` adds the command that would fix it underneath.
    ///
    /// The keys are padded to `keyWidth` so that a column of checks lines up; `checks` measures them. A value longer than the room wraps at
    /// a word boundary and hangs under its own column; a single word with no room at all is cut with an ellipsis.
    public func check(_ tone: Tone, _ key: String, _ value: String, hint: (cmd: String, note: String?)? = nil, keyWidth: Int) -> [String] {
        let width = max(1, keyWidth)
        let indent = 2 + 1 + 2 + width + 1      // margin, mark, gap, key, space
        let room = max(1, contentWidth - indent)
        var out: [String] = []
        for (i, part) in wrap(value, room).enumerated() {
            let lead = i == 0
                ? "  " + ink(glyph(for: tone), token(for: tone)) + "  " + ink(padding(key, width), .text3) + " "
                : String(repeating: " ", count: indent)
            out.append(lead + ink(part, .text1))
        }
        if let hint {
            var line = "     " + ink(glyphs.arrow, .text4) + " " + ink(hint.cmd, .accent)
            if let note = hint.note, !note.isEmpty { line += "  " + ink(note, .text4) }
            out.append(line)
        }
        return out
    }

    /// A column of checks, keys lined up: the longest key plus one column of air.
    public func checks(_ rows: [(Tone, String, String, (cmd: String, note: String?)?)]) -> [String] {
        let keyWidth = (rows.map(\.1.count).max() ?? 0) + 1
        return rows.flatMap { check($0.0, $0.1, $0.2, hint: $0.3, keyWidth: keyWidth) }
    }

    // MARK: gauge and summary

    /// `width` cells split in proportion to the counts, each part in its own colour: at least one cell for anything that happened at all,
    /// and the largest part takes up (or gives back) whatever the rounding left over, so the whole is exactly `width` cells.
    public func gauge(ok: Int, warn: Int, crit: Int, width: Int = 40) -> String {
        let cells = max(0, width)
        guard cells > 0 else { return "" }
        let counts = [max(0, ok), max(0, warn), max(0, crit)]
        let total = counts.reduce(0, +)
        guard total > 0 else { return ink(String(repeating: glyphs.gauge, count: cells), .text4) }
        let tokens: [Palette.Token] = [.ok, .warn, .crit]
        var sizes = counts.map { $0 == 0 ? 0 : max(1, Int((Double($0) * Double(cells) / Double(total)).rounded())) }
        var left = cells - sizes.reduce(0, +)
        while left != 0, let big = sizes.indices.max(by: { sizes[$0] < sizes[$1] }) {
            if left > 0 {
                sizes[big] += left
                left = 0
            } else {
                let give = min(-left, sizes[big] - (counts[big] > 0 ? 1 : 0))
                guard give > 0 else { break }      // the counts need more cells than there are
                sizes[big] -= give
                left += give
            }
        }
        var bar = ""
        for (i, size) in sizes.enumerated() where size > 0 {
            bar += ink(String(repeating: glyphs.gauge, count: size), tokens[i])
        }
        return bar
    }

    /// The gauge and its counts: what is fine, what to look at, what is failing.
    ///
    /// The gauge takes the room the counts leave, up to 40 cells, so the line is exactly the terminal's width on a narrow one too.
    public func summary(ok: Int, warn: Int, crit: Int) -> String {
        let dots = "  " + ink(glyphs.note, .text4) + "  "
        let fixed = 3 + "\(ok) ok".count + 5 + "\(warn) to look at".count + 5 + "\(crit) failing".count
        let bar = min(40, max(1, width - 2 - fixed))
        return gauge(ok: ok, warn: warn, crit: crit, width: bar) + "   " + counted(ok, "ok", .ok) + dots + counted(warn, "to look at", .warn)
            + dots + counted(crit, "failing", .crit)
    }

    /// A count and its label: the number bold in its colour, or dim when it is zero; the label is left plain.
    private func counted(_ number: Int, _ label: String, _ token: Palette.Token) -> String {
        (number == 0 ? ink("0", .text3) : ink("\(number)", token, bold: true)) + " " + label
    }

    // MARK: what next

    /// The one thing to do next, and why.
    public func next(cmd: String, why: String) -> String {
        "  " + ink("next", .text4) + "  " + ink(cmd, .accent) + "  " + ink(why, .text3)
    }

    // MARK: an error

    /// The same shape for every failed command: what went wrong, in one line, then what to try instead.
    ///
    /// The tries are commands with a note each, the notes in one column under the first; `detail` is the one sentence that saves opening
    /// the log.
    public func errorBlock(title: String, detail: String?, tries: [(cmd: String, note: String)]) -> [String] {
        var out = ["  " + ink(glyph(for: .crit), .crit) + "  " + ink(title, .text1, bold: true)]
        if let detail, !detail.isEmpty {
            out += wrap(detail, contentWidth - 5).map { String(repeating: " ", count: 5) + ink($0, .text3) }
        }
        out.append("")
        let column = tries.map(\.cmd.count).max() ?? 0
        for (i, attempt) in tries.enumerated() {
            let lead = i == 0 ? "     " + ink("try", .text4) + "   " : String(repeating: " ", count: 11)
            out.append(lead + ink(padding(attempt.cmd, column), .accent) + "    " + ink(attempt.note, .text3))
        }
        return out
    }

    // MARK: fitting text

    // The helpers below are the kit's own, shared by the screens in Kit.swift and Kit2.swift: not API, so not public.

    func ink(_ text: String, _ token: Palette.Token, bold: Bool = false) -> String {
        styling(text, Style(fg: palette.color(token, mode), bold: bold))
    }

    func ink(_ text: String, _ color: Color, bold: Bool = false) -> String {
        styling(text, Style(fg: color, bold: bold))
    }

    func padding(_ text: String, _ width: Int) -> String {
        text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
    }

    /// `text` broken into lines of at most `room` characters, at spaces, each word whole; a word that cannot fit is cut.
    func wrap(_ text: String, _ room: Int) -> [String] {
        guard room > 0 else { return [] }
        if text.count <= room { return [text] }
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ").map(String.init) {
            if line.isEmpty {
                line = word.count <= room ? word : cut(word, room)
            } else if line.count + 1 + word.count <= room {
                line += " " + word
            } else {
                lines.append(line)
                line = word.count <= room ? word : cut(word, room)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    func cut(_ word: String, _ room: Int) -> String {
        room <= 1 ? "…" : String(word.prefix(room - 1)) + "…"
    }
}
