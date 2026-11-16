import Foundation

/// Canned screens for the snapshots (docs/installer-snapshots). Each name is a screen in a fixed state; nothing is probed.
enum Snapshots {
    static let names = [
        "welcome", "welcome-blocked", "wm", "bars", "theme", "weather", "weather-results", "weather-offline",
        "usage", "gestures", "scale", "review", "diff", "install-early", "install-mid", "install-late",
        "install-failed", "finish", "bars-minimal", "bars-full", "theme-light",
    ]
    static let sizes = [(100, 32), (80, 24), (60, 20)]

    static func app(_ name: String) -> App {
        var facts = Facts.fixture
        facts.existing = nil
        if name == "welcome-blocked" {
            facts.swift = nil
            facts.arch = "x86_64"
        } else if name == "welcome" {
            facts.arch = "x86_64"
        }
        if name == "review" || name == "diff" {
            facts.layoutFound = true
            facts.configFound = true
        }
        let app = App(facts: facts, paths: Paths(home: "/Users/example"), repo: nil)
        app.tickCount = 0
        app.slideLeft = 0
        app.c.weather = Place(name: "Hamburg", region: "Hamburg, Germany", lat: 53.55, lon: 10.00)
        app.checksShown = 99
        let stage: [String: Stage] = [
            "wm": .wm, "bars": .bars, "theme": .theme, "weather": .weather, "weather-results": .weather,
            "weather-offline": .weather, "usage": .usage, "gestures": .gestures, "scale": .scale,
            "review": .review, "diff": .diff, "install-early": .install, "install-mid": .install,
            "install-late": .install, "install-failed": .install, "finish": .finish,
        ]
        app.stage = stage[name] ?? .welcome
        switch name {
        case "wm":
            app.cursor = 0
        case "bars":
            app.c.preset = .classic
            app.cursor = 1
        case "bars-minimal":
            app.stage = .bars
            app.c.preset = .minimal
            app.cursor = 0
        case "bars-full":
            app.stage = .bars
            app.c.preset = .full
            app.cursor = 2
        case "theme-light":
            app.stage = .theme
            app.c.theme = schemeData.firstIndex { $0.id == "catppuccin-latte" } ?? 0
            app.cursor = app.c.theme
        case "theme":
            app.cursor = 2
            app.c.theme = 2
        case "weather":
            app.query = "Dres"
            app.geoSearching = true
        case "weather-results":
            app.query = "Hamburg"
            app.places = [
                Place(name: "Hamburg", region: "Hamburg, Germany", lat: 53.55108, lon: 9.99368),
                Place(name: "Hamburg", region: "New York, United States", lat: 43.3, lon: -74.7),
                Place(name: "Hamburg", region: "Ontario, Canada", lat: 44.6, lon: -76.2),
            ]
            app.geoOutcome = .found(app.places)
        case "weather-offline":
            app.query = "Hamburg"
            app.geoOutcome = .offline("could not reach open-meteo.com")
            app.cursor = 1
        case "usage":
            app.c.claude = true
            app.c.opencodeOn = true
            app.c.workspace = "wrk_01KQXAMPLEWORKSPACE"
            app.cursor = 2
        case "gestures":
            app.c.gesturesRiskell = true
            app.cursor = 1
            app.conflicts = ["three-finger swipe between spaces", "Mission Control gesture"]
        case "scale":
            app.c.scale = 1.2
            app.cursor = 1
        case "review":
            app.cursor = 1
        case "diff":
            break
        case "install-early", "install-mid", "install-late", "install-failed":
            var j = JobView()
            switch name {
            case "install-early":
                j.status[0] = .running
                j.logLast = "[12/40] Compiling riskell Overlay.swift"
            case "install-mid":
                j.status = [.done, .done, .done, .skipped, .running, .pending, .pending]
                j.details = ["built in 41 s", "merged 6 owned keys, your other keys are kept", "kept your layout.json", "left as they are", "", "", ""]
                j.logLast = "==> Writing launch agent"
            case "install-late":
                j.status = [.done, .done, .done, .skipped, .done, .done, .running]
                j.details = ["built in 41 s", "merged 6 owned keys, your other keys are kept", "kept your layout.json", "left as they are", "~/.local/bin/risk", "running, socket up", ""]
            default:
                j.status = [.done, .done, .done, .skipped, .done, .failed, .pending]
                j.details = ["built in 41 s", "merged 6 owned keys, your other keys are kept", "kept your layout.json", "left as they are", "~/.local/bin/risk", "scripts/risk install failed", ""]
                j.failMessage = "scripts/risk install failed"
                j.failTail = ["Bootstrap failed: 5: Input/output error", "launchctl could not load com.rish.riskell", "run: risk log 30"]
            }
            app.job = j
            app.progressShown = j.progress
        case "finish":
            var j = JobView()
            j.status = Array(repeating: .done, count: 7)
            j.status[3] = .skipped
            j.details = ["built in 41 s", "merged 6 owned keys, your other keys are kept", "Classic layout written", "left as they are", "~/.local/bin/risk", "written and started", "running, socket up, no errors in the log"]
            j.finished = true
            j.summary = j.details
            app.job = j
            app.linesShown = 99
        default:
            break
        }
        return app
    }

    static func render(_ name: String, w: Int, h: Int) -> Grid {
        app(name).render(w: w, h: h)
    }

    /// Writes every screen at every size: `<name>-<w>x<h>.txt` (plain) and `.ansi` (with colour).
    static func writeAll(to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Ink.mode = .truecolor
        for name in names {
            for (w, h) in sizes {
                let g = render(name, w: w, h: h)
                let base = "\(dir)/\(name)-\(w)x\(h)"
                try g.plainText().write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                try g.ansi().write(toFile: base + ".ansi", atomically: true, encoding: .utf8)
            }
        }
    }
}
