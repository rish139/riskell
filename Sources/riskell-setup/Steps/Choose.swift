import Foundation
import RiskellTTY

/// The option screens: window manager, bars, theme, usage, gestures and scale. Each is a section and a list of kit option rows.
extension App {
    func wmLines(_ tty: Tty) -> [String] {
        var out = section(tty, "window manager")
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
            out += tty.option(Choices.wmLabels[i], detail: note, selected: c.wm == i, focused: cursor == i, tag: tag)
        }
        let can: String
        switch c.wmID {
        case "auto", "omniwm": can = "can: workspace rail, and the bars keep the screen edges clear of windows"
        case "yabai", "aerospace": can = "can: workspace rail (experimental, not verified on every Mac)"
        case "command": can = "can: a workspace rail through your own scripts"
        default: can = "can: no workspace rail; bars float over windows"
        }
        out.append("")
        out += tty.paragraph(can)
        return out
    }

    func barsLines(_ tty: Tty) -> [String] {
        var out = section(tty, "bars")
        let notes = ["top bar only", "top, bottom and left", "all four bars"]
        for p in Preset.allCases {
            out += tty.option(p.label, selected: c.preset == p, focused: cursor == p.rawValue,
                              tag: p == .classic ? "recommended, \(notes[p.rawValue])" : notes[p.rawValue])
        }
        out += section(tty, "cards")
        out += tty.option("Flush", detail: "cards hang from the bar", selected: c.cards == .flush, focused: cursor == 3)
        out += tty.option("Chat", detail: "rounded cards joined to their pill", selected: c.cards == .chat, focused: cursor == 3)
        out += section(tty, "bar style")
        let mode = c.barMode == .preset ? 2 : (c.barMode == .floating ? 0 : 1)
        out += tty.option("Floating", detail: "separate pills", selected: mode == 0, focused: cursor == 4)
        out += tty.option("Hug", detail: "one band on each edge", selected: mode == 1, focused: cursor == 4)
        out += tty.option("As preset", detail: "riskell's own mix", selected: mode == 2, focused: cursor == 4)
        return out
    }

    func themeLines(_ tty: Tty, height: Int) -> [String] {
        let schemes = schemeData
        var out = section(tty, "theme")
        let rows = max(3, height - 3)
        let first = schemes.count > rows ? min(max(0, cursor - rows / 2), schemes.count - rows) : 0
        for i in first..<min(schemes.count, first + rows) {
            let s = schemes[i]
            out += tty.option(s.name, selected: c.theme == i, focused: cursor == i,
                              tag: s.isDefault ? "recommended" : s.variant)
        }
        if first > 0 { out += tty.paragraph("more schemes above") }
        if first + rows < schemes.count { out += tty.paragraph("more schemes below") }
        return out
    }

    func usageLines(_ tty: Tty) -> [String] {
        if let pending = consent { return consentLines(tty, pending) }
        var out = section(tty, "usage")
        out += tty.option("Claude Code usage", detail: "from its local logs; no credentials, no network",
                          selected: c.claude, focused: cursor == 0, tag: c.claude ? "on" : "off")
        out += tty.option("Claude plan limits", detail: "reads the keychain token; unofficial, asks first",
                          selected: c.claudeLimits, focused: cursor == 1,
                          tag: c.claude ? (c.claudeLimits ? "on" : "off") : "needs Claude usage")
        out += tty.option("OpenCode Go usage", detail: "reads an opencode.ai browser cookie; asks first",
                          selected: c.opencodeOn, focused: cursor == 2, tag: c.opencodeOn ? "on" : "off")
        if c.opencodeOn {
            out.append(tty.field("workspace", value: maskedWorkspace(), focused: cursor == 3, placeholder: "wrk_…"))
            out.append(tty.field("profiles", value: c.profiles, focused: cursor == 4))
        }
        return out
    }

    /// What the source reads and sends, said before the user can turn it on. Only y accepts (App.usageKey).
    func consentLines(_ tty: Tty, _ which: UsageConsent) -> [String] {
        let title: String, text: String
        switch which {
        case .limits:
            title = "Claude plan limits"
            text = "riskell reads the Claude Code login token from your login keychain and sends it to Anthropic's usage endpoint, to ask for "
                + "your plan's limits. Nothing else is read or sent. This is unofficial: Anthropic's terms do not allow using that token in "
                + "other tools, so your account could be restricted."
        case .opencode:
            title = "OpenCode Go usage"
            text = "riskell reads the opencode.ai session cookie from the browser profile folder (Zen by default) and sends it to "
                + "opencode.ai's console, to read your workspace's usage. Nothing else is read or sent. The console is not a published "
                + "API, so this can stop working when the site changes."
        }
        var out = section(tty, title)
        out += tty.paragraph(text)
        out.append("")
        out += tty.paragraph("Press y to turn it on. Any other key leaves it off.")
        return out
    }

    /// The workspace id is never shown in full on screen: the first four characters, then dots.
    func maskedWorkspace() -> String {
        if c.workspace.isEmpty { return "wrk_…" }
        let head = String(c.workspace.prefix(4))
        return head + String(repeating: ".", count: max(0, c.workspace.count - 4))
    }

    func gesturesLines(_ tty: Tty) -> [String] {
        var out = section(tty, "three-finger gestures")
        out += tty.option("System", detail: "macOS handles the gestures", selected: !c.gesturesRiskell,
                          focused: cursor == 0, tag: "default")
        out += tty.option("riskell", detail: "riskell's own swipe and overview", selected: c.gesturesRiskell, focused: cursor == 1)
        guard c.gesturesRiskell else {
            out.append("")
            out += tty.paragraph("Off means nothing runs. Accessibility is needed only for riskell's own gestures.")
            return out
        }
        out += section(tty, "conflicts with macOS settings")
        let found = conflicts ?? []
        if found.isEmpty {
            out += tty.checks([(.ok, "conflicts", "none found", nil)])
        } else {
            out += tty.checks(found.prefix(5).map { (.warn, "conflicts", $0, nil) })
        }
        out += tty.option("Turn them off for me", detail: "saves your originals; undo with riskell --gestures-restore",
                          selected: c.gesturesFix, focused: cursor == 2)
        return out
    }

    func scaleLines(_ tty: Tty) -> [String] {
        var out = section(tty, "scale")
        out += tty.option("Auto", detail: "matches your screen", selected: c.scale == nil,
                          focused: cursor == 0, tag: "recommended")
        out += tty.option("Custom", detail: "0.5 to 2.0, steps of 0.05", selected: c.scale != nil, focused: cursor == 1)
        if c.scale != nil || cursor == 1 {
            out.append(tty.field("scale", value: String(format: "%.2f", c.scale ?? 1.0), focused: cursor == 1))
        }
        out.append("")
        out += tty.paragraph("Fine-tune spacing later with ctrl-alt-, in riskell preferences.")
        return out
    }
}
