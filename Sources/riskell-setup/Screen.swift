import Foundation

/// One character cell. `ch` is a single grapheme (every glyph the installer draws is one column wide).
struct Cell: Equatable {
    var ch: String
    var style: Style
}

/// A frame: a width x height grid of cells. Screens draw into a fresh grid every time; `Renderer` writes only what changed.
final class Grid {
    let w: Int
    let h: Int
    private(set) var cells: [Cell]

    init(w: Int, h: Int) {
        self.w = max(1, w)
        self.h = max(1, h)
        cells = Array(repeating: Cell(ch: " ", style: .plain), count: self.w * self.h)
    }

    subscript(x: Int, y: Int) -> Cell {
        cells[y * w + x]
    }

    /// Writes `text` starting at (x, y), clipped to the grid and to `max` columns. Returns the columns used.
    @discardableResult
    func put(_ x: Int, _ y: Int, _ text: String, _ style: Style = .plain, max: Int? = nil) -> Int {
        guard y >= 0, y < h, x < w else { return 0 }
        let limit = Swift.min(w, max.map { x + $0 } ?? w)
        var col = x
        for ch in text {
            if col >= limit || col < 0 { break }
            cells[y * w + col] = Cell(ch: String(ch), style: style)
            col += 1
        }
        return col - x
    }

    /// Writes the text right-aligned so it ends at column `end` (exclusive).
    func putRight(_ end: Int, _ y: Int, _ text: String, _ style: Style = .plain) {
        put(end - text.count, y, text, style)
    }

    func fill(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ style: Style) {
        for yy in y..<Swift.min(h, y + height) {
            for xx in x..<Swift.min(w, x + width) where xx >= 0 && yy >= 0 {
                cells[yy * w + xx] = Cell(ch: " ", style: style)
            }
        }
    }

    func set(_ x: Int, _ y: Int, _ cell: Cell) {
        guard x >= 0, y >= 0, x < w, y < h else { return }
        cells[y * w + x] = cell
    }

    /// Plain text, one line per row, trailing spaces removed. What the snapshots store as `.txt`.
    func plainText() -> String {
        var rows: [String] = []
        for y in 0..<h {
            var line = ""
            for x in 0..<w { line += cells[y * w + x].ch }
            while line.hasSuffix(" ") { line.removeLast() }
            rows.append(line)
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// The same grid with SGR colour codes, one line per row. What the snapshots store as `.ansi`.
    func ansi() -> String {
        var out = ""
        for y in 0..<h {
            var current = Style.plain
            for x in 0..<w {
                let c = cells[y * w + x]
                if c.style != current {
                    out += sgr(c.style)
                    current = c.style
                }
                out += c.ch
            }
            out += "\u{1b}[0m\n"
        }
        return out
    }
}

/// The SGR sequence for a style: reset, then weight, dim and colours.
func sgr(_ s: Style) -> String {
    var codes = ["0"]
    if s.bold { codes.append("1") }
    if s.dim { codes.append("2") }
    switch s.fg {
    case .none: break
    case .rgb(let r, let g, let b): codes.append("38;2;\(r);\(g);\(b)")
    case .idx(let n): codes.append("38;5;\(n)")
    }
    switch s.bg {
    case .none: break
    case .rgb(let r, let g, let b): codes.append("48;2;\(r);\(g);\(b)")
    case .idx(let n): codes.append("48;5;\(n)")
    }
    return "\u{1b}[" + codes.joined(separator: ";") + "m"
}

/// Writes frames to the terminal. Only cells that changed since the last frame are written, inside a synchronized
/// update (where the terminal supports it), so a redraw never flickers.
final class Renderer {
    private var front: Grid?

    /// Forget the last frame (after a resize or on the first draw): the next frame repaints every cell.
    func invalidate() {
        front = nil
    }

    func frame(_ grid: Grid) -> String {
        var out = "\u{1b}[?2026h"
        let full = front == nil || front!.w != grid.w || front!.h != grid.h
        if full { out += "\u{1b}[2J" }
        var cur: (Int, Int)? = nil
        var style: Style? = nil
        for y in 0..<grid.h {
            for x in 0..<grid.w {
                let c = grid[x, y]
                if !full, let f = front, f[x, y] == c { continue }
                if cur == nil || cur! != (x, y) {
                    out += "\u{1b}[\(y + 1);\(x + 1)H"
                }
                if style != c.style {
                    out += sgr(c.style)
                    style = c.style
                }
                out += c.ch
                cur = (x + 1, y)
            }
        }
        out += "\u{1b}[0m\u{1b}[?2026l"
        front = grid
        return out
    }
}
