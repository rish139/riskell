import Foundation

extension Tty {
    /// The one-line mark every command starts with: the strip of the logo, `riskell`, the command's name, and, flush right, one dim detail
    /// (a path, a count, the agent's state). The full masthead is for the screens that report on the whole system; this is for the rest.
    public func header(_ command: String, detail: String? = nil) -> String {
        let left = String(repeating: " ", count: headerWidth(command))
        let styled = headerPrefix(command)
        guard let detail, !detail.isEmpty else { return styled }
        let room = contentWidth - left.count - detail.count
        guard room >= 2 else { return styled }
        return styled + String(repeating: " ", count: room) + ink(detail, .text4)
    }

    /// The styled start of a header, and its visible width: the margin, the strip, `riskell` and the command.
    func headerPrefix(_ command: String) -> String {
        "  " + ink(glyphs.logoStrip, .accent) + " " + ink("riskell", .text1, bold: true) + "  " + ink(command, .text2)
    }

    func headerWidth(_ command: String) -> Int { 2 + glyphs.logoStrip.count + 1 + "riskell".count + 2 + command.count }

    /// One entry per two lines: a state dot, the name, its kind and version (and a mark such as `installed`), then the description in
    /// the softer text, wrapped under the name and cut with an ellipsis only after the second line. For lists whose rows have a sentence.
    public func entries(_ rows: [(tone: Tone, name: String, tag: String, version: String, mark: String?, text: String)]) -> [String] {
        let nameWidth = rows.map(\.name.count).max() ?? 0, tagWidth = rows.map(\.tag.count).max() ?? 0
        var out: [String] = []
        for row in rows {
            var line = "  " + ink(glyphs.dot, color(for: row.tone) == color(for: .note) ? .text4 : tokenFor(row.tone)) + "  "
            line += ink(padding(row.name, nameWidth), .text1, bold: true) + "  " + ink(padding(row.tag, tagWidth), .info) + "  " + ink(row.version, .text4)
            if let mark = row.mark, !mark.isEmpty { line += "  " + ink(glyphs.ok + " " + mark, .ok) }
            out.append(line)
            let room = max(10, contentWidth - 5)
            var wrapped = wrap(row.text, room)
            if wrapped.count > 2 { wrapped = Array(wrapped.prefix(2)); wrapped[1] = cut(wrapped[1] + " " + "\u{2026}", room) }
            for text in wrapped { out.append("     " + ink(text, .text3)) }
        }
        return out
    }

    /// A label and a run of words on one line, wrapped under the first word: the compact form of a list whose rows need no sentence.
    public func chips(label: String, items: [String], labelWidth: Int) -> [String] {
        let room = max(10, contentWidth - 2 - labelWidth - 2)
        var lines: [String] = [], current = ""
        for item in items {
            if !current.isEmpty && current.count + 2 + item.count > room { lines.append(current); current = item }
            else { current += (current.isEmpty ? "" : "  ") + item }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.enumerated().map { index, text in
            "  " + (index == 0 ? ink(padding(label, labelWidth), .text2) : String(repeating: " ", count: labelWidth)) + "  " + ink(text, .text1)
        }
    }

    private func tokenFor(_ tone: Tone) -> Palette.Token {
        switch tone {
        case .ok: return .ok
        case .warn: return .warn
        case .crit: return .crit
        case .note: return .text4
        }
    }
}

