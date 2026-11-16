import Foundation

/// The option screens: window manager, bars, theme, usage, gestures and scale.
extension App {
    func drawWM(_ g: Grid, _ b: Body) {
        var y = Chrome.title(g, b, "Window manager", "Bars go around the windows your window manager tiles.")
        let width = min(b.w, 70)
        for (i, id) in Choices.wmIDs.enumerated() {
            var note = Choices.wmNotes[i]
            var tag: String?
            if id == "auto" {
                tag = "recommended"
                note = facts.detectedWM.map { "detected: \($0)" } ?? "nothing running: bars float"
            }
            if id == "yabai" || id == "aerospace" { tag = "experimental" }
            if id == "yabai" { note = "tiles with yabai" }
            if id == "aerospace" { note = "tiles with AeroSpace" }
            Chrome.option(g, b.x, y, width: width, label: Choices.wmLabels[i], selected: c.wm == i, focused: cursor == i, tag: tag, note: note)
            y += 1
        }
        y += 1
        let can: String
        switch c.wmID {
        case "auto", "omniwm": can = "can: workspace rail, and the bars keep the screen edges clear of windows"
        case "yabai", "aerospace": can = "can: workspace rail (experimental, not verified on every Mac)"
        case "command": can = "can: a workspace rail through your own scripts"
        default: can = "can: no workspace rail; bars float over windows"
        }
        g.put(b.x, y, can, Ink.dim, max: b.w)
    }

    func drawBars(_ g: Grid, _ b: Body) {
        var y = Chrome.title(g, b, "Bars", "The preset picks the bars and what sits on them.")
        let listW = min(b.w, 44)
        let presetNotes = ["top bar only", "top, bottom and left", "all four bars"]
        for p in Preset.allCases {
            Chrome.option(g, b.x, y, width: listW, label: p.label, selected: c.preset == p, focused: cursor == p.rawValue,
                          tag: p == .classic ? "recommended" : nil, note: presetNotes[p.rawValue])
            y += 1
        }
        y += 1
        drawToggle(g, b.x, y, label: "Cards", options: ["Flush", "Chat"], selected: c.cards.rawValue, focused: cursor == 3, width: listW)
        y += 1
        drawToggle(g, b.x, y, label: "Bars", options: ["Floating", "Hug", "as preset"],
                   selected: c.barMode == .preset ? 2 : (c.barMode == .floating ? 0 : 1), focused: cursor == 4, width: listW)
        y += 2
        g.put(b.x, y, c.cards == .chat ? "Chat: rounded cards joined to their pill." : "Flush: cards hang from the bar.", Ink.dim, max: listW)
        if b.w >= 72 {
            Chrome.schematic(g, b.x + listW + 4, b.y + 3, preset: c.preset, mode: c.barMode, cards: c.cards)
            let mode = c.barMode == .preset ? "bars as preset" : (c.barMode == .floating ? "floating bars" : "hug bars")
            g.put(b.x + listW + 4, b.y + 14, "\(c.preset.label) · \(mode)", Ink.dim, max: b.w - listW - 4)
            g.put(b.x + listW + 4, b.y + 15, "\(c.cards == .flush ? "flush" : "chat") cards", Ink.dim, max: b.w - listW - 4)
        } else {
            // Too narrow for the schematic: say which bars are on, in words.
            let on: [String] = c.preset == .minimal ? ["top"] : (c.preset == .classic ? ["top", "bottom", "left"] : ["top", "bottom", "left", "right"])
            g.put(b.x, y + 1, "bars on: " + on.joined(separator: ", "), Ink.dim, max: b.w)
        }
    }

    /// "Cards   ● Flush   ○ Chat": a row of radio options under one label.
    func drawToggle(_ g: Grid, _ x: Int, _ y: Int, label: String, options: [String], selected: Int, focused: Bool, width: Int) {
        g.put(x, y, label, focused ? Ink.bold : Ink.dim, max: 8)
        var cx = x + 9
        for (i, o) in options.enumerated() {
            let on = i == selected
            g.put(cx, y, on ? "●" : "○", on ? Ink.accentText : Ink.dim)
            cx += 2
            let st = on ? (focused ? Ink.bold : Ink.text) : Ink.dim
            cx += g.put(cx, y, o, st, max: width - (cx - x)) + 3
        }
    }

    func drawTheme(_ g: Grid, _ b: Body) {
        let schemes = schemeData
        let stacked = b.w < 72
        // The card sits below the title (rows 3 onwards): full if it fits, else compact, else no card.
        let room = b.h - 3
        let cardRows = room >= Chrome.cardFull + (stacked ? 2 : 0) ? Chrome.cardFull
            : (room >= Chrome.cardCompact + (stacked ? 2 : 0) ? Chrome.cardCompact : 0)
        let listRows = max(3, stacked && cardRows > 0 ? room - cardRows - 1 : room)
        Chrome.title(g, b, "Theme", "The preview uses each scheme's real colours.")
        let listW = stacked ? b.w : min(36, b.w)
        let first = Chrome.window(count: schemes.count, cursor: cursor, rows: listRows)
        var y = b.y + 3
        for i in first..<min(schemes.count, first + listRows) {
            let s = schemes[i]
            let tag: String? = s.isDefault ? "recommended" : nil
            Chrome.option(g, b.x, y, width: listW, label: s.name, selected: c.theme == i, focused: cursor == i, tag: tag, note: s.variant)
            y += 1
        }
        if first > 0 { g.put(b.x + listW - 2, b.y + 3, "↑", Ink.dim) }
        let s = schemes[min(cursor, schemes.count - 1)]
        if cardRows > 0 {
            if stacked {
                Chrome.themeCard(g, b.x, y + 1, width: min(b.w, 40), height: cardRows, scheme: s)
            } else {
                Chrome.themeCard(g, b.x + 40, b.y + 3, width: min(36, b.w - 40), height: cardRows, scheme: s)
            }
        }
    }

    func drawUsage(_ g: Grid, _ b: Body) {
        var y = Chrome.title(g, b, "Usage", "Both are off by default; each reads a login here.")
        let w = min(b.w, 76)
        Chrome.option(g, b.x, y, width: w, label: "Claude usage", selected: c.claude, focused: cursor == 0,
                      note: c.claude ? "on" : "off")
        Chrome.paragraph(g, b.x + 4, y + 1, width: w - 4, text: "reads Claude Code's login from your keychain; nothing leaves your Mac except the request to Anthropic")
        y += 4
        Chrome.option(g, b.x, y, width: w, label: "OpenCode usage", selected: c.opencodeOn, focused: cursor == 1,
                      note: c.opencodeOn ? "on" : "off")
        Chrome.paragraph(g, b.x + 4, y + 1, width: w - 4, text: "reads the console of your OpenCode workspace from a browser profile on this Mac")
        y += 4
        if c.opencodeOn {
            drawField(g, b.x + 2, y, label: "workspace", value: maskedWorkspace(), focused: cursor == 2, width: w)
            y += 1
            drawField(g, b.x + 2, y, label: "profiles", value: c.profiles, focused: cursor == 3, width: w)
            y += 2
        }
    }

    /// The workspace id is never shown in full on screen: the first four characters, then dots.
    func maskedWorkspace() -> String {
        if c.workspace.isEmpty { return "wrk_…" }
        let head = String(c.workspace.prefix(4))
        return head + String(repeating: "•", count: max(0, c.workspace.count - 4))
    }

    func drawField(_ g: Grid, _ x: Int, _ y: Int, label: String, value: String, focused: Bool, width: Int) {
        g.put(x, y, label, Ink.dim, max: 11)
        g.put(x + 12, y, "›", focused ? Ink.accentText : Ink.dim)
        g.put(x + 14, y, value, Ink.text, max: width - 14)
        if focused { g.put(x + 14 + min(value.count, width - 15), y, "▏", Ink.accentText) }
    }

    func drawGestures(_ g: Grid, _ b: Body) {
        var y = Chrome.title(g, b, "Three-finger gestures", "Who handles swipes between spaces and the overview.")
        let w = min(b.w, 76)
        Chrome.option(g, b.x, y, width: w, label: "System", selected: !c.gesturesRiskell, focused: cursor == 0,
                      tag: "default", note: "macOS handles the gestures")
        y += 1
        Chrome.option(g, b.x, y, width: w, label: "riskell", selected: c.gesturesRiskell, focused: cursor == 1,
                      note: "riskell's own swipe and overview")
        y += 2
        guard c.gesturesRiskell else {
            Chrome.paragraph(g, b.x, y, width: b.w, text: "Off means nothing runs. Accessibility is needed only for riskell's own gestures.")
            return
        }
        g.put(b.x, y, "Conflicts with macOS settings", Ink.dim)
        y += 1
        let found = conflicts ?? []
        if found.isEmpty {
            g.put(b.x, y, "✓", Ink.ok)
            g.put(b.x + 2, y, "none found", Ink.dim)
        } else {
            for f in found.prefix(5) {
                g.put(b.x, y, "!", Ink.accentText)
                g.put(b.x + 2, y, f, Ink.text, max: b.w - 2)
                y += 1
            }
        }
        y += 1
        Chrome.option(g, b.x, y, width: w, label: "Turn them off for me", selected: c.gesturesFix, focused: cursor == 2)
        g.put(b.x + 4, y + 1, "saves your originals; undo with riskell --gestures-restore", Ink.dim, max: w - 4)
    }

    func drawScale(_ g: Grid, _ b: Body) {
        var y = Chrome.title(g, b, "Scale", "Auto fits the bars to each screen's notch or menu bar.")
        let w = min(b.w, 70)
        Chrome.option(g, b.x, y, width: w, label: "Auto", selected: c.scale == nil, focused: cursor == 0,
                      tag: "recommended", note: "matches your screen")
        y += 1
        let value = c.scale ?? 1.0
        Chrome.option(g, b.x, y, width: w, label: "Custom", selected: c.scale != nil, focused: cursor == 1,
                      note: "0.5 to 2.0, steps of 0.05")
        if c.scale != nil || cursor == 1 {
            y += 2
            let frac = (value - 0.5) / 1.5
            let cells = 24
            let filled = Int((frac * Double(cells)).rounded())
            g.put(b.x + 4, y, String(format: "%.2f", value), Ink.accentText)
            var bar = ""
            for i in 0..<cells { bar += i < filled ? "█" : "▁" }
            g.put(b.x + 12, y, bar, Ink.text, max: b.w - 12)
            g.put(b.x + 12, y + 1, "0.50", Ink.dim)
            g.putRight(b.x + 12 + cells, y + 1, "2.00", Ink.dim)
        }
        y += 3
        g.put(b.x, y, "Fine-tune spacing later with ctrl-alt-, in the layout editor.", Ink.dim, max: b.w)
    }
}
