import Foundation

extension App {
    /// The brand moment (a miniature bar mock in accent, top right), a short line, and the preflight checklist.
    /// The marks appear one by one, about 60 ms apart.
    func drawWelcome(_ g: Grid, _ b: Body) {
        var y = b.y
        g.put(b.x, y, "riskell", Ink.accent)
        g.put(b.x + 8, y, "v\(riskellVersion)", Ink.dim)
        y += 2
        g.put(b.x, y, "A bar that fits your Mac.", Ink.bold, max: b.w)
        g.put(b.x, y + 1, "Nothing is written until you confirm.", Ink.dim, max: b.w)
        y += 3
        // the bar mock in the default theme, left aligned under the tagline, when there is room for the checklist too
        if b.h >= 16 {
            Chrome.mockBar(g, b.x + 1, y + 1, scheme: schemeData[schemeData.firstIndex(where: { $0.isDefault }) ?? 0], pills: b.w >= 60 ? 3 : 2)
            y += 5
        }
        let checks = Detect.checks(facts)
        for (i, c) in checks.enumerated() where i < checksShown {
            let (mark, style): (String, Style) = {
                switch c.mark {
                case .ok: return ("✓", Ink.ok)
                case .fail: return ("✗", Ink.bad)
                case .warn: return ("!", Ink.accentText)
                }
            }()
            g.put(b.x, y, mark, style)
            g.put(b.x + 2, y, c.label, Ink.text, max: 16)
            g.put(b.x + 18, y, c.detail, c.mark == .fail ? Ink.bad : Ink.dim, max: b.w - 18)
            y += 1
        }
    }
}
