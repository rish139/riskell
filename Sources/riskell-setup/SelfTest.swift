import Foundation

/// `riskell-setup --self-test`: unit-style checks with PASS / FAIL lines, no XCTest (the package builds with Command Line Tools only).
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("PASS \(name)")
        } else {
            failures += 1
            print("FAIL \(name)\(detail.isEmpty ? "" : ": " + detail)")
        }
    }

    static func run(repo: URL?) -> Int32 {
        configMerge()
        presets(repo: repo)
        geocode()
        shellPath()
        detection()
        arguments()
        themes()
        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private static func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("riskell-setup-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
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
            print("SKIP riskell --dump checks: no checkout found (pass --repo)")
            return
        }
        let binary = repo.appendingPathComponent(".build/release/riskell")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            print("SKIP riskell --dump checks: build riskell first (swift build -c release)")
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

    static func themes() {
        check("eleven schemes ship", schemeData.count == 11)
        check("exactly one scheme is the default", schemeData.filter { $0.isDefault }.count == 1)
        check("the default is gruvbox dark medium", schemeData.first { $0.isDefault }?.id == "gruvbox-dark-medium")
        check("hex parses", Ink.parseHex("#fabd2f")?.0 == 250)
        check("256-colour fallback maps pure white to the top of the palette", Ink.nearest256(255, 255, 255) >= 231)
        check("NO_COLOR forces mono", Ink.detectMode(env: ["NO_COLOR": "1", "COLORTERM": "truecolor"]) == .mono)
        check("truecolor is detected", Ink.detectMode(env: ["COLORTERM": "truecolor"]) == .truecolor)
    }
}
