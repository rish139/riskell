import Foundation

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
        app.c.claude = o.claude
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

    /// The plan as text, then the exact JSON that would be written.
    static func dryRun(_ app: App) -> String {
        var out = "riskell-setup: plan (nothing is written)\n\n"
        for (k, v) in app.changeLines() {
            out += "  \(k.padding(toLength: 16, withPad: " ", startingAt: 0))\(v)\n"
        }
        let p = app.plan()
        let merged = ConfigIO.merge(app.facts.existing, owned: p.owned)
        out += "\n\(app.paths.config().path):\n" + ((try? ConfigIO.pretty(merged)) ?? "{}\n")
        if let layout = p.layoutText {
            out += "\n\(app.paths.layout().path):\n" + layout
        }
        return out
    }

    static func yes(_ o: Options, paths: Paths, repo: URL?) -> Int32 {
        let app = makeApp(o, paths: paths, repo: repo)
        let problems = applyAnswers(o, to: app)
        if !problems.isEmpty {
            for p in problems { FileHandle.standardError.write(Data("riskell-setup: \(p)\n".utf8)) }
            return 2
        }
        if o.dryRun {
            Term.write(dryRun(app))
            return 0
        }
        guard let repo = repo else {
            FileHandle.standardError.write(Data("riskell-setup: no riskell checkout found; pass --repo PATH\n".utf8))
            return 2
        }
        print("riskell-setup: installing riskell from \(repo.path)")
        let builder: Builder? = {
            if o.noBuild { print("  - Build riskell: skipped (--no-build)"); return nil }
            if Detect.buildIsFresh(repo) { print("  - Build riskell: skipped, the binary is current"); return nil }
            let b = Builder()
            b.start(repo: repo) { line in print("    \(line)") }
            return b
        }()
        var failed = false
        Installer.run(app.plan(), builder: builder) { e in
            switch e {
            case .stepStart: break
            case .stepLog: break
            case .stepDone(let i, let d): print("  ✓ \(stepNames[i]): \(d)")
            case .stepSkipped(let i, let d): print("  ○ \(stepNames[i]): \(d)")
            case .failed(let i, let m, let tail):
                failed = true
                print("  ✗ \(stepNames[i]): \(m)")
                for t in tail { print("      \(t)") }
            case .finished:
                print("riskell is running. Next: ctrl-alt-, (riskell preferences), risk status, risk log 30")
            }
        }
        return failed ? 1 : 0
    }

    /// The doctor: preflight plus the agent, the socket and the log. Non-zero when something is wrong.
    static func check(paths: Paths, label: String) -> Int32 {
        let f = Detect.gather(paths, label: label)
        var bad = false
        for c in Detect.checks(f) {
            let mark: String
            switch c.mark {
            case .ok: mark = "✓"
            case .warn: mark = "!"
            case .fail: mark = "✗"; bad = true
            }
            print("\(mark)  \(c.label.padding(toLength: 16, withPad: " ", startingAt: 0))\(c.detail)")
        }
        if f.agentLoaded {
            let socket = FileManager.default.fileExists(atPath: paths.socket().path)
            print(socket ? "✓  socket          up" : "✗  socket          missing: is riskell running?")
            if !socket { bad = true }
            let log = (try? String(contentsOf: paths.log(), encoding: .utf8)) ?? ""
            let errors = log.split(separator: "\n").suffix(40).filter { $0.lowercased().contains("fatal") || $0.lowercased().contains("error") }
            print(errors.isEmpty ? "✓  log             no errors in the last lines" : "✗  log             \(errors.count) error line(s): risk log 30")
            if !errors.isEmpty { bad = true }
        }
        return bad ? 1 : 0
    }

    static func uninstall(_ o: Options, paths: Paths, label: String, repo: URL?) -> Int32 {
        if !o.yes {
            guard isatty(0) == 1 else {
                FileHandle.standardError.write(Data("riskell-setup: --uninstall asks first; add --yes to run it without a terminal\n".utf8))
                return 2
            }
            print("Remove riskell's launch agent and the risk link? [y/N] ", terminator: "")
            guard let answer = readLine(), answer.lowercased().hasPrefix("y") else {
                print("nothing removed")
                return 0
            }
        }
        let restore = o.restoreGestures || (FileManager.default.fileExists(atPath: paths.gestureBackup().path) && o.yes)
        let lines = Installer.uninstall(paths: paths, label: label, removeConfig: o.removeConfig, restoreGestures: restore, repo: repo) { _ in }
        for l in lines { print("✓  \(l)") }
        if FileManager.default.fileExists(atPath: paths.gestureBackup().path) && !restore {
            print("!  your trackpad gestures were changed by riskell: riskell --gestures-restore --yes")
        }
        return 0
    }
}
