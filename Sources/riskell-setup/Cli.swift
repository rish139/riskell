import Foundation
import RiskellTTY

enum Mode: Equatable {
    case tui, yes, check, doctor, uninstall, version, help, selfTest, snapshot, snapshotDir
}

/// Every flag, parsed once. Unknown flags are reported, never ignored silently.
struct Options: Equatable {
    var mode: Mode = .tui
    var repo: String?
    var noBuild = false
    var noLaunch = false
    var noPath = false
    var dryRun = false
    var yes = false
    var wm: String?
    var theme: String?
    var bars: String?
    var cards: String?
    var city: String?
    var gestures: String?
    var aerospaceGaps: String?
    var claude = false
    var claudeLimits = false
    var opencodeWorkspace: String?
    var opencodeProfiles: String?
    var scale: String?
    var replaceLayout = false
    var removeConfig = false
    var restoreGestures = false
    var json = false
    var all = false
    var bundle: String?
    var snapshotName: String?
    var snapshotDirPath: String?
    var width = 100
    var height = 32
    var ansi = false
    var errors: [String] = []

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        func value(_ flag: String) -> String? {
            i += 1
            if i < args.count { return args[i] }
            o.errors.append("\(flag) needs a value")
            return nil
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--help", "-h": o.mode = .help
            case "--version": o.mode = .version
            case "--self-test": o.mode = .selfTest
            case "--yes", "-y": o.yes = true; if o.mode == .tui { o.mode = .yes }
            case "--dry-run": o.dryRun = true
            case "--check": o.mode = .check
            case "--doctor": o.mode = .doctor
            case "--json": o.json = true
            case "--all": o.all = true
            case "--bundle": o.bundle = value(a)
            case "--uninstall": o.mode = .uninstall
            case "--no-build": o.noBuild = true
            case "--no-launch": o.noLaunch = true
            case "--no-path": o.noPath = true
            case "--claude": o.claude = true
            case "--claude-limits": o.claude = true; o.claudeLimits = true
            case "--opencode-workspace": o.opencodeWorkspace = value(a)
            case "--opencode-profiles": o.opencodeProfiles = value(a)
            case "--replace-layout": o.replaceLayout = true
            case "--remove-config": o.removeConfig = true
            case "--restore-gestures": o.restoreGestures = true
            case "--ansi": o.ansi = true
            case "--repo": o.repo = value(a)
            case "--wm": o.wm = value(a)
            case "--theme": o.theme = value(a)
            case "--bars": o.bars = value(a)
            case "--cards": o.cards = value(a)
            case "--city": o.city = value(a)
            case "--gestures": o.gestures = value(a)
            case "--aerospace-gaps": o.aerospaceGaps = value(a)
            case "--scale": o.scale = value(a)
            case "--snapshot":
                o.mode = .snapshot
                o.snapshotName = value(a)
            case "--snapshot-dir":
                o.mode = .snapshotDir
                o.snapshotDirPath = value(a)
            case "--size":
                if let v = value(a) {
                    let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { o.width = parts[0]; o.height = parts[1] } else { o.errors.append("--size wants WxH, like 80x24") }
                }
            default:
                o.errors.append("unknown option \(a)")
            }
            i += 1
        }
        if o.mode == .yes, o.dryRun { o.mode = .yes }
        if (o.json || o.bundle != nil), o.mode != .check, o.mode != .doctor {
            o.errors.append("--json and --bundle go with --check or --doctor")
        }
        return o
    }

    /// `--help`: the guided flow in one line, then every flag in the group a reader meets it in, drawn with the kit. Nothing here is a
    /// setting of its own: the groups are the questions `--yes` would have asked, and the reports are read-only.
    static func help(_ tty: Tty) -> [String] {
        var out = [tty.header("setup", detail: "the guided installer for riskell"), ""]
        out += tty.detail(usage: "riskell-setup [options]", summary: "With no options it opens the guided terminal flow, which needs a terminal; each option below answers one of its questions.",
                          fields: [], children: [])
        out += [""]
        out += tty.stackedList([
            (title: "without questions", rows: [
                ("--yes", "take the detected defaults and install: no questions, and every usage source stays off unless a flag below turns it on"),
                ("--dry-run", "print the plan and the JSON that would be written; write nothing"),
            ]),
            (title: "reports", rows: [
                ("--check", "the installer's checklist: the preflight, then the agent, the socket and the log"),
                ("--doctor", "the health report: build, system, install, files, running app, window manager, permissions, gestures, log, verdict"),
                ("--all", "with --doctor: every row with its detail, instead of one line per section"),
                ("--json", "with --check or --doctor: one JSON object on stdout and nothing else"),
                ("--bundle", "DIR: with --check or --doctor, also write a redacted report (the JSON and the last 200 log lines) to DIR as one tar.gz"),
            ]),
            (title: "answers (with --yes)", rows: [
                ("--wm", "auto, omniwm, yabai, aerospace, command or none: the window manager to set up"),
                ("--theme", "ID: a scheme id from installer/themes.json"),
                ("--bars", "minimal, classic or full: the layout to write"),
                ("--cards", "flush or chat: how a card sits against the bar"),
                ("--city", "\"Name\": the place the weather card shows, looked up once; the first match is used"),
                ("--aerospace-gaps", "riskell or manual: with AeroSpace, who sets its outer gaps in aerospace.toml (default riskell)"),
                ("--gestures", "riskell or system: who owns the three and four-finger gestures"),
                ("--claude", "Claude Code usage on, from its local logs: no credentials, no network"),
                ("--claude-limits", "also the real plan limits: reads the keychain login token and asks Anthropic (unofficial, may breach its terms); implies --claude, and this flag is the consent"),
                ("--opencode-workspace", "wrk_...: OpenCode Go usage, which reads an opencode.ai browser cookie; this flag is the consent"),
                ("--opencode-profiles", "DIR: the browser profiles folder for OpenCode (default: Zen's)"),
                ("--scale", "N or auto: a number from 0.5 to 2.0"),
                ("--replace-layout", "replace an existing layout.json"),
            ]),
            (title: "other", rows: [
                ("--repo", "PATH: the riskell checkout (found automatically when omitted)"),
                ("--no-build", "do not build riskell"),
                ("--no-launch", "do not start the launch agent or link risk"),
                ("--no-path", "do not add the folder of the risk link to PATH in your shell start-up files"),
                ("--uninstall", "stop riskell and remove its agent, its risk link and its PATH block (asks, or --yes)"),
                ("--remove-config", "with --uninstall: also remove ~/.config/riskell"),
                ("--restore-gestures", "with --uninstall: restore the trackpad gestures too"),
                ("--version", "print the installer's version"),
                ("--help", "this page"),
            ]),
        ])
        out.append("")
        out += tty.paragraph("Nothing is written before the final confirm. Docs: docs/INSTALL.md")
        return out
    }
}
