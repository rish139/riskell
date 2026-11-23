import Foundation

/// The compact `risk status`: a section's keys on one line, each in its tone's colour.
///
/// `check` draws one key with its value, which is what `risk status --all` shows; this draws the keys alone, so a whole section fits one
/// line and the screen fits a terminal. The colour, the mark a warning or a failure carries, and the width are the kit's, so the line
/// reads the same in colour, plain, ASCII and narrow.
extension Tty {
    /// The keys of one section, with no values: the title in text2 padded to `titleWidth`, then each key in its tone's colour.
    ///
    /// `titleWidth` is the column the keys start in — the longest title plus two — so every section's keys line up. The keys wrap at
    /// `contentWidth` and continue under the first key; a key that does not fit on a line of its own keeps that line rather than being cut.
    public func keyLine(_ title: String, titleWidth: Int, keys: [(tone: Tone, key: String)]) -> [String] {
        let column = max(1, titleWidth)
        let room = max(1, contentWidth - column)
        let items: [(text: String, width: Int)] = keys.map { row in
            switch row.tone {
            case .ok: return (self.tone(row.key, .text3), row.key.count)
            case .note: return (self.tone(row.key, .text4), row.key.count)
            case .warn, .crit:
                let marked = glyph(for: row.tone) + " " + row.key
                return (self.tone(marked, row.tone == .warn ? .warn : .crit), marked.count)
            }
        }
        guard !items.isEmpty else { return [] }
        var groups: [[(text: String, width: Int)]] = []
        var current: [(text: String, width: Int)] = []
        var used = 0
        for item in items {
            if !current.isEmpty, used + 2 + item.width > room {
                groups.append(current)
                current = []
                used = 0
            }
            used += (current.isEmpty ? 0 : 2) + item.width
            current.append(item)
        }
        if !current.isEmpty { groups.append(current) }
        return groups.enumerated().map { index, group in
            let head = index == 0
                ? tone(title, .text2) + String(repeating: " ", count: max(0, column - title.count))
                : String(repeating: " ", count: column)
            return "  " + head + group.map(\.text).joined(separator: "  ")
        }
    }
}
