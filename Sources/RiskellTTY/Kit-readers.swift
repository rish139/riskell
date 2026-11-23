import Foundation

// The readers task's additions to the kit: a header with a dim detail beside its title, and pretty JSON in the theme's tokens.
// Nothing here is a colour of its own: every token comes from the palette, and every line is the kit's two-space screen margin.

extension Tty {
    /// The two lines above a table, with a dim detail after the title as well as the meta against the right edge. `tableHead` without a
    /// detail is the same screen; this is the one a screen uses when it names the file it is showing.
    public func tableHead(title: String, detail: String?, meta: String?) -> [String] {
        var head = headerPrefix(title)
        var used = headerWidth(title)
        if let detail, !detail.isEmpty {
            let room = max(1, contentWidth - used - 2)
            let shown = detail.count <= room ? detail : cut(detail, room)
            head += "  " + ink(shown, .text4)
            used += 2 + shown.count
        }
        if let meta, !meta.isEmpty, contentWidth - used > 1 {
            let room = max(1, contentWidth - used - 1)
            let shown = meta.count <= room ? meta : cut(meta, room)
            head += String(repeating: " ", count: max(1, contentWidth - used - shown.count)) + ink(shown, .text4)
        }
        return [head, "  " + ink(String(repeating: glyphs.ruleChar, count: max(0, contentWidth - 2)), .text4)]
    }

    /// A pretty JSON document as screen lines: keys in the dim text, strings in the brightest, numbers in the accent, true and false in
    /// the information colour, and the punctuation dimmer than all of them. The document is already formatted; this only colours it, so a
    /// reader can still match it against the file byte for byte once the escapes are stripped.
    public func jsonLines(_ text: String) -> [String] {
        let room = max(1, contentWidth - 2)
        return text.components(separatedBy: "\n").map { line in
            "  " + jsonHighlight(line.count <= room ? line : cut(line, room))
        }
    }

    private func jsonHighlight(_ line: String) -> String {
        var out = ""
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                var j = line.index(after: i)
                var escaped = false
                while j < line.endIndex {
                    let c = line[j]
                    if escaped {
                        escaped = false
                    } else if c == "\\" {
                        escaped = true
                    } else if c == "\"" {
                        j = line.index(after: j)
                        break
                    }
                    j = line.index(after: j)
                }
                let token = String(line[i..<j])
                var k = j
                while k < line.endIndex, line[k] == " " { k = line.index(after: k) }
                out += ink(token, k < line.endIndex && line[k] == ":" ? .text3 : .text1)
                i = j
            } else if ch == "-" || ch.isNumber {
                var j = i
                while j < line.endIndex, line[j].isNumber || line[j] == "-" || line[j] == "+" || line[j] == "."
                    || line[j] == "e" || line[j] == "E" {
                    j = line.index(after: j)
                }
                out += ink(String(line[i..<j]), .accent)
                i = j
            } else if line[i...].hasPrefix("true") || line[i...].hasPrefix("false") {
                let word = line[i...].hasPrefix("true") ? "true" : "false"
                out += ink(word, .info)
                i = line.index(i, offsetBy: word.count)
            } else if line[i...].hasPrefix("null") {
                out += ink("null", .text4)
                i = line.index(i, offsetBy: 4)
            } else if "{}[],:".contains(ch) {
                out += ink(String(ch), .text4)
                i = line.index(after: i)
            } else {
                out += String(ch)
                i = line.index(after: i)
            }
        }
        return out
    }
}
