// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `riskell-ext gallery`: every screen the kit draws, side by side, from fixed data.
///
/// The screens a `risk` command prints are the kit's (Sources/RiskellTTY/Screens.swift and Lists.swift): this command is how they are looked at and
/// recorded. Nothing here reads the clock, a process or a file, and the palette is the Gruvbox dark tokens as data, so the same build prints
/// the same bytes on every machine and in every theme. `Tests/cli/golden/gallery-*.txt` are the recordings.
///
///   risk gallery                     every screen, in the terminal's own colour mode
///   risk gallery --plain             no colour at all: what a pipe or NO_COLOR gets
///   risk gallery --ascii             the plain glyph set (+, x, -, ||, _), for a terminal that cannot show more
///   risk gallery --color             truecolor even down a pipe, so the recording does not depend on TERM
///   risk gallery --width N           lay the screens out for a terminal N columns wide
enum Gallery {
    /// One check as a screen keeps it: the tone, the key, the value, and the command that would fix it.
    typealias Row = (Tone, String, String, (cmd: String, note: String?)?)

    /// The Gruvbox dark tokens, as the app resolves them. Data, not a lookup: the gallery may not depend on the theme in force.
    private static let tokens = [
        "bg": "#282828", "tile": "#3c3836", "canvas": "#1d2021", "text1": "#ebdbb2", "text2": "#d5c4a1", "text3": "#bdae93",
        "text4": "#928374", "accent": "#fabd2f", "ok": "#b8bb26", "warn": "#fe8019", "crit": "#fb4934", "info": "#83a598",
        "critInk": "#ff6b55", "prov": "#d3869b", "amberDim": "#91722c",
    ]

    static func run(_ args: [String]) -> Int32 {
        var ascii = false, plain = false, color = false, width: Int?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--ascii": ascii = true
            case "--plain": plain = true
            case "--color": color = true
            case "--width":
                guard i + 1 < args.count, let w = Int(args[i + 1]), w > 0 else { return usage("--width needs a number of columns") }
                width = w
                i += 1
            default: return usage("unknown flag \"\(args[i])\"")
            }
            i += 1
        }
        let palette = Palette(hex: tokens)
        let detected = Tty.detect(palette: palette)
        let tty = Tty(mode: plain ? .none : (color ? .truecolor : detected.mode), width: width ?? detected.width,
                      palette: palette, glyphs: ascii ? .ascii : detected.glyphs)
        print(screens(tty).joined(separator: "\n"))
        return 0
    }

    private static func usage(_ why: String) -> Int32 {
        Usage.error("gallery", why)
    }

    /// The screens, each under a dim name, one blank line apart.
    private static func screens(_ tty: Tty) -> [String] {
        var out: [String] = []
        for (name, body) in [("status", compact(tty)), ("status-all", status(tty)), ("status-failing", failing(tty)), ("error", failure(tty)),
                             ("narrow", narrow(tty)), ("help", help(tty)), ("help-command", helpCommand(tty)),
                             ("table", table(tty)), ("log", log(tty)), ("plan", plan(tty)), ("empty", empty(tty)),
                             ("progress", progress(tty))] {
            if !out.isEmpty { out.append("") }
            let label = String(repeating: tty.glyphs.ruleChar, count: 2) + " \(name) " + String(repeating: tty.glyphs.ruleChar, count: 2)
            out.append("  " + tty.tone(label, .text4))
            out += body
        }
        return out
    }

    /// `risk status`, the screen you get by default: a line per section with each check's name in its tone, detail only for what needs
    /// attention, then the summary and the one command to run. The full list is `status --all`, drawn by `status` below.
    private static func compact(_ tty: Tty) -> [String] {
        let sections: [(String, [Row])] = [
            ("build", [(.ok, "binary", "", nil), (.ok, "app bundle", "", nil),
                       (.warn, "freshness", "a source file is newer than the binary", (cmd: "risk dev", note: "rebuild and restart")),
                       (.ok, "version", "", nil)]),
            ("system", [(.ok, "macOS", "", nil), (.ok, "chip", "", nil), (.ok, "swift", "", nil), (.ok, "Spaces", "", nil),
                        (.ok, "signing", "", nil), (.ok, "verified", "", nil)]),
            ("install", [(.ok, "launch agent", "", nil), (.ok, "agent plist", "", nil), (.ok, "risk link", "", nil), (.ok, "PATH", "", nil)]),
            ("running app", [(.ok, "socket", "", nil), (.ok, "process", "", nil), (.ok, "services", "", nil), (.ok, "atoms", "", nil)]),
            ("window manager", [(.ok, "manager", "", nil), (.ok, "subscription", "", nil), (.ok, "protocol", "", nil),
                                (.ok, "settings", "", nil), (.ok, "gaps", "", nil)]),
            ("permissions", [(.ok, "accessibility", "", nil), (.ok, "location", "", nil)]),
        ]
        let titleWidth = (sections.map { $0.0.count }.max() ?? 0) + 2
        var out = tty.masthead(version: "0.2.1", lines: ["macOS 27.2 · Apple silicon · OmniWM"], state: .running("running · pid 67123 · up 3d 4h"))
        out.append("")
        for (title, rows) in sections { out += tty.keyLine(title, titleWidth: titleWidth, keys: rows.map { (tone: $0.0, key: $0.1) }) }
        let problems = sections.flatMap { $0.1 }.filter { $0.0 == .warn || $0.0 == .crit }
        if !problems.isEmpty { out += [""] + tty.checks(problems.map { ($0.0, $0.1, $0.2, $0.3) }) }
        let all = sections.flatMap { $0.1 }
        out += ["", "  " + tty.summary(ok: all.filter { $0.0 == .ok }.count, warn: problems.count, crit: 0), ""]
        out.append(tty.next(cmd: "risk dev", why: "a rebuild clears the one warning"))
        out.append(tty.footerHint([(cmd: "risk status --all", text: "every check, with its detail")]))
        return out
    }

    /// `risk status --all`: everything fine but one warning, every check with its value.
    private static func status(_ tty: Tty) -> [String] {
        let build: [Row] = [
            (.ok, "binary", "built · 0.2.1 · current", nil),
            (.ok, "app bundle", "up to date with the release binary", nil),
            (.warn, "freshness", "a source file is newer than the binary", (cmd: "risk dev", note: "rebuild and restart")),
        ]
        let system: [Row] = [
            (.ok, "macOS", "27.2 · the version riskell was verified against", nil),
            (.ok, "signing", "riskell-dev identity present: grants survive a rebuild", nil),
            (.ok, "Spaces", "one Space on the main display", nil),
        ]
        let app: [Row] = [
            (.ok, "socket", "~/.cache/riskell/ev.sock answers", nil),
            (.ok, "atoms", "11 on top, bottom, left · none need a service", nil),
            (.ok, "window manager", "OmniWM · subscribed, state reaches the bars live", nil),
            (.ok, "gestures", "nothing conflicts", nil),
        ]
        let keyWidth = width(of: build + system + app)
        var out = tty.masthead(version: "0.2.1", lines: ["macOS 27.2 · Apple silicon · OmniWM"],
                               state: .running("running · pid 67123 · up 3d 4h"))
        out += section(tty, "build") + draw(tty, build, keyWidth)
        out += section(tty, "system") + draw(tty, system, keyWidth)
        out += section(tty, "running app") + draw(tty, app, keyWidth)
        out += ["", "  " + tty.summary(ok: 9, warn: 1, crit: 0), ""]
        out.append(tty.next(cmd: "risk dev", why: "a rebuild clears the one warning"))
        return out
    }

    /// `risk status` when the bar is down: a failure, a warning, and what to do now.
    private static func failing(_ tty: Tty) -> [String] {
        let build: [Row] = [
            (.ok, "binary", "built · 0.2.1 · current", nil),
            (.crit, "app bundle", "the bundle is older than the binary", (cmd: "risk dev", note: "rebuild and restart")),
            (.warn, "freshness", "a source file is newer than the binary", (cmd: "risk dev", note: "rebuild and restart")),
        ]
        let system: [Row] = [
            (.ok, "macOS", "27.2 · the version riskell was verified against", nil),
            (.ok, "signing", "riskell-dev identity present: grants survive a rebuild", nil),
            (.ok, "Spaces", "one Space on the main display", nil),
        ]
        let app: [Row] = [
            (.crit, "socket", "~/.cache/riskell/ev.sock does not answer", (cmd: "risk dev", note: "start it from this checkout")),
            (.ok, "atoms", "11 on top, bottom, left · none need a service", nil),
            (.ok, "window manager", "OmniWM · subscribed, state reaches the bars live", nil),
            (.ok, "gestures", "nothing conflicts", nil),
        ]
        let keyWidth = width(of: build + system + app)
        var out = tty.masthead(version: "0.2.1", lines: ["macOS 27.2 · Apple silicon · OmniWM"], state: .stopped("stopped"))
        out += section(tty, "build") + draw(tty, build, keyWidth)
        out += section(tty, "system") + draw(tty, system, keyWidth)
        out += section(tty, "running app") + draw(tty, app, keyWidth)
        out += ["", "  " + tty.summary(ok: 7, warn: 1, crit: 2), ""]
        out.append(tty.next(cmd: "risk dev", why: "a rebuild brings the bar back"))
        return out
    }

    /// One failed command: the same shape for all of them.
    private static func failure(_ tty: Tty) -> [String] {
        tty.errorBlock(title: "riskell is not running", detail: "the bar's socket does not answer: ~/.cache/riskell/ev.sock",
                       tries: [(cmd: "risk dev", note: "start it from this checkout"),
                               (cmd: "risk status", note: "see what else is off")])
    }

    /// `risk help`: what the machine is, then the four groups of the user CLI, then the two ways to read more.
    private static func help(_ tty: Tty) -> [String] {
        let groups: [(title: String, rows: [(name: String, text: String)])] = [
            ("RUN", [("install", "build, then start riskell now and at login"),
                     ("dev", "rebuild and restart the running agent"),
                     ("setup", "the guided installer"),
                     ("uninstall", "stop riskell and remove its login agent")]),
            ("LOOK", [("status", "health, with the first thing to fix named"),
                      ("log", "the last lines of the log, or follow it")]),
            ("CHANGE", [("config", "read and change settings without editing JSON"),
                        ("ctl", "send one word to the running bar"),
                        ("gestures", "turn off the trackpad keys that fight riskell")]),
            ("EXTEND", [("ext", "add, update, remove, validate and publish extensions")]),
        ]
        var out = tty.masthead(version: "0.2.1", lines: ["a desktop shell for macOS: bars, cards and extensions"],
                               state: .running("running · pid 67123"))
        out.append("")
        out += tty.commandList(groups)
        out.append("")
        out.append(tty.footerHint([(cmd: "risk help <command>", text: "for one"), (cmd: "docs/CLI.md", text: "for all")]))
        return out
    }

    /// `risk help status`: one command in full, with no tier line.
    private static func helpCommand(_ tty: Tty) -> [String] {
        tty.detail(usage: "status [--json]", summary: "health, with the first thing to fix named",
                   fields: [("aliases", ["st"]),
                            ("example", ["risk status --json"]),
                            ("exit", ["0 when everything is fine", "1 when a check failed"])],
                   children: [])
    }

    /// `risk ext list`: one row per extension, the dot saying whether it runs.
    private static func table(_ tty: Tty) -> [String] {
        let rows: [(Tone, String, String, String, String)] = [
            (.ok, "load", "reading", "0.3.1", "load average, with a hover card"),
            (.ok, "gh-notify", "pill", "1.0.0", "unread GitHub notifications"),
            (.note, "nord-night", "theme", "0.2.0", "a quiet blue-grey scheme (disabled)"),
        ]
        let columns = [Column(priority: 4), Column(priority: 3), Column(priority: 2), Column(priority: 1)]
        let body = rows.map { row in
            [tty.statusDot(row.0), Cell(row.1, .left, Style(fg: tty.palette.color(.text1, tty.mode), bold: true)),
             Cell(row.2, .left, Style(fg: tty.palette.color(.info, tty.mode))),
             Cell(row.3, .left, Style(fg: tty.palette.color(.text4, tty.mode))),
             Cell(row.4, .left, Style(fg: tty.palette.color(.text3, tty.mode)))]
        }
        return tty.table(title: "extensions", meta: "3 installed", columns: columns, rows: body)
    }

    /// `risk log`: the last lines, under the same title and rule as a table.
    private static func log(_ tty: Tty) -> [String] {
        tty.tableHead(title: "log", meta: "last 5 · --follow") + [
            tty.logLine(time: "12:04:11", level: .info, source: "overview", message: "opened on workspace 3"),
            tty.logLine(time: "12:04:12", level: .info, source: "touch", message: "frames arriving, 3 fingers down"),
            tty.logLine(time: "12:04:19", level: .warn, source: "touch", message: "no frame for 2 s, reattaching"),
            tty.logLine(time: "12:04:30", level: .error, source: "weather", message: "fetch failed (offline); retry in 600 s"),
            tty.logLine(time: "12:04:31", level: .info, source: "weather", message: "serving the cached forecast"),
        ]
    }

    /// `risk gestures fix --dry-run`: what would happen, one step that has already happened, and what was not written.
    private static func plan(_ tty: Tty) -> [String] {
        tty.plan([
            (verb: "save", text: "the trackpad keys as they are now", satisfied: false),
            (verb: "turn off", text: "the four keys that fight riskell", satisfied: false),
            (verb: "back up", text: "the originals to ~/.config/riskell/gesture-backup.json", satisfied: true),
            (verb: "restart", text: "the trackpad agent, so the keys take effect", satisfied: false),
        ], note: "dry run, nothing written; add --yes to write")
    }

    /// `risk ext list` on a machine with nothing installed.
    private static func empty(_ tty: Tty) -> [String] {
        tty.empty("no extensions installed", hint: (cmd: "risk ext add <name>", text: "to install one"))
    }

    /// `risk ext add` with no terminal to animate on: three finished steps and the summary, and a clock of the screen's own, so the
    /// recording never moves.
    private static func progress(_ tty: Tty) -> [String] {
        var clock = 0.0
        var out = ""
        let progress = Progress(tty: tty, steps: ["download", "build", "install"], now: { clock }, write: { out += $0 })
        progress.begin(0)
        clock += 3.2
        progress.finish(0, .ok, detail: "clock 0.3.1")
        progress.begin(1)
        clock += 0.4
        progress.finish(1, .ok, detail: "clock 0.3.1")
        progress.begin(2)
        clock += 1.1
        progress.finish(2, .ok, detail: "~/.config/riskell/extensions.json")
        progress.done(summary: "3 steps, 4.7 s")
        out = out.hasSuffix("\n") ? String(out.dropLast()) : out
        return out.components(separatedBy: "\n")
    }

    /// The first screen in a 44-column window: the logo is dropped and the values wrap, so the narrow case is looked at, not hoped for.
    private static func narrow(_ tty: Tty) -> [String] {
        let narrow = Tty(mode: tty.mode, width: 46, palette: tty.palette, glyphs: tty.glyphs)
        let build: [Row] = [
            (.ok, "binary", "built · 0.2.1 · current", nil),
            (.ok, "app bundle", "up to date with the release binary", nil),
            (.warn, "freshness", "a source file is newer than the binary", (cmd: "risk dev", note: "rebuild and restart")),
        ]
        var out = narrow.masthead(version: "0.2.1", lines: ["macOS 27.2 · Apple silicon · OmniWM"], state: .running("running"))
        out += section(narrow, "build") + draw(narrow, build, width(of: build))
        return out
    }

    /// A section heading, with the blank line the screen keeps above it.
    private static func section(_ tty: Tty, _ title: String) -> [String] {
        ["", "  " + tty.section(title)]
    }

    /// The keys are one column wide on a screen, not on a section: the longest key plus one, measured over every row of that screen, so
    /// the sections line up with each other the way the design draws them.
    private static func width(of rows: [Row]) -> Int {
        (rows.map(\.1.count).max() ?? 0) + 1
    }

    private static func draw(_ tty: Tty, _ rows: [Row], _ keyWidth: Int) -> [String] {
        rows.flatMap { tty.check($0.0, $0.1, $0.2, hint: $0.3, keyWidth: keyWidth) }
    }
}
