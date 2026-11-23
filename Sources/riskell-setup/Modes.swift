import Foundation
import RiskellTTY

/// The plain (no TUI) modes: --yes, --dry-run, --check and --uninstall. Same engine and plan as the TUI.
enum Modes {
    /// Applies the answer flags to the App's choices. Returns the problems it found.
    static func applyAnswers(_ o: Options, to app: App) -> [String] {
        var problems: [String] = []
        if let wm = o.wm {
            if let i = Choices.wmIDs.firstIndex(of: wm) { app.c.wm = i } else { problems.append("--wm: \(wm) is not one of \(Choices.wmIDs.joined(separator: ", "))") }
        }
        if let t = o.theme {
            if let i = schemeData.firstIndex(where: { $0.id == t }) { app.c.theme = i } else { problems.append("--theme: no scheme called \(t)") }
        }
        if let b = o.bars {
            if let p = Preset.allCases.first(where: { $0.id == b }) { app.c.preset = p } else { problems.append("--bars wants minimal, classic or full") }
        }
        if let cards = o.cards {
            switch cards {
            case "flush": app.c.cards = .flush
            case "chat": app.c.cards = .chat
            default: problems.append("--cards wants flush or chat")
            }
        }
        if let g = o.aerospaceGaps {
            if g == "riskell" || g == "manual" { app.c.aerospaceGaps = g } else { problems.append("--aerospace-gaps wants riskell or manual") }
        }
        if let g = o.gestures {
            switch g {
            case "riskell": app.c.gesturesRiskell = true
            case "system": app.c.gesturesRiskell = false
            default: problems.append("--gestures wants riskell or system")
            }
        }
        if let city = o.city {
            switch Geocode.search(city) {
            case .found(let list): app.c.weather = list[0]
            case .noMatch: problems.append("--city: no place called \(city)")
            case .offline(let why): problems.append("--city: \(why)")
            }
        }
        // --yes starts every usage source off; only the flags below turn one on. Each opt-in flag is the consent for it.
        app.c.claude = o.claude || o.claudeLimits
        app.c.claudeLimits = o.claudeLimits
        app.c.opencodeOn = false
        if let ws = o.opencodeWorkspace {
            if Choices.isWorkspaceID(ws) {
                app.c.opencodeOn = true
                app.c.workspace = ws
            } else {
                problems.append("--opencode-workspace wants wrk_ then 6 to 64 letters or digits")
            }
        }
        if let dir = o.opencodeProfiles {
            if app.c.opencodeOn { app.c.profiles = dir } else { problems.append("--opencode-profiles needs --opencode-workspace") }
        }
        if let s = o.scale {
            if s == "auto" {
                app.c.scale = nil
            } else if let v = Double(s), (0.5...2.0).contains(v) {
                app.c.scale = (v * 100).rounded() / 100
            } else {
                problems.append("--scale wants auto or a number from 0.5 to 2.0")
            }
        }
        app.c.replaceLayout = o.replaceLayout
        app.c.gesturesFix = false
        return problems
    }

    static func makeApp(_ o: Options, paths: Paths, repo: URL?) -> App {
        let app = App(facts: Detect.gather(paths, label: "com.rish.riskell"), paths: paths, repo: repo)
        app.noBuild = o.noBuild
        app.noLaunch = o.noLaunch
        app.noPath = o.noPath
        return app
    }

    /// The plan as the kit's `plan` screen, then the exact JSON that would be written.
    static func dryRun(_ app: App, tty: Tty) -> String {
        func block(_ text: String) -> [String] {
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }      // the file ends in a newline: no empty line of margin
            return lines.map { "  " + $0 }
        }
        var out = [tty.header("setup", detail: "the plan, and the JSON it would write"), ""]
        out += tty.plan(app.changePlanRows(), note: "plan (nothing is written); add --yes to install, without the questions")
        let p = app.plan()
        let merged = ConfigIO.merge(app.facts.existing, owned: p.owned)
        out += ["", "  " + tty.tone(app.paths.config().path, .text4)]
        out += block((try? ConfigIO.pretty(merged)) ?? "{}")
        if let layout = p.layoutText {
            out += ["", "  " + tty.tone(app.paths.layout().path, .text4)]
            out += block(layout)
        }
        return out.joined(separator: "\n")
    }

    static func yes(_ o: Options, paths: Paths, repo: URL?) -> Int32 {
        let app = makeApp(o, paths: paths, repo: repo)
        let problems = applyAnswers(o, to: app)
        let tty = Tty.themed()
        if !problems.isEmpty {
            let lines = tty.errorBlock(title: problems.joined(separator: "; "), detail: "riskell-setup --yes [options]",
                                       tries: [("risk help setup", "every option, with its values")])
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            return 2
        }
        if o.dryRun {
            Term.write(dryRun(app, tty: tty) + "\n")
            return 0
        }
        guard let repo = repo else {
            let lines = tty.errorBlock(title: "no riskell checkout was found", detail: "--repo points the installer at the checkout to install from",
                                       tries: [("risk setup --repo PATH", "where the checkout is")])
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            return 2
        }
        print(tty.header("setup", detail: "installing from \(shown(repo.path))"))
        let width = (stepNames.map(\.count).max() ?? 0) + 1      // the steps' key column, measured once
        let builder: Builder? = {
            if o.noBuild {
                print(tty.check(.note, "Build riskell", "skipped (--no-build)", keyWidth: width).joined(separator: "\n"))
                return nil
            }
            if Detect.buildIsFresh(repo) {
                print(tty.check(.note, "Build riskell", "skipped, the binary is current", keyWidth: width).joined(separator: "\n"))
                return nil
            }
            let b = Builder()
            b.start(repo: repo) { line in print("    " + tty.tone(line, .text4)) }
            return b
        }()
        var failed = false
        Installer.run(app.plan(), builder: builder) { e in
            switch e {
            case .stepStart: break
            case .stepLog: break
            case .stepDone(let i, let d): print(tty.check(.ok, stepNames[i], d, keyWidth: width).joined(separator: "\n"))
            case .stepSkipped(let i, let d): print(tty.check(.note, stepNames[i], d, keyWidth: width).joined(separator: "\n"))
            case .failed(let i, let m, let tail):
                failed = true
                print(tty.check(.crit, stepNames[i], m, keyWidth: width).joined(separator: "\n"))
                for t in tail { print(tty.paragraph(t).joined(separator: "\n")) }
            case .finished:
                print(tty.next(cmd: "risk status", why: "the health report, with the first thing to fix named"))
                print(tty.footerHint([(cmd: "ctrl-alt-,", text: "riskell preferences"), (cmd: "risk log 30", text: "what it did")]))
            }
        }
        return failed ? 1 : 0
    }

    /// The doctor: preflight plus the agent, the socket and the log. Non-zero when something is wrong.
    static func check(paths: Paths, label: String) -> Int32 {
        let f = Detect.gather(paths, label: label)
        let tty = Tty.themed()
        var rows: [(Tone, String, String, (cmd: String, note: String?)?)] = []
        var bad = false
        for c in Detect.checks(f) {
            let tone: Tone
            switch c.mark {
            case .ok: tone = .ok
            case .warn: tone = .warn
            case .fail: tone = .crit; bad = true
            }
            rows.append((tone, c.label, c.detail, nil))
        }
        if f.agentLoaded {
            let socket = FileManager.default.fileExists(atPath: paths.socket().path)
            rows.append(socket ? (.ok, "socket", "up", nil) : (.crit, "socket", "missing: is riskell running?", nil))
            if !socket { bad = true }
            let log = (try? String(contentsOf: paths.log(), encoding: .utf8)) ?? ""
            let errors = log.split(separator: "\n").suffix(40).filter { $0.lowercased().contains("fatal") || $0.lowercased().contains("error") }
            rows.append(errors.isEmpty ? (.ok, "log", "no errors in the last lines", nil)
                                       : (.crit, "log", "\(errors.count) error line(s)", (cmd: "risk log 30", note: "read them")))
            if !errors.isEmpty { bad = true }
        }
        print(tty.header("setup --check", detail: "the installer's checklist"))
        print("")
        print(tty.checks(rows).joined(separator: "\n"))
        return bad ? 1 : 0
    }

    static func uninstall(_ o: Options, paths: Paths, label: String, repo: URL?) -> Int32 {
        let tty = Tty.themed()
        if !o.yes {
            guard isatty(0) == 1 else {
                let lines = tty.errorBlock(title: "uninstall asks before it removes anything", detail: "there is no terminal to answer the question on",
                                           tries: [("risk uninstall --yes", "remove it without questions")])
                FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                return 2
            }
            guard tty.confirm("Remove riskell's launch agent and the risk link?", default: false) == true else {
                print(tty.empty("nothing removed", hint: nil).joined(separator: "\n"))
                return 0
            }
        }
        let restore = o.restoreGestures || (FileManager.default.fileExists(atPath: paths.gestureBackup().path) && o.yes)
        let lines = Installer.uninstall(paths: paths, label: label, removeConfig: o.removeConfig, restoreGestures: restore, repo: repo) { _ in }
        print(tty.checks(lines.map { (.ok, "removed", $0, nil) }).joined(separator: "\n"))
        if FileManager.default.fileExists(atPath: paths.gestureBackup().path) && !restore {
            print(tty.check(.warn, "trackpad gestures", "changed by riskell; the originals are saved",
                            hint: (cmd: "risk gestures restore", note: "put them back"), keyWidth: 18).joined(separator: "\n"))
        }
        return 0
    }

    /// A path as a screen reads it: `~/...` under the home folder, absolute everywhere else.
    private static func shown(_ path: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let normal = URL(fileURLWithPath: home).standardized.path
        if path == normal { return "~" }
        if path.hasPrefix(normal + "/") { return "~/" + String(path.dropFirst(normal.count + 1)) }
        return path
    }
}
