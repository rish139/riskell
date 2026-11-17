import Foundation

/// The review: a calm summary, what will be written, and the three actions. The diff shows the same plan line by line.
extension App {
    func wmSummary() -> String {
        if c.wmID == "auto", let d = facts.detectedWM { return "auto (\(d))" }
        return Choices.wmLabels[c.wm]
    }

    func barsSummary() -> String {
        let mode: String
        switch c.barMode {
        case .preset: mode = "preset"
        case .floating: mode = "floating"
        case .hug: mode = "hug"
        }
        return "\(c.preset.label), \(mode), \(c.cards == .flush ? "flush" : "chat")"
    }

    func usageSummary() -> String {
        return c.claude ? "Claude Code, local logs" : "off"
    }

    func drawReview(_ g: Grid, _ b: Body) {
        Chrome.title(g, b, "Review", "Nothing is written until you choose Install.")
        let pairs: [(String, String)] = [
            ("Window mgr", wmSummary()), ("Bars", barsSummary()),
            ("Theme", c.themeData.name), ("Weather", c.weather?.name ?? "off"),
            ("Usage", usageSummary()), ("Gestures", c.gesturesRiskell ? (c.gesturesFix ? "riskell, conflicts off" : "riskell") : "system"),
            ("Scale", c.scale.map { String(format: "%.2f", $0) } ?? "auto"),
        ]
        let colW = b.w / 2
        var y = b.y + 3
        let actionsTop = b.y + b.h - 3
        // Wide: label and value side by side. Narrow: the label sits above its value, so nothing is cut.
        let stacked = b.w < 80
        for i in stride(from: 0, to: pairs.count, by: 2) where y < actionsTop - 1 {
            for (j, p) in pairs[i..<min(i + 2, pairs.count)].enumerated() {
                let x = b.x + j * colW
                if stacked {
                    g.put(x, y, p.0, Ink.dim, max: colW - 1)
                    g.put(x, y + 1, p.1, Ink.text, max: colW - 1)
                } else {
                    g.put(x, y, p.0, Ink.dim, max: 11)
                    g.put(x + 12, y, p.1, Ink.text, max: colW - 13)
                }
            }
            y += stacked ? 2 : 1
        }
        y += 1
        let cfg = facts.configFound ? "merged, backup first" : "new file"
        var files: [(String, String)] = [
            ("config.json", cfg),
            ("launch agent", facts.agentLabel),
            ("risk link", Detect.linkDir(paths).dir.appendingPathComponent("risk").path.replacingOccurrences(of: paths.home.path, with: "~")),
        ]
        if plan().addPath { files.append(("PATH", "added in ~/.zshrc")) }
        for f in files where y < actionsTop - 1 {
            g.put(b.x, y, f.0, Ink.dim, max: 14)
            g.put(b.x + 14, y, f.1, Ink.text, max: b.w - 14)
            y += 1
        }
        // Actions, anchored to the bottom of the body.
        var ay = actionsTop
        var row = 0
        if facts.layoutFound {
            Chrome.option(g, b.x, ay, width: min(b.w, 70), label: "Replace my layout", selected: c.replaceLayout, focused: cursor == 0,
                          note: c.replaceLayout ? "replaced with \(c.preset.label)" : "keep yours")
            ay += 1
            row = 1
        }
        let actions = ["Install", "Show what would change", "Back"]
        for (i, a) in actions.enumerated() {
            Chrome.option(g, b.x, ay + i, width: min(b.w, 70), label: a, selected: cursor == row + i,
                          focused: cursor == row + i, note: i == 0 ? "⏎" : nil)
        }
    }

    /// Plain lines of what Install would change: + added, ~ changed, - removed, = kept.
    func changeLines() -> [(String, String)] {
        var out: [(String, String)] = []
        let p = plan()
        for (key, value) in p.owned {
            let old = facts.existing?[key]
            if value == nil && old == nil { continue }
            if value == nil {
                out.append(("- \(key)", "removed (was \(jsonText(old!)))"))
            } else if old == nil {
                out.append(("+ \(key)", jsonText(value!)))
            } else if jsonText(old!) != jsonText(value!) {
                out.append(("~ \(key)", "\(jsonText(old!)) → \(jsonText(value!))"))
            }
        }
        if p.layoutText == nil {
            out.append(("= layout.json", "kept, your layout is unchanged"))
        } else {
            out.append((facts.layoutFound ? "~ layout.json" : "+ layout.json", "\(c.preset.label) layout"))
        }
        if p.gesturesFix { out.append(("~ trackpad", "three and four-finger gestures set off, originals saved")) }
        out.append(("+ launch agent", "\(facts.agentLabel), written and started"))
        out.append(("+ risk", "a link to scripts/risk"))
        if p.addPath { out.append(("+ PATH", "\(Detect.linkDir(paths).dir.path.replacingOccurrences(of: paths.home.path, with: "~")) added in ~/.zshrc (and your other shells' start-up files)")) }
        return out
    }

    func drawDiff(_ g: Grid, _ b: Body) {
        var y = Chrome.title(g, b, "What would change", "This is the plan. Nothing is written from this screen.")
        for (k, v) in changeLines() where y < b.y + b.h {
            let st: Style = k.hasPrefix("+") ? Ink.text : (k.hasPrefix("-") ? Ink.bad : Ink.dim)
            g.put(b.x, y, k, st, max: 18)
            g.put(b.x + 18, y, v, Ink.text, max: b.w - 18)
            y += 1
        }
        y += 1
        if y < b.y + b.h { g.put(b.x, y, "⏎ or esc goes back to the review", Ink.dim) }
    }

    /// A JSON fragment for a value, for the plan lines.
    func jsonText(_ v: Any) -> String {
        if let s = v as? String { return "\"\(s)\"" }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let d = v as? Double { return String(format: "%g", d) }
        if let o = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) {
            return String(decoding: o, as: UTF8.self)
        }
        return "\(v)"
    }
}
