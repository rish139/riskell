import Darwin
import Foundation
import RiskellTTY

/// `riskell-setup --self-test`: unit-style checks with PASS / FAIL lines, no XCTest (the package builds with Command Line Tools only).
enum SelfTest {
    private static var failures = 0

    /// The terminal the run is drawn on: the kit's, in the theme in force.
    private static let tty = Tty.themed()

    /// One check. The word stays first and the name after it because these lines are read by other tests (`^PASS ...`); the tone is what
    /// the kit adds, so a terminal shows PASS in the ok colour and FAIL in the critical one, and a pipe shows the same plain text.
    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print(tty.tone("PASS", .ok) + " " + tty.tone(name, .text1))
        } else {
            failures += 1
            print(tty.tone("FAIL", .crit) + " " + tty.tone(name, .text1) + (detail.isEmpty ? "" : ": " + tty.tone(detail, .text3)))
        }
    }

    /// A check that did not run, in the warning colour: what was skipped and what would have run it.
    private static func skip(_ text: String) {
        print(tty.tone("SKIP", .warn) + " " + tty.tone(text, .text3))
    }

    static func run(repo: URL?) -> Int32 {
        print(tty.header("setup --self-test", detail: "the installer's checks, one line each"))
        print("")
        configMerge()
        presets(repo: repo)
        geocode()
        shellPath()
        detection()
        arguments()
        usage()
        aerospace()
        themes()
        doctor()
        statusScreen(repo: repo)
        bundle()
        print("")
        print(tty.check(failures == 0 ? .ok : .crit, "result", failures == 0 ? "all checks passed" : "\(failures) check(s) failed",
                        keyWidth: 7).joined(separator: "\n"))
        return failures == 0 ? 0 : 1
    }

    private static func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("riskell-setup-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A unix socket at PATH for the report's probe: bound and listening (the descriptor comes back, so the file stays), or bound and
    /// closed at once, which leaves a socket file that refuses connections.
    private static func openSocket(at path: String, listening: Bool) -> Int32? {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } } == 0 else {
            close(fd)
            return nil
        }
        guard listening else { close(fd); return nil }
        listen(fd, 1)
        return fd
    }

    static func configMerge() {
        let existing: [String: Any] = ["pills": [["id": "x"]], "spacing": ["edgeGap": 12], "wm": "none", "theme": "nord", "scale": 1.2]
        let out = ConfigIO.merge(existing, owned: [("wm", "omniwm"), ("scale", nil)])
        check("merge keeps unknown keys", (out["pills"] as? [[String: String]]) != nil && (out["spacing"] as? [String: Int])?["edgeGap"] == 12)
        check("merge replaces owned keys", out["wm"] as? String == "omniwm")
        check("merge removes owned keys set to nil", out["scale"] == nil)
        check("merge does not touch other owned keys", out["theme"] as? String == "nord")

        let dir = tempDir("backup")
        let file = dir.appendingPathComponent("config.json")
        try? "{\"wm\": \"none\"}\n".write(to: file, atomically: true, encoding: .utf8)
        let made = try? ConfigIO.backup(file)
        check("backup is created with a timestamp name", made.flatMap { $0 }?.lastPathComponent.hasPrefix("config.json.bak-") ?? false)
        check("the original stays in place", FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(at: dir)

        let bad = tempDir("badjson")
        try? "[1,2]".write(to: bad.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        if case .failure = ConfigIO.readObject(bad.appendingPathComponent("config.json")) {
            check("a config that is not an object is rejected", true)
        } else {
            check("a config that is not an object is rejected", false)
        }
        try? FileManager.default.removeItem(at: bad)
    }

    /// Every preset must be accepted by riskell itself: `riskell --dump` with RISKELL_LAYOUT pointing at the generated file.
    static func presets(repo: URL?) {
        let known: Set<String> = ["ext:workspaces", "ext:appicon", "ext:usage", "ext:fan", "ext:bat", "ext:clock", "ext:vol", "ext:net", "ext:cpu", "ext:weather", "compat"]
        for p in Preset.allCases {
            for mode in BarMode.allCases {
                for cards in [CardStyle.flush, CardStyle.chat] {
                    let atoms = Presets.atoms(Presets.layout(p, mode: mode, cards: cards))
                    check("preset \(p.id) \(mode) \(cards) places only known atoms once",
                          atoms.allSatisfy { known.contains($0) } && Set(atoms).count == atoms.count)
                }
            }
        }
        let classic = Presets.layout(.classic, mode: .preset, cards: .flush)
        check("classic bottom centre holds cpu", ((classic["bottom"] as? [String: Any])?["center"] as? [[String: Any]])?.first?["id"] as? String == "cpu")
        guard let repo = repo else {
            skip("riskell --dump checks: no checkout found (pass --repo)")
            return
        }
        let binary = repo.appendingPathComponent(".build/release/riskell")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            skip("riskell --dump checks: build riskell first (swift build -c release)")
            return
        }
        let dir = tempDir("dump")
        defer { try? FileManager.default.removeItem(at: dir) }
        for p in Preset.allCases {
            let layoutFile = dir.appendingPathComponent("layout-\(p.id).json")
            let configFile = dir.appendingPathComponent("config-\(p.id).json")
            let json = (try? Presets.json(Presets.layout(p, mode: .hug, cards: .chat))) ?? ""
            try? json.write(to: layoutFile, atomically: true, encoding: .utf8)
            try? "{}\n".write(to: configFile, atomically: true, encoding: .utf8)
            let proc = Process()
            proc.executableURL = binary
            proc.arguments = ["--no-usage", "--no-reserve", "--fake-media", "--dump"]
            proc.currentDirectoryURL = repo
            var env = ProcessInfo.processInfo.environment
            env["RISKELL_LAYOUT"] = layoutFile.path
            env["RISKELL_CONFIG"] = configFile.path
            proc.environment = env
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do { try proc.run() } catch {
                check("riskell --dump starts for \(p.id)", false, "\(error)")
                continue
            }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            proc.waitUntilExit()
            check("riskell --dump accepts the \(p.id) layout", !out.lowercased().contains("error"), String(out.prefix(200)))
            let trayLine = out.split(separator: "\n").first { $0.hasPrefix("tray:") }.map(String.init) ?? ""
            let unknown = trayLine.split(separator: " ").dropFirst().filter { !known.contains(String($0)) }
            check("the \(p.id) dump lists no unknown atoms in tray", trayLine.hasPrefix("tray:") && unknown.isEmpty, "\(unknown)")
        }
    }

    static func shellPath() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("riskell-setup-test-\(getpid())")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = Paths(home: tmp.path)
        let zshrc = tmp.appendingPathComponent(".zshrc"), bashrc = tmp.appendingPathComponent(".bashrc")
        let mine = "alias ll='ls -l'\nexport EDITOR=vim\n"
        try? mine.write(to: zshrc, atomically: true, encoding: .utf8)
        try? "# bash\n".write(to: bashrc, atomically: true, encoding: .utf8)
        let dir = paths.localBin()
        ShellPath.add(dir: dir, paths: paths); ShellPath.add(dir: dir, paths: paths)
        let z = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        check("PATH block: added once to zshrc", z.components(separatedBy: ShellPath.begin).count == 2 && z.hasPrefix(mine) && z.contains("export PATH=\"$HOME/.local/bin:$PATH\""))
        check("PATH block: added to a bashrc that exists", ShellPath.present(in: bashrc))
        check("PATH block: no bash_profile created", !FileManager.default.fileExists(atPath: tmp.appendingPathComponent(".bash_profile").path))
        check("PATH block: a backup of the old zshrc", ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).contains { $0.hasPrefix(".zshrc.bak-riskell-") })
        ShellPath.remove(paths: paths)
        check("PATH block: removed, the user's lines intact", ((try? String(contentsOf: zshrc, encoding: .utf8)) ?? "") == mine && !ShellPath.present(in: bashrc))
    }

    static func geocode() {
        let canned = """
        {"results":[
          {"id":1,"name":"Bergen","latitude":60.39299,"longitude":5.32415,"country":"Norway","admin1":"Vestland"},
          {"id":2,"name":"Oslo","latitude":59.9,"longitude":10.7,"country":"Norway"}
        ],"generationtime_ms":0.4}
        """
        let places = (try? Geocode.parse(Data(canned.utf8))) ?? []
        check("geocode parses a canned response", places.count == 2 && places[0].name == "Bergen" && places[0].region == "Vestland, Norway")
        let negative = (try? Geocode.parse(Data("{\"results\":[{\"name\":\"X\",\"latitude\":1,\"longitude\":-74.7}]}".utf8))) ?? []
        check("geocode keeps negative longitudes", negative.first?.lon == -74.7)
        let empty = (try? Geocode.parse(Data("{}".utf8))) ?? [Place(name: "x", region: "", lat: 0, lon: 0)]
        check("geocode: no results key is no match", empty.isEmpty)
        check("geocode percent-encodes the query", Geocode.percentEncode("São Paulo") == "S%C3%A3o%20Paulo")
        check("geocode coordinates by hand", Geocode.parseCoordinates("53.55, 10.00")?.1 == 10.00 && Geocode.parseCoordinates("95, 1") == nil)
    }

    static func detection() {
        check("parses the Swift version line", Detect.parseSwiftVersion("swift-driver version: 1.1 Apple Swift version 6.1.2 (swiftlang)") == "Swift 6.1.2")
        check("parses defaults integers", Detect.parseDefaultsInt(" 1\n") == 1 && Detect.parseDefaultsInt("x") == nil)
        check("reads the agent label from scripts/risk", Detect.parseRiskLabel("root=1\nlabel=com.rish.riskell\n") == "com.rish.riskell")
        check("macOS 14 is the gate", Detect.macOSAtLeast14("14.0") && !Detect.macOSAtLeast14("13.6"))
        var f = Facts.fixture
        f.wms = [WMFact(name: "yabai", installed: true, running: false), WMFact(name: "OmniWM", installed: true, running: true)]
        check("detected window manager prefers a running one", f.detectedWM == "OmniWM")
        f.swift = nil
        check("a missing Swift toolchain blocks", f.blocked)
        check("welcome shows a fail mark for Swift", Detect.checks(f).contains { $0.label == "swift" && $0.mark == .fail })
    }

    static func arguments() {
        let o = Options.parse(["--yes", "--wm", "omniwm", "--bars", "minimal", "--cards", "chat", "--scale", "1.2", "--no-launch", "--repo", "/tmp/r"])
        check("--yes selects the plain mode", o.mode == .yes && o.yes)
        check("answer flags are read", o.wm == "omniwm" && o.bars == "minimal" && o.cards == "chat" && o.scale == "1.2")
        check("--no-launch and --repo are read", o.noLaunch && o.repo == "/tmp/r")
        check("--check is a mode", Options.parse(["--check"]).mode == .check)
        check("--size WxH is read", Options.parse(["--snapshot", "welcome", "--size", "80x24"]).width == 80)
        check("an unknown flag is reported", !Options.parse(["--bogus"]).errors.isEmpty)
        check("a flag without its value is reported", !Options.parse(["--wm"]).errors.isEmpty)
    }

    /// The usage sources: both opt-ins start off, only a flag turns them on, and the installer keeps the keys it does not own.
    static func usage() {
        check("a workspace id is wrk_ and 6 to 64 letters or digits", Choices.isWorkspaceID("wrk_01KQXAMPLE01")
              && !Choices.isWorkspaceID("wrk_abc") && !Choices.isWorkspaceID("wrk_" + String(repeating: "a", count: 65))
              && !Choices.isWorkspaceID("abc_01KQXAMPLE01") && !Choices.isWorkspaceID("wrk_ab-cdef1"))
        let home = Paths(home: "/tmp/riskell-setup-usage-selftest")
        func answered(_ args: [String]) -> (App, [String]) {
            let app = App(facts: Facts.fixture, paths: home, repo: nil)
            let problems = Modes.applyAnswers(Options.parse(args), to: app)
            return (app, problems)
        }
        let (plain, plainProblems) = answered(["--yes"])
        check("--yes alone leaves every usage source off", plainProblems.isEmpty && !plain.c.claude && !plain.c.claudeLimits && !plain.c.opencodeOn)
        let (limits, _) = answered(["--yes", "--claude-limits"])
        check("--claude-limits implies --claude and turns the limits on", limits.c.claude && limits.c.claudeLimits && !limits.c.opencodeOn)
        let (oc, ocProblems) = answered(["--yes", "--opencode-workspace", "wrk_01KQXAMPLE01", "--opencode-profiles", "/tmp/zen"])
        check("--opencode-workspace turns OpenCode on with the folder", ocProblems.isEmpty && oc.c.opencodeOn && oc.c.workspace == "wrk_01KQXAMPLE01" && oc.c.profiles == "/tmp/zen" && !oc.c.claudeLimits)
        check("a bad --opencode-workspace is reported", !answered(["--yes", "--opencode-workspace", "wrk_x"]).1.isEmpty)
        check("--opencode-profiles without a workspace is reported", !answered(["--yes", "--opencode-profiles", "/tmp/zen"]).1.isEmpty)

        var f = Facts.fixture
        f.existing = ["usage": ["claude": true, "claudeLimits": true, "fiveHourTokens": 5000000.0,
                                "opencode": ["workspace": "wrk_01KQXAMPLE01", "profiles": "/tmp/zen"]] as [String: Any]]
        let kept = App(facts: f, paths: home, repo: nil)
        check("an existing file keeps its consent in the choices", kept.c.claudeLimits && kept.c.opencodeOn)
        Modes.applyAnswers(Options.parse(["--yes"]), to: kept)
        let usage = kept.plan().owned.first { $0.0 == "usage" }?.1 as? [String: Any]
        check("--yes writes no opt-in key, and keeps the token limit", usage?["claude"] == nil && usage?["claudeLimits"] == nil
              && usage?["opencode"] == nil && (usage?["fiveHourTokens"] as? Double) == 5000000)
        let merged = ConfigIO.merge(f.existing, owned: kept.plan().owned)
        check("the merged file keeps the token limit and drops the opt-ins", (merged["usage"] as? [String: Any])?.keys.sorted() == ["fiveHourTokens"])
    }

    /// AeroSpace: detected from its app or binary, gaps default to riskell, the nested key merges, and only AeroSpace writes it.
    static func aerospace() {
        let home = Paths(home: "/tmp/riskell-setup-aerospace-selftest")
        var f = Facts.fixture
        f.wms = [WMFact(name: "AeroSpace", installed: true, running: false)]
        check("AeroSpace installed but not running is reported", Detect.checks(f).contains { $0.label == "window manager" && $0.detail == "AeroSpace installed, not running" })
        check("AeroSpace is a choice", Choices.wmIDs.contains("aerospace"))
        let plain = App(facts: Facts.fixture, paths: home, repo: nil)
        check("the default window manager is still auto, with no aerospace key", plain.c.wmID == "auto" && !plain.plan().owned.contains { $0.0 == "aerospace" })
        f.existing = ["aerospace": ["gaps": "manual", "other": 1] as [String: Any], "pills": [["id": "x"]]]
        let again = App(facts: f, paths: home, repo: nil)
        check("an existing manual gaps choice is kept", again.c.aerospaceGaps == "manual")
        let fresh = App(facts: Facts.fixture, paths: home, repo: nil)
        let problems = Modes.applyAnswers(Options.parse(["--yes", "--wm", "aerospace"]), to: fresh)
        check("gaps default to riskell", problems.isEmpty && fresh.c.isAerospace && fresh.c.aerospaceGaps == "riskell")
        check("--wm aerospace writes wm", fresh.plan().owned.contains { $0.0 == "wm" && ($0.1 as? String) == "aerospace" })
        check("--aerospace-gaps manual is read", Modes.applyAnswers(Options.parse(["--yes", "--wm", "aerospace", "--aerospace-gaps", "manual"]), to: fresh).isEmpty && fresh.c.aerospaceGaps == "manual")
        check("a bad --aerospace-gaps is reported", !Modes.applyAnswers(Options.parse(["--yes", "--aerospace-gaps", "x"]), to: fresh).isEmpty)
        let kept = App(facts: f, paths: home, repo: nil)
        kept.c.wm = Choices.wmIDs.firstIndex(of: "aerospace")!
        kept.c.aerospaceGaps = "riskell"
        let merged = ConfigIO.merge(f.existing, owned: kept.plan().owned)
        let aero = merged["aerospace"] as? [String: Any]
        check("the merge sets gaps and keeps the other aerospace keys and the rest of the file",
              aero?["gaps"] as? String == "riskell" && aero?["other"] as? Int == 1 && merged["pills"] != nil)
        check("the review explains the gaps in one sentence", Choices.aerospaceGapsNote("riskell").contains("aerospace.toml")
              && Choices.aerospaceGapsNote("riskell").contains("backup") && Choices.aerospaceGapsNote("manual").contains("does not touch"))
    }

    static func themes() {
        check("eleven schemes ship", schemeData.count == 11)
        check("exactly one scheme is the default", schemeData.filter { $0.isDefault }.count == 1)
        check("the default is gruvbox dark medium", schemeData.first { $0.isDefault }?.id == "gruvbox-dark-medium")
        check("hex parses", RGB8(hex: "#fabd2f") == RGB8(250, 189, 47))
        check("256-colour fallback maps pure white to the top of the palette", RGB8(255, 255, 255).ansi256 >= 231)
        check("NO_COLOR forces no colour", RiskellTTY.Mode.detect(env: ["NO_COLOR": "1", "COLORTERM": "truecolor"], isTTY: true) == .none)
        check("a pipe is never styled", RiskellTTY.Mode.detect(env: ["COLORTERM": "truecolor"], isTTY: false) == .none)
        check("truecolor is detected", RiskellTTY.Mode.detect(env: ["COLORTERM": "truecolor"], isTTY: true) == .truecolor)
        let tty = Tty(mode: .truecolor, width: 80, palette: palette(schemeData[0]))
        check("strip gives back the plain text", Tty.strip(tty.accent("riskell")) == "riskell" && Tty.strip(tty.mark(.ok, "done")) == "✓ done")
        check("the tones carry no width", Tty.strip(tty.bold("a") + tty.dim("b") + tty.tone("c", .accent)) == "abc")
        check("a label and its value are one line", Tty.strip(tty.label("bg", "#282828")) == "bg  #282828")
        check("a pipe prints no escape sequences", Tty(mode: .none, width: 80, palette: tty.palette).accent("riskell") == "riskell")
        check("rows line up and right-align",
              tty.rows([[RiskellTTY.Cell("bg"), RiskellTTY.Cell("2", .right)], [RiskellTTY.Cell("text1"), RiskellTTY.Cell("22", .right)]])
              == ["bg      2", "text1  22"])
        check("no line is wider than the width", Tty(mode: .none, width: 12, palette: tty.palette).heading(String(repeating: "x", count: 40)).count == 12)
        check("the width comes from COLUMNS, else 80", Tty.detect(palette: tty.palette, env: ["COLUMNS": "40"]).width == 40
              && Tty.detect(palette: tty.palette, env: [:]).width == 80)
    }

    /// The health report (`--doctor`): the order of the sections, the worst row's status, the JSON writer, and what a bundle leaves out.
    static func doctor() {
        let rows = [ReportCheck(id: "a", label: "a", severity: .ok, detail: "fine", source: .cli),
                    ReportCheck(id: "b", label: "b", severity: .warn, detail: "hmm", source: .app)]
        check("a section's status is its worst row", ReportSection(id: "s", title: "s", checks: rows).status == .warn)
        check("a section with no row is ok", ReportSection(id: "s", title: "s", checks: []).status == .ok)
        check("an info row never makes a section fail",
              ReportSection(id: "s", title: "s", checks: rows + [ReportCheck(id: "c", label: "c", severity: .info, detail: "n/a", source: .cli)]).firstFailure == nil)

        // the JSON keeps the order it was written in and escapes nothing but `"`, `\` and control characters
        let doc = JSON.object([("schema", .number(1)), ("detail", .text("~/a/b")), ("keys", .list([.text("wm")])), ("ok", .flag(true)), ("none", .null)])
        let text = doc.rendered()
        check("the JSON keeps its keys in order", text.hasPrefix("{\n  \"schema\": 1,\n  \"detail\": \"~/a/b\""))
        check("the JSON escapes no slash and no non-ASCII", text.contains("~/a/b") && !text.contains("\\/"))
        check("the JSON escapes a quote, and only that", JSON.quoted("a \"b\"") == "\"a \\\"b\\\"\"" && JSON.quoted("a/b\u{1F600}") == "\"a/b\u{1F600}\"")
        check("an empty object and an empty list are one line", JSON.object([]).rendered() == "{}" && JSON.list([]).rendered() == "[]")
        check("a decoded answer becomes ordered JSON", JSON.value(["b": 1, "a": [true, NSNull()]]).rendered() == "{\n  \"a\": [\n    true,\n    null\n  ],\n  \"b\": 1\n}")

        // redaction: the home folder, an id, a token, a credential word and the lines that print window and app names
        let home = "/Users/example"
        check("a home path is written ~", Doctor.shorten(home + "/.config/riskell/config.json", home: home) == "~/.config/riskell/config.json")
        check("a path outside home is left alone", Doctor.shorten("/opt/homebrew/bin/risk", home: home) == "/opt/homebrew/bin/risk")
        check("the home folder is short", Doctor.shorten(home, home: home) == "~")
        check("a folder named like home plus a letter is not short", Doctor.shorten(home + "else/x", home: home) == home + "else/x")
        check("a log line has its home folder shortened", Doctor.redact("wrote " + home + "/.cache/riskell/overview.png", home: home) == "wrote ~/.cache/riskell/overview.png")
        check("a workspace id is masked", Doctor.redact("opencode wrk_01KQXAMPLE01 read", home: home).contains("wrk_<redacted>"))
        check("a token is masked", !Doctor.redact("Authorization: sk-abcdefghijklmnop", home: home).contains("sk-abcdefghijklmnop"))
        check("a long hash is masked", !Doctor.redact("id 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", home: home).contains("1a2b3c4d5e6f"))
        check("an address is masked", !Doctor.redact("ssid at 192.168.1.24 link up", home: home).contains("192.168.1.24"))
        check("a line that mentions a credential is dropped whole", Doctor.redact("token: abc", home: home).hasPrefix("[redacted"))
        check("a line that prints app names is dropped whole", Doctor.redact("window-order (front first): Arc > Ghostty", home: home).hasPrefix("[redacted"))
        check("a header names what a bundle leaves out", Doctor.header(Date()).contains("keychain") && !Doctor.header(Date()).contains(home))

        // the probes
        check("the main display has at least one Space", Doctor.mainDisplaySpaces().map { $0 >= 1 } ?? true)
        check("the last wake is in the past", (Doctor.lastWake()?.timeIntervalSinceNow ?? -1) < 0)
        let plist = tempDir("plist").appendingPathComponent("agent.plist")
        try? ("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>ProgramArguments</key><array><string>/tmp/riskell</string></array></dict></plist>")
            .write(to: plist, atomically: true, encoding: .utf8)
        check("an agent plist names its program", Doctor.plistProgram(plist) == "/tmp/riskell")
        check("a missing plist names nothing", Doctor.plistProgram(plist.appendingPathExtension("nope")) == nil)


        // what the agent runs against this checkout's release binary: a rebuild that has not reached the agent warns, a bundle without
        // its binary fails (scripts/risk writes both, and only risk dev refreshes the copy the agent starts)
        let checkout = tempDir("agent")
        let release = checkout.appendingPathComponent(".build/release/riskell")
        let program = checkout.appendingPathComponent(".build/riskell.app/Contents/MacOS/riskell")
        for url in [release, program] {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: url.path)
        }
        check("an app bundle newer than the release binary is fine",
              Doctor.bundleCheck(program: program.path, release: release, home: checkout.path).severity == .ok)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: release.path)
        let older = Doctor.bundleCheck(program: program.path, release: release, home: checkout.path)
        check("an agent started before the last build is a warning with risk dev", older.severity == .warn && older.fix == "risk dev", older.detail)
        try? FileManager.default.removeItem(at: program)
        check("a bundle without its binary is a failure",
              Doctor.bundleCheck(program: program.path, release: release, home: checkout.path).severity == .fail)

        // the version the bar reports, when its own answer is not there: the app bundle's plist, else the checkout's VERSION
        let fake = tempDir("app").appendingPathComponent("riskell.app")
        try? FileManager.default.createDirectory(at: fake.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try? ("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>9.9.9</string></dict></plist>")
            .write(to: fake.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        check("the version of the app the agent runs comes from its bundle",
              Doctor.bundleVersion(fake.appendingPathComponent("Contents/MacOS/riskell").path) == "9.9.9")
        check("a program outside a bundle has no bundle version", Doctor.bundleVersion("/tmp/riskell") == nil)
        let versioned = tempDir("version")
        try? "1.2.3\n".write(to: versioned.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        check("the checkout's VERSION is the last fallback", Doctor.checkoutVersion(versioned) == "1.2.3" && Doctor.checkoutVersion(nil) == nil)

        // the socket's three ways of saying nothing, which the report tells apart: no file, a file nothing listens on, a build that
        // takes the doctor word for an event and replies with nothing
        func state(_ home: URL) -> String {
            switch Doctor.ask(Paths(home: home.path)) {
            case .answered: return "answered"
            case .silent: return "silent"
            case .refused: return "refused"
            case .missing: return "missing"
            }
        }
        let quiet = URL(fileURLWithPath: "/tmp/riskell-setup-socket-\(getpid())")      // a unix socket path is at most 104 bytes
        try? FileManager.default.removeItem(at: quiet)
        let socketPath = quiet.appendingPathComponent(".cache/riskell/ev.sock").path
        openSocket(at: socketPath, listening: false)
        check("a socket with nothing behind it is refused", state(quiet) == "refused")
        let listener = openSocket(at: socketPath, listening: true)
        check("a socket that says nothing is an app older than this report", state(quiet) == "silent")
        if let listener { close(listener) }
        unlink(socketPath)
        check("no socket at all is riskell not running", state(quiet) == "missing")
        try? FileManager.default.removeItem(at: quiet)

        // the instance lock: held from an open file description, then released
        let lock = tempDir("lock").appendingPathComponent("riskell.lock")
        FileManager.default.createFile(atPath: lock.path, contents: nil)
        check("a lock file nobody holds is free", !Doctor.lockHeld(lock))
        let fd = open(lock.path, O_RDWR)
        check("a held lock file is held", fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0 && Doctor.lockHeld(lock))
        flock(fd, LOCK_UN); close(fd)
        check("a released lock file is free again", !Doctor.lockHeld(lock))

        // the flags
        let json = Options.parse(["--check", "--json"])
        check("--json goes with --check", json.mode == .check && json.json && json.errors.isEmpty)
        let doctor = Options.parse(["--doctor", "--bundle", "/tmp/report"])
        check("--bundle takes a folder and --doctor is a mode", doctor.mode == .doctor && doctor.bundle == "/tmp/report" && doctor.errors.isEmpty)
        check("--json alone is refused", !Options.parse(["--json"]).errors.isEmpty)
        check("--bundle without a value is refused", !Options.parse(["--check", "--bundle"]).errors.isEmpty)
        // --all asks for the full status list; with --json the report is already every row, so it changes nothing and breaks nothing
        let full = Options.parse(["--doctor", "--all", "--json"])
        check("--all is a flag of the report", full.mode == .doctor && full.all && full.errors.isEmpty && !Options.parse(["--doctor"]).all)
    }

    /// The status screen drawn from fixed reports: all four tones, hints, and a value long enough to wrap, compared with the recordings
    /// in Tests/cli/golden. The default screen is the compact one and `--all` is the full list, both recorded. The reports are data and the
    /// Tty is forced plain, so nothing about this machine reaches them.
    static func statusScreen(repo: URL?) {
        let report = Report(
            version: "0.2.1", macOS: "27.2", chip: "Apple silicon", windowManager: "OmniWM",
            state: .running("running · pid 67123 · up 3d 4h"),
            sections: [
                ScreenSection(title: "build", rows: [
                    ScreenRow(tone: .ok, key: "binary", value: "built · 0.2.1 · current"),
                    ScreenRow(tone: .note, key: "checkout", value: "no riskell checkout found: pass --repo PATH to check the build"),
                    ScreenRow(tone: .warn, key: "freshness", value: "a source file is newer than the binary",
                              hint: (cmd: "risk dev", note: "rebuild and restart")),
                ]),
                ScreenSection(title: "running app", rows: [
                    ScreenRow(tone: .crit, key: "socket", value: "~/.cache/riskell/ev.sock does not answer",
                              hint: (cmd: "risk dev", note: "start it from this checkout")),
                    ScreenRow(tone: .ok, key: "atoms", value: "11 on top, bottom, left · none need a service"),
                    ScreenRow(tone: .ok, key: "window manager",
                              value: "OmniWM · subscribed, state reaches the bars live, and this value is long enough to wrap"),
                ]),
            ])
        let healthy = Report(
            version: "0.2.1", macOS: "27.2", chip: "Apple silicon", windowManager: "OmniWM",
            state: .running("running · pid 67123 · up 3d 4h"),
            sections: [
                ScreenSection(title: "build", rows: [
                    ScreenRow(tone: .ok, key: "binary", value: "built · 0.2.1 · current"),
                    ScreenRow(tone: .ok, key: "app bundle", value: "up to date with the release binary"),
                    ScreenRow(tone: .ok, key: "freshness", value: "the binary is newer than every source file"),
                    ScreenRow(tone: .ok, key: "version", value: "0.2.1, the binary is current"),
                ]),
                ScreenSection(title: "system", rows: [
                    ScreenRow(tone: .ok, key: "macOS", value: "27.2"),
                    ScreenRow(tone: .ok, key: "chip", value: "Apple silicon"),
                    ScreenRow(tone: .ok, key: "swift", value: "Swift 6.1.2, Command Line Tools"),
                    ScreenRow(tone: .ok, key: "Spaces", value: "one Space on the main display"),
                    ScreenRow(tone: .ok, key: "signing", value: "the riskell-dev identity is present"),
                    ScreenRow(tone: .ok, key: "verified", value: "macOS 27.2 is the version riskell was verified against"),
                ]),
                ScreenSection(title: "install", rows: [
                    ScreenRow(tone: .ok, key: "launch agent", value: "com.rish.riskell is loaded"),
                    ScreenRow(tone: .ok, key: "agent plist", value: "runs ~/.local/bin/risk"),
                    ScreenRow(tone: .ok, key: "risk link", value: "~/.local/bin/risk"),
                    ScreenRow(tone: .ok, key: "PATH", value: "the PATH block is in ~/.zshrc"),
                    ScreenRow(tone: .ok, key: "homebrew", value: "no Homebrew plist left over"),
                ]),
                ScreenSection(title: "files", rows: [
                    ScreenRow(tone: .ok, key: "config.json", value: "~/.config/riskell/config.json is there"),
                    ScreenRow(tone: .note, key: "layout.json", value: "no ~/.config/riskell/layout.json: the built-in layout is used"),
                    ScreenRow(tone: .ok, key: "instance lock", value: "held by the running riskell"),
                ]),
                ScreenSection(title: "running app", rows: [
                    ScreenRow(tone: .ok, key: "socket", value: "~/.cache/riskell/ev.sock answers"),
                    ScreenRow(tone: .ok, key: "process", value: "pid 67123, riskell 0.2.1"),
                    ScreenRow(tone: .ok, key: "services", value: "none: no atom on a showing bar needs one"),
                    ScreenRow(tone: .ok, key: "atoms", value: "5 atoms on top, bottom"),
                ]),
                ScreenSection(title: "window manager", rows: [
                    ScreenRow(tone: .ok, key: "manager", value: "OmniWM running"),
                    ScreenRow(tone: .ok, key: "subscription", value: "OmniWM is subscribed"),
                    ScreenRow(tone: .ok, key: "protocol", value: "OmniWM 0.4.2, protocol 3, is the verified version"),
                    ScreenRow(tone: .ok, key: "settings", value: "every setting riskell needs is as verified (6)"),
                    ScreenRow(tone: .ok, key: "gaps", value: "left, right, bottom and top are the values riskell wrote"),
                ]),
                ScreenSection(title: "permissions", rows: [
                    ScreenRow(tone: .ok, key: "accessibility", value: "granted"),
                    ScreenRow(tone: .ok, key: "location", value: "granted: Wi-Fi names can be shown"),
                ]),
                ScreenSection(title: "gestures", rows: [
                    ScreenRow(tone: .ok, key: "conflicts", value: "no macOS or window-manager gesture competes"),
                    ScreenRow(tone: .ok, key: "trackpad", value: "attached after the last wake, 412 frames read"),
                    ScreenRow(tone: .ok, key: "scroll guard", value: "tap installed, 3 scrolls dropped"),
                ]),
                ScreenSection(title: "log", rows: [
                    ScreenRow(tone: .ok, key: "errors", value: "no error in the last 40 lines"),
                ]),
            ])
        guard let repo else {
            skip("the status screen: no checkout found (pass --repo)")
            return
        }
        let dir = repo.appendingPathComponent("Tests/cli/golden")
        func rendered(_ report: Report, _ glyphs: Glyphs, width: Int = 80, all: Bool = false) -> String {
            let tty = Tty(mode: .none, width: width, palette: DoctorScreen.palette(), glyphs: glyphs, isInteractive: false)
            return DoctorScreen.render(report: report, tty: tty, all: all).joined(separator: "\n") + "\n"
        }
        func recorded(_ name: String, _ what: String, _ got: String) {
            let file = dir.appendingPathComponent(name)
            guard let want = try? String(contentsOf: file, encoding: .utf8) else {
                check(what, false, "no Tests/cli/golden/\(name): record it")
                return
            }
            check(what, want == got, want == got ? "" : "Tests/cli/golden/\(name) differs from the screen")
        }
        recorded("status-screen.txt", "the status screen is as recorded", rendered(report, .unicode, all: true))
        recorded("status-screen-ascii.txt", "the status screen in plain ASCII is as recorded", rendered(report, .ascii, all: true))
        recorded("status-compact.txt", "the compact status screen is as recorded", rendered(healthy, .unicode))
        recorded("status-compact-ascii.txt", "the compact status screen in plain ASCII is as recorded", rendered(healthy, .ascii))
        recorded("status-compact-problems.txt", "the compact status screen with a warning and a failure is as recorded",
                 rendered(report, .unicode))

        // the compact screen is one glance: a healthy machine fits 24 lines at a normal width, and at 44 columns a section's keys wrap
        // onto the next line instead of being cut, so the keys never reach past the terminal
        let wide = rendered(healthy, .unicode).split(separator: "\n", omittingEmptySubsequences: false).count - 1
        check("the compact status screen fits a 24-line terminal", wide <= 24, "\(wide) lines at 72 columns")
        let narrow = rendered(healthy, .unicode, width: 44).components(separatedBy: "\n")
        let keys = narrow.drop { !$0.isEmpty }.dropFirst().prefix { !$0.isEmpty }
        check("the compact status screen wraps its keys at 44 columns and cuts none",
              keys.count > healthy.sections.count && keys.allSatisfy { $0.count <= 44 },
              "\(keys.count) lines, \(keys.map(\.count).max() ?? 0) columns")
    }

    /// `--bundle`: the archive carries the report and the last 200 log lines, and the redaction its header lists is applied to both, so a
    /// home path, a token, a workspace id and a secret do not reach it.
    static func bundle() {
        let home = "/Users/example"
        let report = """
        {"schema":1,"generatedAt":"2026-01-01T00:00:00Z","running":{"pid":4242,"version":"0.2.1"},
         "path":"\(home)/.cache/riskell/riskell.log","token":"sk-abcdefghijklmnop",
         "workspace":"wrk_01KQXAMPLE01","note":"the session secret is hunter2"}
        """
        var log = (1...250).map { "line \($0)" }
        log[199] = "wrote \(home)/.cache/riskell/overview.png"
        log[200] = "Authorization: sk-abcdefghijklmnop"
        log[201] = "opencode wrk_01KQXAMPLE01 read"
        log[202] = "password hunter2"
        let dir = tempDir("report")
        guard let tarball = try? Doctor.writeBundle(dir.path, json: report, log: log, home: home, generated: Date()) else {
            check("a bundle is written", false)
            return
        }
        let name = tarball.lastPathComponent.replacingOccurrences(of: ".tar.gz", with: "")
        let listing = Detect.run("/usr/bin/tar", ["tzf", tarball.path], quiet: true) ?? ""
        check("the bundle holds the report and the log", listing.contains("\(name)/report.json") && listing.contains("\(name)/log.txt"))
        let json = Detect.run("/usr/bin/tar", ["-xOzf", tarball.path, "\(name)/report.json"], quiet: true) ?? ""
        let tail = Detect.run("/usr/bin/tar", ["-xOzf", tarball.path, "\(name)/log.txt"], quiet: true) ?? ""
        check("the report in the bundle is the JSON report",
              ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])?["schema"] as? Int == 1)
        check("a home path in the report is written ~", json.contains("~/.cache/riskell/riskell.log") && !json.contains(home))
        check("no token, id or secret reaches the report",
              ["sk-abcdefghijklmnop", "wrk_01KQXAMPLE01", "hunter2"].allSatisfy { !json.contains($0) })
        check("the log tail is the last 200 lines", tail.contains("line 250") && tail.contains("line 51") && !tail.contains("line 50"))
        check("a home path in a log line is written ~", tail.contains("~/.cache/riskell/overview.png") && !tail.contains(home))
        check("no token, id or secret reaches the log",
              ["sk-abcdefghijklmnop", "wrk_01KQXAMPLE01", "hunter2"].allSatisfy { !tail.contains($0) })
        check("the header says what a bundle leaves out", tail.contains("keychain items"))
    }

    /// A scheme's colours as a palette; the four tokens the installer's data does not carry stay mid grey.
    private static func palette(_ s: SchemeData) -> Palette {
        Palette(hex: ["bg": s.bg, "tile": s.tile, "text1": s.text1, "text2": s.text2, "text3": s.text3, "text4": s.text4,
                      "accent": s.accent, "ok": s.ok, "warn": s.warn, "crit": s.crit, "info": s.info])
    }
}
