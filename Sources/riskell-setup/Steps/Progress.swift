import Foundation

/// The install screen (steps, the 8-cell progress bar, the failure block) and the finish screen (the revealed summary).
extension App {
    func drawInstall(_ g: Grid, _ b: Body) {
        guard let j = job else { return }
        let failed = j.failMessage != nil
        let title = failed ? "Install stopped" : (j.finished ? "Installed" : "Installing")
        var y = Chrome.title(g, b, title, "Backups first. Running setup again is safe.")
        for i in 0..<j.names.count {
            let st = j.status[i]
            let (mark, markStyle): (String, Style) = {
                switch st {
                case .pending, .skipped: return ("○", Ink.dim)
                case .running: return (spinnerFrames[tickCount % spinnerFrames.count], Ink.accentText)
                case .done: return ("✓", Ink.ok)
                case .failed: return ("✗", Ink.bad)
                }
            }()
            g.put(b.x, y, mark, markStyle)
            g.put(b.x + 2, y, j.names[i], st == .pending ? Ink.dim : Ink.text, max: 24)
            let detail = st == .done || st == .skipped || st == .failed ? j.details[i] : ""
            g.put(b.x + 27, y, detail, st == .failed ? Ink.bad : Ink.dim, max: b.w - 27)
            y += 1
        }
        y += 1
        drawProgressBar(g, b.x, y, fraction: progressShown)
        let settled = j.status.filter { $0 == .done || $0 == .skipped }.count
        g.put(b.x + 11, y, "\(settled) of \(j.names.count) steps", Ink.dim)
        y += 2
        if failed {
            g.put(b.x, y, "✗", Ink.bad)
            g.put(b.x + 2, y, j.failMessage ?? "", Ink.bad, max: b.w - 2)
            y += 1
            for line in j.failTail.suffix(5) where y < b.y + b.h - 2 {
                g.put(b.x + 2, y, line, Ink.dim, max: b.w - 2)
                y += 1
            }
            y += 1
            g.put(b.x, y, "Fix the cause, then press ⏎ to try again.", Ink.dim, max: b.w)
            g.put(b.x, y + 1, "Finished steps are not repeated.", Ink.dim, max: b.w)
        } else if !j.logLast.isEmpty {
            g.put(b.x, y, App.humanize(j.logLast), Ink.dim, max: b.w)
        }
    }

    /// A raw tool line as a status sentence: "==> Writing launch agent" becomes "starting the launch agent…".
    static func humanize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("==> ") { s = String(s.dropFirst(4)) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if s.lowercased().contains("writing launch agent") { return "starting the launch agent…" }
        if let first = s.first { s = first.lowercased() + s.dropFirst() }
        return s.hasSuffix("…") ? s : s + "…"
    }

    /// Eight cells, each a block of its own height: 0 is the lowest block, 1 the full one. Partial cells step through the
    /// eighths so the bar moves smoothly between install steps.
    func drawProgressBar(_ g: Grid, _ x: Int, _ y: Int, fraction: Double) {
        for k in 0..<8 {
            let f = min(1, max(0, fraction * 8 - Double(k)))
            let idx = Int((f * 7).rounded())
            g.put(x + k, y, progressCells[idx], f > 0 ? Ink.accentText : Ink.dim)
        }
    }

    func drawFinish(_ g: Grid, _ b: Body) {
        let lines = finishLines()
        let allShown = linesShown >= lines.count
        g.put(b.x, b.y, "✓", Ink.ok)
        g.put(b.x + 2, b.y, "riskell is running", allShown ? Ink.accent : Ink.dim)
        g.put(b.x, b.y + 1, "Settings live in ~/.config/riskell.", Ink.dim, max: b.w)
        var y = b.y + 3
        for (i, l) in lines.enumerated() where i < linesShown {
            g.put(b.x, y, l.0, l.0 == "✓" ? Ink.ok : Ink.dim)
            g.put(b.x + 2, y, l.1, Ink.text, max: 24)
            g.put(b.x + 27, y, l.2, Ink.dim, max: b.w - 27)
            y += 1
        }
        guard linesShown >= lines.count else { return }
        y += 1
        // The bar mock in the chosen theme's colours, once there is room for it and the next steps.
        if b.y + b.h - y >= 11 {
            Chrome.mockBar(g, b.x + 1, y + 1, scheme: c.themeData, pills: b.w >= 60 ? 3 : 2)
            y += 5
        }
        let next: [(String, String)] = [
            ("ctrl-alt-,", "open riskell preferences"),
            ("risk status", "check it"),
            ("risk log 30", "the recent log"),
        ]
        for (k, d) in next where y < b.y + b.h {
            g.put(b.x, y, k, Ink.text, max: 14)
            g.put(b.x + 14, y, d, Ink.dim, max: b.w - 14)
            y += 1
        }
        y += 1
        var hints = ["Location Services: Wi-Fi names in the network card"]
        if c.gesturesRiskell { hints.append("Accessibility: riskell's own gestures need it") }
        for h in hints where y < b.y + b.h {
            g.put(b.x, y, h, Ink.dim, max: b.w)
            y += 1
        }
    }

    /// The finish screen's lines: one per step that ran or was skipped, in order.
    func finishLines() -> [(String, String, String)] {
        guard let j = job else { return [] }
        var out: [(String, String, String)] = []
        for i in 0..<j.names.count where j.status[i] == .done || j.status[i] == .skipped {
            out.append((j.status[i] == .done ? "✓" : "○", j.names[i], j.details[i]))
        }
        return out
    }
}
