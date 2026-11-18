import Foundation

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
    var claude = false
    var claudeLimits = false
    var opencodeWorkspace: String?
    var opencodeProfiles: String?
    var scale: String?
    var replaceLayout = false
    var removeConfig = false
    var restoreGestures = false
    var json = false
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

    static let usage = """
    riskell-setup: the guided installer for riskell.

    usage: riskell-setup [options]

      (no options)            the guided terminal flow (needs a terminal)
      --yes                   no questions: detected defaults, plus the flags below.
                              The usage sources stay off unless a usage flag turns one on.
      --dry-run               print the plan and the JSON that would be written; write nothing
      --check                 the installer's checklist: the preflight plus agent, socket and log (unchanged since 0.1: the install
                              flow's last step depends on it)
      --doctor                the health report: build, system, install, files, running app, window manager, permissions, gestures,
                              log, verdict, each row with the command to run next (risk status runs this)
      --json                  with --check or --doctor: one JSON object on stdout and nothing else
      --bundle DIR            with --check or --doctor: also write a redacted report (the JSON and the last 200 log lines) to DIR
                              as one tar.gz; nothing else is written
      --no-path               do not add the folder of the risk link to PATH in your shell start-up files
      --uninstall             stop riskell and remove its agent, its risk link and its PATH block (asks, or --yes)
      --version, --help

    answers (with --yes):
      --wm auto|omniwm|yabai|aerospace|command|none
      --theme ID               a scheme id from installer/themes.json
      --bars minimal|classic|full
      --cards flush|chat
      --city "Name"            looked up once; the first match is used
      --gestures riskell|system
      --claude                 Claude Code usage on, from its local logs (no credentials, no network)
      --claude-limits          also the real plan limits: reads the keychain login token and asks
                               Anthropic (unofficial, may breach its terms). Implies --claude; this flag is the consent.
      --opencode-workspace wrk_...
                               OpenCode Go usage: reads an opencode.ai browser cookie. This flag is the consent.
      --opencode-profiles DIR  the browser profiles folder for OpenCode (default: Zen's)
      --scale N|auto           a number from 0.5 to 2.0, or automatic
      --replace-layout         replace an existing layout.json

    other:
      --repo PATH              the riskell checkout (found automatically when omitted)
      --no-build               do not build riskell
      --no-launch              do not start the launch agent or link risk
      --remove-config          with --uninstall: also remove ~/.config/riskell
      --restore-gestures       with --uninstall: restore the trackpad gestures too

    Nothing is written before the final confirm. Docs: docs/INSTALL.md
    """
}
