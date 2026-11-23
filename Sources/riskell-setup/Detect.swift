import Foundation

enum Mark: Equatable { case ok, warn, fail }

/// One line of the welcome checklist.
struct Check: Equatable {
    let mark: Mark
    let label: String
    let detail: String
}

struct WMFact: Equatable {
    let name: String
    let installed: Bool
    let running: Bool
}

/// Everything the flow needs to know about this Mac. Probed once at start; tests and snapshots use `fixture`.
struct Facts {
    var macos: String?
    var arch: String
    var swift: String?
    var configFound = false
    var configInvalid = false
    var existing: [String: Any]?
    var layoutFound = false
    var agentLabel = "com.rish.riskell"
    var agentLoaded = false
    var wms: [WMFact] = []

    static var fixture: Facts {
        var f = Facts(macos: "15.2", arch: "arm64", swift: "Swift 6.1")
        f.configFound = false
        f.wms = [WMFact(name: "OmniWM", installed: true, running: true)]
        return f
    }

    var detectedWM: String? {
        wms.first(where: { $0.running })?.name ?? wms.first(where: { $0.installed })?.name
    }

    /// Riskell needs macOS 14 and the Swift toolchain to build; without them the flow cannot continue.
    var blocked: Bool {
        swift == nil || !(macos.map(Detect.macOSAtLeast14) ?? false)
    }
}

enum Detect {
    static func macOSAtLeast14(_ v: String) -> Bool {
        guard let major = Int(v.split(separator: ".").first ?? "") else { return false }
        return major >= 14
    }

    /// The welcome checklist, in the order the screen shows it.
    static func checks(_ f: Facts) -> [Check] {
        var out: [Check] = []
        if let v = f.macos, macOSAtLeast14(v) {
            out.append(Check(mark: .ok, label: "macOS", detail: v))
        } else if let v = f.macos {
            out.append(Check(mark: .fail, label: "macOS", detail: "\(v): riskell needs macOS 14 or newer"))
        } else {
            out.append(Check(mark: .fail, label: "macOS", detail: "not detected"))
        }
        if f.arch == "arm64" {
            out.append(Check(mark: .ok, label: "chip", detail: "Apple silicon"))
        } else {
            out.append(Check(mark: .warn, label: "chip", detail: "\(f.arch): not verified on Intel"))
        }
        if let s = f.swift {
            out.append(Check(mark: .ok, label: "swift", detail: "\(s), Command Line Tools"))
        } else {
            out.append(Check(mark: .fail, label: "swift", detail: "missing: run xcode-select --install"))
        }
        if f.configInvalid {
            out.append(Check(mark: .warn, label: "settings", detail: "config.json is not valid JSON: it is backed up, then replaced"))
        } else if f.configFound {
            out.append(Check(mark: .ok, label: "settings", detail: "config.json found, your settings will be kept"))
        } else {
            out.append(Check(mark: .ok, label: "settings", detail: "new install, no config.json yet"))
        }
        out.append(f.agentLoaded
            ? Check(mark: .ok, label: "launch agent", detail: "loaded and running")
            : Check(mark: .warn, label: "launch agent", detail: "not loaded yet, starts on install"))
        let found = f.wms.filter { $0.installed || $0.running }
        if found.isEmpty {
            out.append(Check(mark: .warn, label: "window manager", detail: "none found: bars float over your windows"))
        }
        for w in found {
            out.append(w.running
                ? Check(mark: .ok, label: "window manager", detail: "\(w.name) running")
                : Check(mark: .warn, label: "window manager", detail: "\(w.name) installed, not running"))
        }
        return out
    }

    /// Probes the Mac. A few milliseconds of read-only commands; nothing is written.
    static func gather(_ paths: Paths, label: String) -> Facts {
        let macos = run("/usr/bin/sw_vers", ["-productVersion"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let arch = run("/usr/bin/uname", ["-m"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        var swift: String? = nil
        if run("/usr/bin/xcode-select", ["-p"]) != nil, let v = run("/usr/bin/env", ["swift", "--version"]) {
            swift = parseSwiftVersion(v)
        }
        var f = Facts(macos: macos?.isEmpty == false ? macos : nil, arch: arch, swift: swift)
        switch ConfigIO.readObject(paths.config()) {
        case .success(let obj?):
            f.configFound = true
            f.existing = obj
        case .success(nil):
            break
        case .failure:
            f.configFound = true
            f.configInvalid = true
        }
        f.layoutFound = FileManager.default.fileExists(atPath: paths.layout().path)
        f.agentLabel = label
        let uid = run("/usr/bin/id", ["-u"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "501"
        f.agentLoaded = (run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"], quiet: true) != nil)
        f.wms = [
            wmFact("OmniWM", installed: FileManager.default.fileExists(atPath: "/Applications/OmniWM.app"), process: "OmniWM"),
            wmFact("yabai", installed: anyExists(["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]), process: "yabai"),
            wmFact("AeroSpace", installed: anyExists(["/Applications/AeroSpace.app", "/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]), process: "AeroSpace"),
        ]
        return f
    }

    static func wmFact(_ name: String, installed: Bool, process: String) -> WMFact {
        let running = run("/usr/bin/pgrep", ["-x", process], quiet: true) != nil
        return WMFact(name: name, installed: installed || running, running: running)
    }

    static func anyExists(_ paths: [String]) -> Bool {
        paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Runs a tool and returns its stdout, or nil when it fails or is missing.
    @discardableResult
    static func run(_ path: String, _ args: [String], quiet: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = quiet ? Pipe() : FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// "Apple Swift version 6.1.2 (...)" becomes "Swift 6.1.2".
    static func parseSwiftVersion(_ text: String) -> String? {
        guard let r = text.range(of: "Swift version ") else { return nil }
        let v = text[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        return v.isEmpty ? nil : "Swift \(v)"
    }

    /// `defaults read` prints one integer for a boolean or number key.
    static func parseDefaultsInt(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The `label=` line of scripts/risk: the launch agent's name.
    static func parseRiskLabel(_ script: String) -> String? {
        for line in script.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("label=") {
                let v = t.dropFirst("label=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Read-only: the trackpad gestures and Mission Control / App Exposé keys that clash with riskell's own swipe.
    static func gestureConflicts() -> [String] {
        var out: [String] = []
        let trackpads = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        let keys: [(String, String)] = [
            ("TrackpadThreeFingerHorizSwipeGesture", "three-finger swipe between spaces"),
            ("TrackpadThreeFingerVertSwipeGesture", "three-finger swipe up or down"),
            ("TrackpadFourFingerHorizSwipeGesture", "four-finger swipe between spaces"),
            ("TrackpadFourFingerVertSwipeGesture", "four-finger swipe up or down"),
        ]
        for (key, what) in keys where trackpads.contains(where: { readDefault($0, key).map { $0 != 0 } ?? false }) {
            out.append(what)
        }
        if readDefault("com.apple.dock", "showMissionControlGestureEnabled") == 1 { out.append("Mission Control gesture") }
        if readDefault("com.apple.dock", "showAppExposeGestureEnabled") == 1 { out.append("App Exposé gesture") }
        return out
    }

    static func readDefault(_ domain: String, _ key: String) -> Int? {
        run("/usr/bin/defaults", ["read", domain, key], quiet: true).flatMap(parseDefaultsInt)
    }

    /// The repository: the directory holding Package.swift and Sources/riskell. Tried: the flag, then the working
    /// directory and its parents, then the executable's parents.
    static func findRepo(flag: String?) -> URL? {
        if let f = flag {
            let u = URL(fileURLWithPath: f)
            return isRepo(u) ? u : nil
        }
        var starts = [FileManager.default.currentDirectoryPath]
        starts.append(CommandLine.arguments[0])
        for s in starts {
            var u = URL(fileURLWithPath: s).standardizedFileURL
            while true {
                if isRepo(u) { return u }
                let parent = u.deletingLastPathComponent()
                if parent.path == u.path { break }
                u = parent
            }
        }
        return nil
    }

    static func isRepo(_ u: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: u.appendingPathComponent("Package.swift").path)
            && fm.fileExists(atPath: u.appendingPathComponent("Sources/riskell").path)
    }

    /// True when the built binary is newer than every source file, so the build can be skipped.
    static func buildIsFresh(_ repo: URL) -> Bool {
        let bin = repo.appendingPathComponent(".build/release/riskell").path
        guard let binTime = mtime(bin) else { return false }
        var newest = mtime(repo.appendingPathComponent("Package.swift").path) ?? .distantPast
        newest = max(newest, newestUnder(repo.appendingPathComponent("Sources/riskell").path))
        return newest <= binTime
    }

    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func newestUnder(_ dir: String) -> Date {
        var newest = Date.distantPast
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            let p = dir + "/" + name
            var isDir: ObjCBool = false
            fm.fileExists(atPath: p, isDirectory: &isDir)
            let t = isDir.boolValue ? newestUnder(p) : (mtime(p) ?? .distantPast)
            newest = max(newest, t)
        }
        return newest
    }

    /// The directory for the `risk` link: the first of ~/.local/bin, /opt/homebrew/bin, /usr/local/bin that is on PATH and writable.
    static func linkDir(_ paths: Paths) -> (dir: URL, onPath: Bool) {
        let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = pathVar.split(separator: ":").map(String.init)
        let local = paths.localBin()
        for c in [local.path, "/opt/homebrew/bin", "/usr/local/bin"] where dirs.contains(c) {
            if FileManager.default.isWritableFile(atPath: c) { return (URL(fileURLWithPath: c), true) }
        }
        return (local, dirs.contains(local.path))
    }
}
