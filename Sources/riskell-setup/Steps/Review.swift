import Foundation
import RiskellTTY

/// The review: the answers as checks, what will be written as a plan, and the actions as option rows. The diff shows the same
/// plan line by line.
extension App {
    func wmSummary() -> String {
        if c.wmID == "auto", let d = facts.detectedWM { return "auto (\(d))" }
        if c.isAerospace { return "AeroSpace, gaps \(c.aerospaceGaps == "manual" ? "by you" : "by riskell")" }
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

    /// What is on, with what each one reads. Short: the review's cells are narrow at 60 columns.
    func usageSummary() -> String {
        var parts: [String] = []
        if c.claude && !c.claudeLimits { parts.append("Claude, local logs") }
        if c.claudeLimits { parts.append("Claude: reads the keychain") }
        if c.opencodeOn { parts.append("OpenCode: reads a browser cookie") }
        return parts.isEmpty ? "off" : parts.joined(separator: "; ")
    }

    func reviewLines(_ tty: Tty, height: Int) -> [String] {
        var out = section(tty, "review")
        var answers: [(Tone, String, String, (cmd: String, note: String?)?)] = [
            (.ok, "window", wmSummary(), nil),
            (.ok, "bars", barsSummary(), nil),
            (.ok, "theme", c.themeData.name, nil),
            (.ok, "weather", c.weather?.name ?? "off", nil),
            (.ok, "usage", usageSummary(), nil),
            (.ok, "gestures", c.gesturesRiskell ? (c.gesturesFix ? "riskell, conflicts off" : "riskell") : "system", nil),
            (.ok, "scale", c.scale.map { String(format: "%.2f", $0) } ?? "auto", nil),
        ]
        if c.isAerospace { answers.insert((.ok, "aerospace", Choices.aerospaceGapsNote(c.aerospaceGaps), nil), at: 1) }
        out += tty.checks(answers)
        out += section(tty, "what will happen")
        var planLines = tty.plan(reviewPlanRows(), note: "")
        while planLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { planLines.removeLast() }
        out += planLines
        if out.count < height - 4 { out.append("") }
        // Actions, in the order Review's cursor moves over them.
        var row = 0
        if facts.layoutFound {
            out += tty.option("Replace my layout", selected: c.replaceLayout, focused: cursor == 0,
                              tag: c.replaceLayout ? "replaced with \(c.preset.label)" : "keep yours")
            row = 1
        }
        let actions = ["install", "show what would change", "back"]
        for (i, action) in actions.enumerated() {
            out += tty.option(action, selected: cursor == row + i, focused: cursor == row + i)
        }
        return out
    }

    /// The three things Install will do, in the plan's own shape. The diff screen has every key.
    func reviewPlanRows() -> [(verb: String, text: String, satisfied: Bool)] {
        let p = plan()
        let config = facts.configFound ? "merge config.json, backup first" : "write a new config.json"
        let layout = p.layoutText == nil ? "layout.json as it is" : "the \(c.preset.label) layout.json"
        var launch = p.noLaunch ? "keep the launch agent (--no-launch)" : "start the launch agent \(facts.agentLabel)"
        if p.addPath { launch += ", add \(Detect.linkDir(paths).dir.path.replacingOccurrences(of: paths.home.path, with: "~")) to PATH" }
        if p.gesturesFix { launch += ", turn off the conflicting gestures" }
        return [
            (verb: "write", text: config, satisfied: false),
            (verb: p.layoutText == nil ? "kept" : "write", text: layout, satisfied: p.layoutText == nil),
            (verb: p.noLaunch ? "kept" : "start", text: launch, satisfied: p.noLaunch),
        ]
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

    /// The diff's rows in the plan's shape: a symbol becomes a verb, and a kept row says so.
    func changePlanRows() -> [(verb: String, text: String, satisfied: Bool)] {
        changeLines().map { key, value in
            let name = String(key.dropFirst(2))
            if key.hasPrefix("=") { return (verb: "kept", text: "\(name): \(value)", satisfied: true) }
            let verb: String
            if key.hasPrefix("+") { verb = "add" } else if key.hasPrefix("-") { verb = "remove" } else { verb = "change" }
            return (verb: verb, text: "\(name): \(value)", satisfied: false)
        }
    }

    func diffLines(_ tty: Tty) -> [String] {
        var out = section(tty, "what would change")
        out += tty.plan(changePlanRows(), note: "Nothing is written from this screen; enter or esc goes back to the review.")
        return out
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
