import Foundation

// The guided installer's rows: the small shapes the step screens need beside the kits' checks, plans and hints. They follow the
// same rules as Screens.swift and Lists.swift: every width counts characters, every colour is a palette token, and a row is returned
// as styled text so the caller decides where it goes.

extension Tty {
    /// One option of a step: the focused row is pointed at and its label is bold, a filled dot marks the chosen row.
    ///
    /// The pointer and the dot take five columns before the label; a detail wraps under the label's own column, never under the
    /// marker, and a tag (recommended, on, off) follows the label on the same line when it fits.
    public func option(_ label: String, detail: String? = nil, selected: Bool, focused: Bool, tag: String? = nil) -> [String] {
        let pointer = focused ? ink(pointerMark, .accent, bold: true) : " "
        let mark = selected ? ink(glyphs.dot, .ok) : ink(glyphs.ring, .text4)
        var line = "  " + pointer + "  " + mark + " " + ink(label, .text1, bold: focused)
        if let tag, !tag.isEmpty {
            let used = 7 + label.count + 2 + tag.count
            if used <= contentWidth { line += "  " + ink(tag, .text4) }
        }
        var out = [line]
        if let detail, !detail.isEmpty {
            out += wrap(detail, max(1, contentWidth - 7)).map { String(repeating: " ", count: 7) + ink($0, .text3) }
        }
        return out
    }

    /// A text field: its label in the key column, a chevron that is the accent while the field has the keys, then the value.
    ///
    /// An empty value shows its placeholder in the dimmest text. The caret takes one column of the room, so a full field is cut
    /// with an ellipsis rather than wrap.
    public func field(_ label: String, value: String, focused: Bool, placeholder: String? = nil) -> String {
        let keyWidth = 10
        let room = max(1, contentWidth - 2 - keyWidth - 3)
        var shown = value.isEmpty ? (placeholder ?? "") : value
        if shown.count > room { shown = cut(shown, room) }
        var line = "  " + ink(padding(label, keyWidth), .text4) + " " + ink(pointerMark, focused ? .accent : .text4) + " "
        line += ink(shown, value.isEmpty ? .text4 : .text1, bold: focused && !value.isEmpty)
        if focused { line += ink(caretMark, .accent) }
        return line
    }

    /// A paragraph in the dimmest readable text, wrapped by the kit and indented by the two-space screen margin.
    public func paragraph(_ text: String) -> [String] {
        wrap(text, max(1, contentWidth - 2)).map { "  " + ink($0, .text3) }
    }

    /// The rows of steps a screen records, in the same shape `Progress` prints while it runs: the mark, the label in a column,
    /// what the step did, then its time when there is one. The labels share one width, so the details line up.
    public func progressRows(_ rows: [(label: String, tone: Tone, detail: String, time: String)]) -> [String] {
        let labelWidth = (rows.map(\.label.count).max() ?? 0) + 1
        return rows.map { row in
            let head = "  " + ink(glyph(for: row.tone), color(for: row.tone)) + "  "
            if row.detail.isEmpty { return head + ink(row.label, .text3) }
            let room = max(1, contentWidth - (2 + 1 + 2 + labelWidth + 1) - (row.time.isEmpty ? 0 : 2 + row.time.count))
            var line = head + ink(padding(row.label, labelWidth), .text3)
            line += " " + ink(row.detail.count <= room ? row.detail : cut(row.detail, room), .text1)
            if !row.time.isEmpty { line += "  " + ink(row.time, .text4) }
            return line
        }
    }

    /// The kit's pointer and caret in the terminal's own set: `›` and `▏`, or `>` and `|` where only ASCII is safe.
    private var pointerMark: String { glyphs == .ascii ? ">" : "›" }
    private var caretMark: String { glyphs == .ascii ? "|" : "▏" }
}
