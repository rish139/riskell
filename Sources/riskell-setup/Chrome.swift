import Foundation

/// The shared frame of every screen: header (wordmark, step counter, dots, thin rule), body, status line and footer hints.
/// One column, left margin 3, no boxes except the drawn bar mock, the theme card and the schematic.
struct Body {
    let x: Int
    let y: Int
    let w: Int
    let h: Int
}

/// Set by the App while a selection marker is easing (the newly chosen row shows a half-filled marker for two frames).
enum Ease {
    static var marker = false
}

enum Chrome {
    static let margin = 3
    static let minW = 60
    static let minH = 20

    /// Tall terminals get two rows of air above the header; the footer stays at the bottom.
    static func top(_ g: Grid) -> Int {
        g.h >= 28 ? 2 : 0
    }

    static func drawHeader(_ g: Grid, stage: Stage) {
        let t = top(g)
        g.put(margin, t, "riskell", Ink.accent)
        g.put(margin + 8, t, "setup", Ink.dim)
        if let n = stage.step {
            let right = g.w - margin
            var dots = ""
            for i in 1...8 {
                dots += i < n ? "●" : (i == n ? "◉" : "○")
                if i < 8 { dots += " " }
            }
            g.putRight(right - dots.count - 3, t, "\(n) / 8", Ink.dim)
            var x = right - dots.count
            for i in 1...8 {
                let ch = i < n ? "●" : (i == n ? "◉" : "○")
                g.put(x, t, ch, i == n ? Ink.accentText : Ink.dim)
                x += 2
            }
        }
        g.put(margin, t + 1, String(repeating: "─", count: max(0, g.w - 2 * margin)), Ink.dim)
    }

    /// Hints are dropped from the end when they do not fit; a hint is never cut in the middle.
    static func drawFooter(_ g: Grid, hints: String, status: (String, Bool)? = nil) {
        if let (text, bad) = status {
            g.put(margin, g.h - 2, text, bad ? Ink.bad : Ink.dim, max: g.w - 2 * margin)
        }
        var parts = hints.components(separatedBy: "   ")
        while parts.joined(separator: "   ").count > g.w - 2 * margin && parts.count > 1 { parts.removeLast() }
        g.put(margin, g.h - 1, parts.joined(separator: "   "), Ink.dim, max: g.w - 2 * margin)
    }

    static func body(_ g: Grid) -> Body {
        let t = top(g)
        return Body(x: margin, y: t + 3, w: g.w - 2 * margin, h: max(0, g.h - t - 6))
    }

    /// Title (bold) and one dim sentence, clipped to the body width. Returns the first content row.
    @discardableResult
    static func title(_ g: Grid, _ b: Body, _ title: String, _ sub: String, subWidth: Int? = nil) -> Int {
        g.put(b.x, b.y, title, Ink.bold, max: b.w)
        g.put(b.x, b.y + 1, sub, Ink.dim, max: subWidth ?? b.w)
        return b.y + 3
    }

    /// Word-wraps a dim paragraph into `width` columns, at most `lines` lines. Returns the row after the last line.
    @discardableResult
    static func paragraph(_ g: Grid, _ x: Int, _ y: Int, width: Int, text: String, lines: Int = 2, style: Style = Ink.dim) -> Int {
        var row = y
        var line = ""
        var used = 0
        for word in text.split(separator: " ") {
            if !line.isEmpty && line.count + 1 + word.count > width {
                g.put(x, row, line, style, max: width)
                row += 1
                used += 1
                line = ""
                if used >= lines { return row }
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { g.put(x, row, line, style, max: width); row += 1 }
        return row
    }

    /// One option row: marker (● selected, ○ not, ◐ while the selection eases), bold label when focused, dim tag,
    /// and a dim note ending at the right edge.
    static func option(_ g: Grid, _ x: Int, _ y: Int, width: Int, label: String, selected: Bool, focused: Bool,
                       tag: String? = nil, note: String? = nil) {
        let marker = selected ? (focused && Ease.marker ? "◐" : "●") : "○"
        g.put(x, y, marker, selected ? Ink.accentText : Ink.dim)
        let labelStyle = focused ? Ink.bold : (selected ? Ink.text : Ink.dim)
        var used = g.put(x + 2, y, label, labelStyle, max: width - 2)
        if let t = tag, used + 2 + t.count < width {
            g.put(x + 2 + used + 2, y, t, Ink.dim)
            used += 2 + t.count
        }
        if let n = note {
            let room = width - used - 4
            if room > 4 {
                let text = n.count > room ? String(n.prefix(max(0, room - 1))) + "…" : n
                g.putRight(x + width, y, text, Ink.dim)
            }
        }
    }

    static func toggle(_ g: Grid, _ x: Int, _ y: Int, width: Int, label: String, on: Bool, focused: Bool, state: String) {
        option(g, x, y, width: width, label: label, selected: on, focused: focused, tag: nil, note: state)
    }

    /// Scrolls a long list so the cursor stays visible; returns the first visible index.
    static func window(count: Int, cursor: Int, rows: Int) -> Int {
        guard count > rows else { return 0 }
        return min(max(0, cursor - rows / 2), count - rows)
    }

    // MARK: the bar mock

    /// The pill mock: three box-drawn pills (battery, clock, a dot) in the scheme's colours, three rows tall, on a strip of
    /// the scheme's background one cell wider than the mock on each side. `pills` is 3, or 2 on narrow screens.
    /// Returns the width of the mock (without the strip margins).
    @discardableResult
    static func mockBar(_ g: Grid, _ x: Int, _ y: Int, scheme s: SchemeData, pills: Int = 3) -> Int {
        let bg = Ink.hex(s.bg)
        let edge = Style(fg: Ink.hex(s.text4), bg: bg)
        let text1 = Style(fg: Ink.hex(s.text1), bg: bg)
        let ok = Style(fg: Ink.hex(s.ok), bg: bg)
        let dimCell = Style(fg: Ink.hex(s.text4), bg: bg)
        let accent = Style(fg: Ink.hex(s.accent), bg: bg)
        // (width, content for the middle row as (text, style) parts)
        var boxes: [(Int, [(String, Style)])] = [
            (17, [(" 100% ", text1), ("▮▮▮▮", ok), ("▯", dimCell)]),
            (12, [(" 02:41 PM", text1)]),
            (5, [(" ● ", accent)]),
        ]
        boxes = Array(boxes.prefix(max(1, min(pills, 3))))
        let total = boxes.reduce(0) { $0 + $1.0 } + boxes.count - 1
        // the background strip: exactly the mock plus one cell each side
        g.fill(x - 1, y, total + 2, 3, Style(fg: .none, bg: bg))
        var cx = x
        for (w, parts) in boxes {
            g.put(cx, y, "╭" + String(repeating: "─", count: w - 2) + "╮", edge)
            g.put(cx, y + 2, "╰" + String(repeating: "─", count: w - 2) + "╯", edge)
            g.put(cx, y + 1, "│", edge)
            g.put(cx + w - 1, y + 1, "│", edge)
            var used = 0
            for (text, st) in parts {
                let room = w - 2 - used
                if room <= 0 { break }
                used += g.put(cx + 1 + used, y + 1, text, st, max: room)
            }
            cx += w + 1
        }
        return total
    }

    // MARK: the bar schematic

    /// Resolved hugging per bar (top, bottom, left, right) for a bar mode; the preset keeps riskell's own mix.
    static func hugs(_ mode: BarMode) -> [Bool] {
        switch mode {
        case .preset: return [false, false, true, true]
        case .floating: return [false, false, false, false]
        case .hug: return [true, true, true, true]
        }
    }

    /// The bar schematic on a 26 x 10 canvas: a rounded screen border (dim), a notch hanging from the top edge, and the
    /// bars in accent. Floating bars are islands with gaps; hugging bars are solid bands or columns. Minimal shows the top
    /// bar only; Classic adds the bottom and left bars; Full adds the right bar. A card hangs from the status island:
    /// flush is a plain box touching it, chat is a rounded box joined by a neck.
    static func schematic(_ g: Grid, _ x: Int, _ y: Int, preset: Preset, mode: BarMode, cards: CardStyle) {
        let w = 26, h = 10
        let dim = Ink.dim
        let acc = Ink.accentText
        g.put(x, y, "╭" + String(repeating: "─", count: w - 2) + "╮", dim)
        g.put(x, y + h - 1, "╰" + String(repeating: "─", count: w - 2) + "╯", dim)
        for r in 1..<(h - 1) {
            g.put(x, y + r, "│", dim)
            g.put(x + w - 1, y + r, "│", dim)
        }
        let x0 = x + 1, y0 = y + 1, iw = w - 2, ih = h - 2
        let hug = hugs(mode)
        let notch = 9

        // top bar
        if hug[0] {
            for c in 0..<iw { g.put(x0 + c, y0, "▄", acc) }
        } else {
            g.put(x0 + 2, y0, "▄▄▄▄▄▄", acc)
            g.put(x0 + 14, y0, "▄▄▄▄▄▄", acc)
        }
        g.put(x0 + notch, y0, "▀▀▀▀", dim)

        // left bar: a solid column when hugging, segments with gaps when floating
        if preset != .minimal {
            if hug[2] {
                for r in 1...6 { g.put(x0, y0 + r, "▌", acc) }
            } else {
                for r in [2, 3, 5, 6] { g.put(x0, y0 + r, "▌", acc) }
            }
        }
        // right bar (Full only), mirrored
        if preset == .full {
            if hug[3] {
                for r in 1...6 { g.put(x0 + iw - 1, y0 + r, "▐", acc) }
            } else {
                for r in [2, 3, 5, 6] { g.put(x0 + iw - 1, y0 + r, "▐", acc) }
            }
        }
        // bottom bar: islands along the last row, or a solid row when hugging
        if preset != .minimal {
            if hug[1] {
                for c in 0..<iw { g.put(x0 + c, y0 + ih - 1, "▀", acc) }
            } else {
                g.put(x0 + 7, y0 + ih - 1, "▀▀▀▀▀▀", acc)
            }
        }

        // the card, under the status island (columns 14 to 19)
        let cx = x0 + 14
        if cards == .flush {
            g.put(cx, y0 + 1, "┌────┐", dim)
            g.put(cx, y0 + 2, "│    │", dim)
            g.put(cx, y0 + 3, "└────┘", dim)
        } else {
            g.put(cx + 2, y0 + 1, "┬", dim)
            g.put(cx, y0 + 2, "╭────╮", dim)
            g.put(cx, y0 + 3, "│    │", dim)
            g.put(cx, y0 + 4, "╰────╯", dim)
        }
    }

    // MARK: theme card

    /// Rows of the full theme card (with the text sample) and of the compact card (palette only).
    static let cardFull = 17
    static let cardCompact = 11

    /// The live preview of a scheme in a thin rounded card: the bar mock on top, the palette as two rows of labelled
    /// swatches, then (full card only) a four-line text sample with the status words in their tones.
    /// Every row is exactly `width` cells: the edges are drawn last on every row, so the right border is straight.
    static func themeCard(_ g: Grid, _ x: Int, _ y: Int, width: Int, height: Int, scheme s: SchemeData) {
        let full = height >= cardFull
        let rows = full ? cardFull : cardCompact
        let bg = Ink.hex(s.bg)
        let edgeC = Ink.hex(s.text4)
        for r in 0..<rows { g.fill(x, y + r, width, 1, Style(fg: .none, bg: bg)) }
        let edge = Style(fg: edgeC, bg: bg)
        g.put(x, y, "╭" + String(repeating: "─", count: width - 2) + "╮", edge)
        g.put(x, y + rows - 1, "╰" + String(repeating: "─", count: width - 2) + "╯", edge)
        for r in 1..<(rows - 1) {
            g.put(x, y + r, "│", edge)
            g.put(x + width - 1, y + r, "│", edge)
        }
        let cx = x + 2
        let inner = width - 4
        // the bar mock: three pills when they fit, else two
        mockBar(g, cx, y + 2, scheme: s, pills: inner >= 36 ? 3 : 2)

        // the palette: two rows of swatches with short labels; the bg swatch is a text4 dot pattern so it shows on the card
        let rowA: [(String, String)] = [("bg", s.bg), ("tile", s.tile), ("t1", s.text1), ("t2", s.text2), ("t3", s.text3), ("t4", s.text4)]
        let rowB: [(String, String)] = [("acc", s.accent), ("ok", s.ok), ("warn", s.warn), ("crit", s.crit), ("info", s.info)]
        func swatchRow(_ items: [(String, String)], _ row: Int, cell: Int) {
            for (i, item) in items.enumerated() {
                let sx = cx + i * cell
                if item.0 == "bg" {
                    g.put(sx, row, "░░", Style(fg: Ink.hex(s.text4), bg: bg))
                } else {
                    g.put(sx, row, "██", Style(fg: Ink.hex(item.1), bg: bg))
                }
                g.put(sx, row + 1, String(item.0.prefix(max(1, cell - 1))), Style(fg: Ink.hex(s.text3), bg: bg), max: inner)
            }
        }
        let cellA = max(4, min(5, inner / 6))
        swatchRow(rowA, y + 6, cell: cellA)
        swatchRow(rowB, y + 8, cell: cellA)

        if full {
            let t = y + 11
            g.put(cx, t, "Headline in text1", Style(fg: Ink.hex(s.text1), bg: bg, bold: true), max: inner)
            g.put(cx, t + 1, "Body copy in text2", Style(fg: Ink.hex(s.text2), bg: bg), max: inner)
            g.put(cx, t + 2, "Hint in text4", Style(fg: Ink.hex(s.text4), bg: bg), max: inner)
            var wx = cx
            wx += g.put(wx, t + 3, "accent", Style(fg: Ink.hex(s.accent), bg: bg, bold: true), max: inner) + 2
            wx += g.put(wx, t + 3, "ok", Style(fg: Ink.hex(s.ok), bg: bg, bold: true), max: max(0, inner - (wx - cx))) + 2
            wx += g.put(wx, t + 3, "warn", Style(fg: Ink.hex(s.warn), bg: bg, bold: true), max: max(0, inner - (wx - cx))) + 2
            g.put(wx, t + 3, "crit", Style(fg: Ink.hex(s.crit), bg: bg, bold: true), max: max(0, inner - (wx - cx)))
        }
    }
}
