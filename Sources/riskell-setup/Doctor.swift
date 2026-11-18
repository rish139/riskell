import Darwin
import Foundation

/// One row of the health report. `id` is the contract (`build.binary` in the JSON, stable across versions); `label` is what a person reads.
struct ReportCheck {
    /// What a row says about this Mac. `info` is "nothing to check here", never a problem.
    enum Severity: String {
        case ok, warn, fail, info

        /// How bad it is, so a section's status is the worst of its rows.
        var rank: Int {
            switch self {
            case .ok: return 0
            case .info: return 1
            case .warn: return 2
            case .fail: return 3
            }
        }
    }

    /// Where the fact came from: probed here (`cli`), read from a file (`file`), or asked of the running bars over the socket (`app`).
    enum Origin: String { case cli, app, file }

    let id: String
    let label: String
    let severity: Severity
    let detail: String
    /// The next thing to do when the row is not ok; a fix is always given for a `fail`.
    var fix: String? = nil
    let source: Origin
}

struct ReportSection {
    let id: String
    let title: String
    let checks: [ReportCheck]

    /// The worst row in the section; an empty section is ok.
    var status: ReportCheck.Severity {
        var worst = ReportCheck.Severity.ok
        for c in checks where c.severity.rank > worst.rank { worst = c.severity }
        return worst
    }

    var firstFailure: ReportCheck? { checks.first { $0.severity == .fail } }
}

/// A JSON value written in the order it is added. The report's keys are a contract, and JSONSerialization neither keeps their order nor
/// leaves `/` and non-ASCII alone; this escapes only `"`, `\` and the control characters.
indirect enum JSON {
    case text(String)
    case number(Int)
    case flag(Bool)
    case null
    case list([JSON])
    case object([(String, JSON)])

    /// Pretty, two spaces, one trailing newline.
    func rendered(_ indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent), inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .text(let s): return JSON.quoted(s)
        case .number(let n): return String(n)
        case .flag(let b): return b ? "true" : "false"
        case .null: return "null"
        case .list(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { inner + $0.rendered(indent + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            return "{\n" + pairs.map { inner + JSON.quoted($0.0) + ": " + $0.1.rendered(indent + 1) }.joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    /// A decoded JSON value (the app's answer, plists) as this one, with the keys of an object sorted so two runs compare equal.
    static func value(_ any: Any) -> JSON {
        if let n = any as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .flag(n.boolValue) : .number(n.intValue)
        }
        if let s = any as? String { return .text(s) }
        if let a = any as? [Any] { return .list(a.map { value($0) }) }
        if let d = any as? [String: Any] { return .object(d.keys.sorted().map { ($0, value(d[$0]!)) }) }
        return .null
    }
}

/// `riskell-setup --doctor [--json] [--bundle DIR]`, which `risk status` runs: one health report in ten sections, in the order a person
/// meets a broken bar (build, system, install, files, running app, window manager, permissions, gestures, log, verdict). Everything the
/// installer's checklist already probes is reused; what only the running bars can see (the manager's live subscription, verified versions,
/// gap drift, permissions, the trackpad) is asked for over the event socket instead of guessed. Read-only, with no waiting loop.
enum Doctor {
    /// The report's shape: bump it when a key moves or changes meaning (the app's answer has its own, AppStatus.schema).
    static let schema = 1

    // MARK: run

    static func run(_ o: Options, paths: Paths, repo: URL?, label: String) -> Int32 {
        let generated = Date()
        let facts = Detect.gather(paths, label: label)
        let app = ask(paths)
        let c = Context(paths: paths, repo: repo, label: label, facts: facts, app: app,
                        socketExists: FileManager.default.fileExists(atPath: paths.socket().path),
                        wake: lastWake(), generated: generated, log: logTail(paths.log(), 400))
        var sections = [build(c), system(c), install(c), files(c), running(c), windowManager(c), permissions(c), gestures(c), log(c)]
        sections.append(verdict(sections))
        let failed = sections.contains { $0.firstFailure != nil }
        let text = json(sections, c)

        if o.json { print(text) } else { print(render(sections, c), terminator: "") }
        if let dir = o.bundle {
            do {
                let url = try writeBundle(dir, json: text, c)
                FileHandle.standardError.write(Data("wrote \(url.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("riskell-setup: could not write the bundle: \(error)\n".utf8))
                return 1
            }
        }
        return failed ? 1 : 0
    }

    /// Everything the report is built from, probed once.
    private struct Context {
        let paths: Paths
        let repo: URL?
        let label: String
        let facts: Facts
        /// The running bars' answer (Services/AppStatus.swift), nil when nothing answered the socket.
        let app: [String: Any]?
        let socketExists: Bool
        let wake: Date?
        let generated: Date
        let log: [String]

        func short(_ url: URL) -> String { Doctor.shorten(url.path, home: paths.home.path) }
        func short(_ path: String) -> String { Doctor.shorten(path, home: paths.home.path) }
    }

    // MARK: the sections, in display order

    private static func build(_ c: Context) -> ReportSection {
        let title = "build"
        guard let repo = c.repo else {
            return ReportSection(id: "build", title: title, checks: [
                ReportCheck(id: "build.checkout", label: "checkout", severity: .info,
                            detail: "no riskell checkout found: pass --repo PATH to check the build", source: .cli),
            ])
        }
        let release = repo.appendingPathComponent(".build/release/riskell")
        let built = FileManager.default.isExecutableFile(atPath: release.path)
        var checks = [ReportCheck(id: "build.binary", label: "binary", severity: built ? .ok : .fail,
                                  detail: built ? "\(c.short(release)) is built" : "\(c.short(release)) is missing",
                                  fix: built ? nil : "risk dev", source: .file)]
        // what the agent actually runs is the copy inside the app bundle: `swift build` alone does not refresh it
        let bundle = repo.appendingPathComponent(".build/riskell.app/Contents/MacOS/riskell")
        if built, let bundleTime = modified(bundle) {
            let stale = (modified(release) ?? .distantPast) > bundleTime
            checks.append(ReportCheck(id: "build.bundle", label: "app bundle",
                                      severity: stale ? .warn : .ok,
                                      detail: stale ? "the agent runs an older copy than the release binary" : "up to date with the release binary",
                                      fix: stale ? "risk dev" : nil, source: .file))
        }
        let fresh = Detect.buildIsFresh(repo)
        checks.append(ReportCheck(id: "build.freshness", label: "freshness", severity: fresh ? .ok : .warn,
                                  detail: fresh ? "the binary is newer than every source file" : "a source file is newer than the binary",
                                  fix: fresh ? nil : "risk dev", source: .file))
        let versionFile = repo.appendingPathComponent("VERSION")
        let version = ((try? String(contentsOf: versionFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !version.isEmpty, let builtTime = modified(release), let versionTime = modified(versionFile) {
            let stale = versionTime > builtTime
            checks.append(ReportCheck(id: "build.version", label: "version", severity: stale ? .warn : .ok,
                                      detail: stale ? "VERSION says \(version), the binary is older" : "\(version), the binary is current",
                                      fix: stale ? "risk dev" : nil, source: .file))
        } else if !version.isEmpty {
            checks.append(ReportCheck(id: "build.version", label: "version", severity: .info,
                                      detail: "\(version) (nothing built to compare it with)", source: .file))
        }
        return ReportSection(id: "build", title: title, checks: checks)
    }

    private static func system(_ c: Context) -> ReportSection {
        let f = c.facts
        var checks: [ReportCheck] = []
        if let v = f.macos, Detect.macOSAtLeast14(v) {
            checks.append(ReportCheck(id: "system.macos", label: "macOS", severity: .ok, detail: v, source: .cli))
        } else if let v = f.macos {
            checks.append(ReportCheck(id: "system.macos", label: "macOS", severity: .fail,
                                      detail: "\(v): riskell needs macOS 14 or newer", fix: "softwareupdate --list", source: .cli))
        } else {
            checks.append(ReportCheck(id: "system.macos", label: "macOS", severity: .fail,
                                      detail: "not detected: sw_vers did not answer", fix: "sw_vers", source: .cli))
        }
        checks.append(f.arch == "arm64"
            ? ReportCheck(id: "system.chip", label: "chip", severity: .ok, detail: "Apple silicon", source: .cli)
            : ReportCheck(id: "system.chip", label: "chip", severity: .warn, detail: "\(f.arch): not verified on Intel", source: .cli))
        if let s = f.swift {
            checks.append(ReportCheck(id: "system.swift", label: "swift", severity: .ok, detail: "\(s), Command Line Tools", source: .cli))
        } else {
            checks.append(ReportCheck(id: "system.swift", label: "swift", severity: .fail,
                                      detail: "no toolchain: riskell cannot be built", fix: "xcode-select --install", source: .cli))
        }
        // OmniWM drives one desktop; extra macOS Spaces make it jump to the desktop that has the window (measured, HANDOFF)
        switch mainDisplaySpaces() {
        case 1?:
            checks.append(ReportCheck(id: "system.spaces", label: "Spaces", severity: .ok,
                                      detail: "one Space on the main display", source: .cli))
        case let n?:
            checks.append(ReportCheck(id: "system.spaces", label: "Spaces", severity: .warn,
                                      detail: "\(n) Spaces on the main display: a window manager wants exactly one; remove the extra desktops in Mission Control",
                                      source: .cli))
        default:
            checks.append(ReportCheck(id: "system.spaces", label: "Spaces", severity: .info,
                                      detail: "com.apple.spaces could not be read", source: .cli))
        }
        // the local signing identity: without it every rebuild looks like a new app to macOS, so keychain and Location ask again
        let identities = Detect.run("/usr/bin/security", ["find-identity", "-p", "codesigning"], quiet: true) ?? ""
        checks.append(identities.contains("riskell-dev")
            ? ReportCheck(id: "system.identity", label: "signing", severity: .ok,
                          detail: "the riskell-dev identity is present: grants survive a rebuild", source: .cli)
            : ReportCheck(id: "system.identity", label: "signing", severity: .warn,
                          detail: "no riskell-dev certificate: macOS asks again for keychain and Location access after every rebuild (README, Troubleshooting)",
                          source: .cli))
        // the versions riskell was last verified against are the app's, not this probe's
        if let running = str(c.app, "macOS"), let verified = str(c.app, "verifiedMacOS") {
            checks.append(ReportCheck(id: "system.verified", label: "verified", severity: running == verified ? .ok : .warn,
                                      detail: running == verified
                                        ? "macOS \(running) is the version riskell was verified against"
                                        : "UPDATE DUE: macOS \(running), verified \(verified); walk docs/COMPATIBILITY.md",
                                      source: .app))
        } else {
            checks.append(notRunning("system.verified", "verified"))
        }
        return ReportSection(id: "system", title: "system", checks: checks)
    }

    private static func install(_ c: Context) -> ReportSection {
        var checks: [ReportCheck] = []
        checks.append(c.facts.agentLoaded
            ? ReportCheck(id: "install.agent", label: "launch agent", severity: .ok,
                          detail: "\(c.label) is loaded", source: .cli)
            : ReportCheck(id: "install.agent", label: "launch agent", severity: .warn,
                          detail: "\(c.label) is not loaded: riskell does not start at login", fix: "risk install", source: .cli))
        // the agent's own plist: it can point at a build that has moved or been deleted (a renamed checkout, a fresh clone)
        let plist = c.paths.agentPlist(c.label)
        if let program = plistProgram(plist) {
            let there = FileManager.default.fileExists(atPath: program)
            checks.append(ReportCheck(id: "install.plist", label: "agent plist", severity: there ? .ok : .warn,
                                      detail: there ? "runs \(c.short(program))" : "points at \(c.short(program)), which does not exist",
                                      fix: there ? nil : "risk install", source: .file))
        } else {
            checks.append(ReportCheck(id: "install.plist", label: "agent plist", severity: .info,
                                      detail: "no \(c.short(plist)): riskell has not been installed", source: .file))
        }
        // the risk link and the PATH block the installer writes
        if let link = riskLink(c.paths) {
            checks.append(ReportCheck(id: "install.link", label: "risk link", severity: .ok, detail: c.short(link), source: .file))
        } else {
            checks.append(ReportCheck(id: "install.link", label: "risk link", severity: .warn,
                                      detail: "no risk command is linked",
                                      fix: c.repo.map { "\(c.short($0.appendingPathComponent("scripts/risk"))) install" } ?? "scripts/risk install",
                                      source: .file))
        }
        let blocks = ShellPath.files(c.paths).filter { ShellPath.present(in: $0) }.map { c.short($0) }
        let dirOnPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).contains(Detect.linkDir(c.paths).dir.path)
        if !blocks.isEmpty {
            checks.append(ReportCheck(id: "install.path", label: "PATH", severity: .ok, detail: "the PATH block is in \(blocks.joined(separator: ", "))", source: .file))
        } else if dirOnPath {
            checks.append(ReportCheck(id: "install.path", label: "PATH", severity: .ok, detail: "the link folder is on PATH already", source: .cli))
        } else {
            checks.append(ReportCheck(id: "install.path", label: "PATH", severity: .warn,
                                      detail: "no PATH block: a new terminal may not find risk", fix: "risk install", source: .file))
        }
        // a Homebrew formula's agent left behind after the formula (or its Cellar path) went away
        let brew = c.paths.agentPlist("homebrew.mxcl.riskell")
        if let program = plistProgram(brew) {
            let there = FileManager.default.fileExists(atPath: program)
            checks.append(ReportCheck(id: "install.homebrew", label: "homebrew", severity: .warn,
                                      detail: there
                                        ? "a Homebrew plist starts \(c.short(program)) as well as the agent above; two bars fight over the socket"
                                        : "a Homebrew plist points at \(c.short(program)), which does not exist",
                                      fix: there ? "launchctl bootout gui/\(uid())/homebrew.mxcl.riskell" : "brew services stop riskell",
                                      source: .file))
        } else {
            checks.append(ReportCheck(id: "install.homebrew", label: "homebrew", severity: .ok,
                                      detail: "no Homebrew plist left over", source: .file))
        }
        return ReportSection(id: "install", title: "install", checks: checks)
    }

    private static func files(_ c: Context) -> ReportSection {
        var checks: [ReportCheck] = []
        let config = c.paths.config()
        switch ConfigIO.readObject(config) {
        case .success(let obj?):
            let keys = obj.keys.sorted()
            checks.append(ReportCheck(id: "files.config", label: "config.json", severity: .ok,
                                      detail: keys.isEmpty ? "\(c.short(config)) is empty" : "\(c.short(config)): \(keys.joined(separator: ", "))",
                                      source: .file))
        case .success(nil):
            checks.append(ReportCheck(id: "files.config", label: "config.json", severity: .info,
                                      detail: "no \(c.short(config)): riskell runs on its defaults", source: .file))
        case .failure(let e):
            checks.append(ReportCheck(id: "files.config", label: "config.json", severity: .warn,
                                      detail: "\(e): riskell sets it aside and writes a new one",
                                      fix: "mv \(c.short(config)) \(c.short(config.path)).bak", source: .file))
        }
        let layout = c.paths.layout()
        switch ConfigIO.readObject(layout) {
        case .success(let obj?):
            checks.append(ReportCheck(id: "files.layout", label: "layout.json", severity: .ok,
                                      detail: "\(c.short(layout)): \(obj.keys.sorted().joined(separator: ", "))", source: .file))
        case .success(nil):
            checks.append(ReportCheck(id: "files.layout", label: "layout.json", severity: .info,
                                      detail: "no \(c.short(layout)): the built-in layout is used", source: .file))
        case .failure(let e):
            checks.append(ReportCheck(id: "files.layout", label: "layout.json", severity: .warn,
                                      detail: "\(e): the built-in layout is used",
                                      fix: "mv \(c.short(layout)) \(c.short(layout.path)).bak", source: .file))
        }
        // riskell writes OmniWM's outer gaps itself (Services/Gaps.swift) and keeps the file it found next to them: after that, a hand
        // edit of gaps.outer is drift, which the window manager section reports
        let omniSettings = URL(fileURLWithPath: settingsPath(c.paths))
        let gapsBackup = URL(fileURLWithPath: omniSettings.path + ".bak-riskell-gaps")
        if FileManager.default.fileExists(atPath: gapsBackup.path) {
            checks.append(ReportCheck(id: "files.gaps", label: "omniwm gaps", severity: .info,
                                      detail: "riskell writes gaps.outer; the file it replaced is \(c.short(gapsBackup))", source: .file))
        } else if FileManager.default.fileExists(atPath: omniSettings.path) {
            checks.append(ReportCheck(id: "files.gaps", label: "omniwm gaps", severity: .info,
                                      detail: "riskell has not written OmniWM's outer gaps yet: it does on the first run with OmniWM", source: .file))
        } else {
            checks.append(ReportCheck(id: "files.gaps", label: "omniwm gaps", severity: .info,
                                      detail: "OmniWM has no settings.toml: no gaps to keep", source: .file))
        }
        // the instance lock: held means one riskell owns the bars, and if the socket is silent as well, that is a second or hung one
        let lock = c.paths.home.appendingPathComponent(".cache/riskell/riskell.lock")
        if !lockHeld(lock) {
            checks.append(ReportCheck(id: "files.lock", label: "instance lock", severity: .ok,
                                      detail: "nobody holds \(c.short(lock))", source: .file))
        } else if c.app != nil {
            checks.append(ReportCheck(id: "files.lock", label: "instance lock", severity: .info,
                                      detail: "held by the running riskell, as it should be", source: .file))
        } else {
            checks.append(ReportCheck(id: "files.lock", label: "instance lock", severity: .warn,
                                      detail: "\(c.short(lock)) is held but nothing answers the socket: a hung or second riskell",
                                      fix: "risk restart", source: .file))
        }
        return ReportSection(id: "files", title: "files", checks: checks)
    }

    private static func running(_ c: Context) -> ReportSection {
        var checks: [ReportCheck] = []
        let socket = c.paths.socket()
        if c.app != nil {
            checks.append(ReportCheck(id: "running.socket", label: "socket", severity: .ok, detail: "\(c.short(socket)) answers", source: .file))
        } else if c.socketExists {
            checks.append(ReportCheck(id: "running.socket", label: "socket", severity: .warn,
                                      detail: "\(c.short(socket)) exists but does not answer the doctor word: the running build is older than this check",
                                      fix: "risk dev", source: .file))
        } else if c.facts.agentLoaded {
            checks.append(ReportCheck(id: "running.socket", label: "socket", severity: .fail,
                                      detail: "\(c.short(socket)) is missing: riskell is loaded but not listening", fix: "risk log 30", source: .file))
        } else {
            checks.append(ReportCheck(id: "running.socket", label: "socket", severity: .info,
                                      detail: "no socket: riskell is not running", source: .file))
        }
        if let pid = int(c.app, "pid") {
            checks.append(ReportCheck(id: "running.process", label: "process", severity: .ok,
                                      detail: "pid \(pid), riskell \(str(c.app, "version") ?? "?")", source: .app))
        } else {
            checks.append(notRunning("running.process", "process"))
        }
        let checkout = c.repo.map { ((try? String(contentsOf: $0.appendingPathComponent("VERSION"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if let version = str(c.app, "version"), !checkout.isEmpty {
            let same = version == checkout
            checks.append(ReportCheck(id: "running.version", label: "running version", severity: same ? .ok : .warn,
                                      detail: same ? "riskell \(version) is the checkout's version" : "the bar runs \(version), the checkout is \(checkout)",
                                      fix: same ? nil : "risk dev", source: .app))
        } else if c.app != nil {
            checks.append(ReportCheck(id: "running.version", label: "running version", severity: .info,
                                      detail: "the bar did not report its version", source: .app))
        } else {
            checks.append(notRunning("running.version", "running version"))
        }
        if c.app != nil {
            let services = strings(c.app, "services")
            checks.append(ReportCheck(id: "running.services", label: "services", severity: .ok,
                                      detail: services.isEmpty ? "none: no atom on a showing bar needs one" : services.joined(separator: " "),
                                      source: .app))
            let bars = strings(c.app, "bars"), atoms = int(c.app, "atoms") ?? 0
            checks.append(ReportCheck(id: "running.atoms", label: "atoms", severity: .ok,
                                      detail: "\(atoms) atom(s) on \(bars.isEmpty ? "no bar" : bars.joined(separator: ", "))", source: .app))
        } else {
            checks.append(notRunning("running.services", "services"))
            checks.append(notRunning("running.atoms", "atoms"))
        }
        return ReportSection(id: "running", title: "running app", checks: checks)
    }

    private static func windowManager(_ c: Context) -> ReportSection {
        var checks: [ReportCheck] = []
        let found = c.facts.wms.filter { $0.installed || $0.running }
        if found.isEmpty {
            checks.append(ReportCheck(id: "wm.manager", label: "manager", severity: .warn,
                                      detail: "none found: the bars float over your windows", source: .cli))
        }
        for w in found {
            checks.append(ReportCheck(id: "wm.manager", label: "manager", severity: w.running ? .ok : .warn,
                                      detail: w.running ? "\(w.name) running" : "\(w.name) installed, not running",
                                      fix: w.running ? nil : startCommand(w.name), source: .cli))
        }
        guard let app = c.app else {
            return ReportSection(id: "wm", title: "window manager", checks: checks + [
                notRunning("wm.subscription", "subscription"),
                notRunning("wm.protocol", "protocol"),
                notRunning("wm.settings", "settings"),
                notRunning("wm.gaps", "gaps"),
            ])
        }
        let name = str(app, "wm") ?? "none"
        if name == "none" {
            checks.append(ReportCheck(id: "wm.subscription", label: "subscription", severity: .info,
                                      detail: "no window manager backend: nothing to subscribe to", source: .app))
        } else if bool(app, "wmSubscribed") == true {
            checks.append(ReportCheck(id: "wm.subscription", label: "subscription", severity: .ok,
                                      detail: "\(name) is subscribed: its state reaches the bars live", source: .app))
        } else {
            checks.append(ReportCheck(id: "wm.subscription", label: "subscription", severity: .warn,
                                      detail: "\(name) is not subscribed: riskell retries every 2 s while it is away", fix: "risk log 30", source: .app))
        }
        let protocolVersion = int(app, "wmProtocol").map { ", protocol \($0)" } ?? ""
        let verifiedWM = str(app, "verifiedOmniwm") ?? "", runningWM = str(app, "omniwm") ?? ""
        if name == "none" {
            checks.append(ReportCheck(id: "wm.protocol", label: "protocol", severity: .info,
                                      detail: "no window manager backend", source: .app))
        } else if runningWM.isEmpty {
            checks.append(ReportCheck(id: "wm.protocol", label: "protocol", severity: .warn,
                                      detail: "\(name)'s version is unknown: its app bundle is missing", source: .app))
        } else {
            let same = runningWM == verifiedWM
            checks.append(ReportCheck(id: "wm.protocol", label: "protocol", severity: same ? .ok : .warn,
                                      detail: same ? "\(name) \(runningWM)\(protocolVersion) is the verified version"
                                                   : "UPDATE DUE: \(name) \(runningWM)\(protocolVersion), verified \(verifiedWM); walk docs/COMPATIBILITY.md",
                                      source: .app))
        }
        checks.append(settingsRow(app, c.paths))
        checks.append(gapsRow(app, c.paths))
        return ReportSection(id: "wm", title: "window manager", checks: checks)
    }

    /// The OmniWM settings riskell depends on: a mismatch is a breakage, not an update (Compat.Verified.omniwmSettings).
    private static func settingsRow(_ app: [String: Any], _ paths: Paths) -> ReportCheck {
        let rows = list(app, "settings")
        guard !rows.isEmpty else {
            return ReportCheck(id: "wm.settings", label: "settings", severity: .info,
                               detail: "OmniWM has no settings file to compare", source: .app)
        }
        let wrong = rows.filter { (str($0, "want") ?? "") != (str($0, "actual") ?? "") }
        guard !wrong.isEmpty else {
            return ReportCheck(id: "wm.settings", label: "settings", severity: .ok,
                               detail: "every setting riskell needs is as verified (\(rows.count))", source: .app)
        }
        let what = wrong.map { "\(str($0, "key") ?? "?") = \(str($0, "actual") ?? "missing") (want \(str($0, "want") ?? "?"))" }
        return ReportCheck(id: "wm.settings", label: "settings", severity: .fail,
                           detail: what.joined(separator: "; "),
                           fix: "open -e \(Doctor.shorten(settingsPath(paths), home: paths.home.path))",
                           source: .app)
    }

    /// OmniWM's settings file: the one `Compat` and `Gaps` in the app write, under the same home.
    private static func settingsPath(_ paths: Paths) -> String {
        paths.home.appendingPathComponent(".config/omniwm/settings.toml").path
    }

    /// The outer gaps: riskell writes them from the bars that are on, so a difference means the file was changed afterwards.
    private static func gapsRow(_ app: [String: Any], _ paths: Paths) -> ReportCheck {
        let rows = list(app, "gaps")
        guard !rows.isEmpty else {
            return ReportCheck(id: "wm.gaps", label: "gaps", severity: .info,
                               detail: "no gaps to compare: OmniWM's settings file is missing", source: .app)
        }
        let wrong = rows.filter { (str($0, "want") ?? "") != (str($0, "actual") ?? "") }
        guard !wrong.isEmpty else {
            return ReportCheck(id: "wm.gaps", label: "gaps", severity: .ok,
                               detail: "left, right, bottom and top are the values riskell wrote", source: .app)
        }
        let what = wrong.map { "\(str($0, "key") ?? "?") = \(str($0, "actual") ?? "missing") (want \(str($0, "want") ?? "?"))" }
        return ReportCheck(id: "wm.gaps", label: "gaps", severity: .warn,
                           detail: what.joined(separator: "; ") + ": something changed the file after riskell wrote it",
                           fix: "risk dev", source: .app)
    }

    private static func permissions(_ c: Context) -> ReportSection {
        let gesturesOurs = gesturesAreRiskells(c)
        var checks: [ReportCheck] = []
        if c.app == nil {
            checks.append(notRunning("permissions.accessibility", "accessibility"))
            checks.append(notRunning("permissions.location", "location"))
            return ReportSection(id: "permissions", title: "permissions", checks: checks)
        }
        let trusted = bool(c.app, "accessibility") == true
        if !gesturesOurs {
            checks.append(ReportCheck(id: "permissions.accessibility", label: "accessibility", severity: .info,
                                      detail: "not needed: the trackpad gestures are macOS's own", source: .app))
        } else if trusted {
            checks.append(ReportCheck(id: "permissions.accessibility", label: "accessibility", severity: .ok,
                                      detail: "granted: the scroll guard may drop the scrolls three fingers make", source: .app))
        } else {
            checks.append(ReportCheck(id: "permissions.accessibility", label: "accessibility", severity: .fail,
                                      detail: "not granted: three-finger swipes leak into the window under the pointer as scrolls",
                                      fix: "open \"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility\"", source: .app))
        }
        switch str(c.app, "location") {
        case "ok":
            checks.append(ReportCheck(id: "permissions.location", label: "location", severity: .ok,
                                      detail: "granted: Wi-Fi names can be shown", source: .app))
        case "none":
            checks.append(ReportCheck(id: "permissions.location", label: "location", severity: .info,
                                      detail: "the bar is not running from its app bundle: Wi-Fi names cannot be shown", source: .app))
        case "asking":
            checks.append(ReportCheck(id: "permissions.location", label: "location", severity: .info,
                                      detail: "not answered yet: macOS asks once, for Wi-Fi names only", source: .app))
        default:
            checks.append(ReportCheck(id: "permissions.location", label: "location", severity: .warn,
                                      detail: "denied: the network card cannot show Wi-Fi names",
                                      fix: "open \"x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices\"", source: .app))
        }
        return ReportSection(id: "permissions", title: "permissions", checks: checks)
    }

    private static func gestures(_ c: Context) -> ReportSection {
        let ours = gesturesAreRiskells(c)
        var checks: [ReportCheck] = []
        // the app's list also carries the window manager's own gestures; without the app, the same macOS keys are read here
        let fromApp = c.app.map { strings($0, "gestureConflicts") }
        let conflicts = (fromApp?.isEmpty == false ? fromApp! : (c.app == nil ? Detect.gestureConflicts() : []))
        let source: ReportCheck.Origin = fromApp == nil ? .cli : .app
        if !ours {
            checks.append(ReportCheck(id: "gestures.conflicts", label: "conflicts", severity: .info,
                                      detail: "the trackpad gestures are macOS's own: nothing of riskell's to fight", source: source))
        } else if conflicts.isEmpty {
            checks.append(ReportCheck(id: "gestures.conflicts", label: "conflicts", severity: .ok,
                                      detail: "no macOS or window-manager gesture competes with riskell's three fingers", source: source))
        } else {
            checks.append(ReportCheck(id: "gestures.conflicts", label: "conflicts", severity: .fail,
                                      detail: conflicts.joined(separator: ", "),
                                      fix: "\(binary(c.repo, c)) --gestures-fix --yes", source: source))
        }
        guard let app = c.app else {
            checks.append(notRunning("gestures.touch", "trackpad"))
            checks.append(notRunning("gestures.scrollguard", "scroll guard"))
            return ReportSection(id: "gestures", title: "gestures", checks: checks)
        }
        // a MultitouchSupport attachment older than the last wake delivers no frames: the swipes, the capsule and the scroll guard's finger
        // count all go quietly dead, which is why Touch re-attaches after a wake
        if let touch = dict(app, "touch") {
            let attachedAt = double(touch, "attachedAt") ?? 0
            let frames = int(touch, "frames") ?? 0
            if let wake = c.wake, attachedAt > 0, attachedAt < wake.timeIntervalSince1970 {
                checks.append(ReportCheck(id: "gestures.touch", label: "trackpad", severity: .warn,
                                          detail: "attached before the last wake (\(frames) frames since): the swipes may be dead",
                                          fix: "printf touch-reattach | nc -U \(c.short(c.paths.socket()))", source: .app))
            } else {
                checks.append(ReportCheck(id: "gestures.touch", label: "trackpad", severity: .ok,
                                          detail: "attached after the last wake, \(frames) frames read", source: .app))
            }
        } else {
            checks.append(ReportCheck(id: "gestures.touch", label: "trackpad", severity: .info,
                                      detail: "not attached: the gestures are off or the trackpad was not found", source: .app))
        }
        let guardState = dict(app, "scrollGuard") ?? [:]
        let tap = bool(guardState, "tap") == true, trusted = bool(guardState, "trusted") == true
        let dropped = int(guardState, "dropped") ?? 0
        if !ours {
            checks.append(ReportCheck(id: "gestures.scrollguard", label: "scroll guard", severity: .info,
                                      detail: "not needed: the gestures are macOS's own", source: .app))
        } else if tap {
            checks.append(ReportCheck(id: "gestures.scrollguard", label: "scroll guard", severity: .ok,
                                      detail: "tap installed, \(dropped) scroll(s) dropped", source: .app))
        } else if !trusted {
            checks.append(ReportCheck(id: "gestures.scrollguard", label: "scroll guard", severity: .info,
                                      detail: "waiting for Accessibility (see permissions): three fingers scroll the window meanwhile", source: .app))
        } else {
            checks.append(ReportCheck(id: "gestures.scrollguard", label: "scroll guard", severity: .warn,
                                      detail: "the event tap is not installed although Accessibility is granted", fix: "risk dev", source: .app))
        }
        return ReportSection(id: "gestures", title: "gestures", checks: checks)
    }

    private static func log(_ c: Context) -> ReportSection {
        let url = c.paths.log()
        guard let size = fileSize(url) else {
            return ReportSection(id: "log", title: "log", checks: [
                ReportCheck(id: "log.errors", label: "errors", severity: .info, detail: "no \(c.short(url)): riskell has not run yet", source: .file),
            ])
        }
        let lines = Array(c.log.suffix(40))
        let errors = lines.filter { $0.lowercased().contains("fatal") || $0.lowercased().contains("error") }
        let when = modified(url).map { ago($0, now: c.generated) } ?? "?"
        if errors.isEmpty {
            return ReportSection(id: "log", title: "log", checks: [
                ReportCheck(id: "log.errors", label: "errors", severity: .ok,
                            detail: "no error in the last \(lines.count) line(s); \(bytes(size)), written \(when) ago", source: .file),
            ])
        }
        return ReportSection(id: "log", title: "log", checks: [
            ReportCheck(id: "log.errors", label: "errors", severity: .fail,
                        detail: "\(errors.count) error line(s) in the last \(lines.count): \(errors.suffix(1).first ?? "")",
                        fix: "risk log 30", source: .file),
        ])
    }

    private static func verdict(_ sections: [ReportSection]) -> ReportSection {
        let all = sections.flatMap(\.checks)
        let fails = all.filter { $0.severity == .fail }, warns = all.filter { $0.severity == .warn }
        guard let first = fails.first else {
            return ReportSection(id: "verdict", title: "verdict", checks: [
                ReportCheck(id: "verdict", label: "verdict", severity: .ok,
                            detail: warns.isEmpty ? "all \(all.count) checks passed" : "no failure among \(all.count) checks, \(warns.count) warning(s)",
                            source: .cli),
            ])
        }
        return ReportSection(id: "verdict", title: "verdict", checks: [
            ReportCheck(id: "verdict", label: "verdict", severity: .fail,
                        detail: "\(fails.count) problem(s) and \(warns.count) warning(s); first is \(first.id): \(first.detail)",
                        fix: first.fix, source: .cli),
        ])
    }

    // MARK: text

    private static func render(_ sections: [ReportSection], _ c: Context) -> String {
        let macos = c.facts.macos ?? "?", pid = int(c.app, "pid").map { ", pid \($0)" } ?? ""
        var out = "riskell doctor: macOS \(macos), \(c.facts.arch)\(pid) · \(stamp(c.generated))\n"
        for s in sections {
            out += "\n\(s.title)\n"
            let width = min(22, max(10, s.checks.map(\.label.count).max() ?? 10))
            for row in s.checks {
                out += "  \(mark(row.severity))  \(padded(row.label, width))\(row.detail)\n"
                if let fix = row.fix, row.severity != .ok, row.severity != .info { out += "      fix: \(fix)\n" }
            }
        }
        return out
    }

    private static func mark(_ s: ReportCheck.Severity) -> String {
        switch s {
        case .ok: return "✓"
        case .warn: return "!"
        case .fail: return "✗"
        case .info: return "·"
        }
    }

    private static func padded(_ s: String, _ n: Int) -> String {
        s.count >= n ? s + "  " : s + String(repeating: " ", count: n - s.count)
    }

    // MARK: JSON

    /// The one object `--json` prints: the shape is a contract, so the keys are always all there and in this order.
    private static func json(_ sections: [ReportSection], _ c: Context) -> String {
        let all = sections.filter { $0.id != "verdict" }.flatMap(\.checks)      // the verdict row repeats them, so it is not counted
        func count(_ s: ReportCheck.Severity) -> JSON { .number(all.filter { $0.severity == s }.count) }
        let failed = all.contains { $0.severity == .fail }
        let firstFailure = all.first { $0.severity == .fail }.map { JSON.text($0.id) } ?? .null
        return JSON.object([
            ("schema", .number(schema)),
            ("generatedAt", .text(iso(c.generated))),
            ("platform", .object([("macos", .text(c.facts.macos ?? "")), ("arch", .text(c.facts.arch))])),
            ("running", .object([
                ("pid", int(c.app, "pid").map { JSON.number($0) } ?? .null),
                ("version", str(c.app, "version").map { JSON.text($0) } ?? .null),
                ("socket", .text(c.short(c.paths.socket()))),
            ])),
            ("ok", .flag(!failed)),
            ("exit", .number(failed ? 1 : 0)),
            ("sections", .list(sections.map { section in
                .object([
                    ("id", .text(section.id)),
                    ("title", .text(section.title)),
                    ("status", .text(section.status.rawValue)),
                    ("checks", .list(section.checks.map { row in
                        var pairs: [(String, JSON)] = [
                            ("id", .text(row.id)),
                            ("label", .text(row.label)),
                            ("severity", .text(row.severity.rawValue)),
                            ("detail", .text(row.detail)),
                        ]
                        if let fix = row.fix { pairs.append(("fix", .text(fix))) }
                        pairs.append(("source", .text(row.source.rawValue)))
                        return .object(pairs)
                    })),
                ])
            })),
            ("app", appJSON(c.app)),
            ("files", filesJSON(c)),
            ("summary", .object([
                ("counts", .object([("ok", count(.ok)), ("warn", count(.warn)), ("fail", count(.fail)), ("info", count(.info))])),
                ("firstFailure", firstFailure),
            ])),
        ]).rendered() + "\n"
    }

    /// The running bars' answer as they sent it, with `reachable` in front so a report without them is not mistaken for a silent one.
    private static func appJSON(_ app: [String: Any]?) -> JSON {
        guard let app else { return .object([("reachable", .flag(false))]) }
        return .object([("reachable", .flag(true))] + app.keys.sorted().map { ($0, JSON.value(app[$0]!)) })
    }

    /// What the files hold: key names only, never a value (a config value can be a place, a folder or an account).
    private static func filesJSON(_ c: Context) -> JSON {
        func object(_ url: URL) -> [(String, JSON)] {
            let read = ConfigIO.readObject(url)
            let exists = FileManager.default.fileExists(atPath: url.path)
            var pairs: [(String, JSON)] = [("path", .text(c.short(url))), ("exists", .flag(exists))]
            switch read {
            case .success(let obj?):
                pairs.append(("valid", .flag(true)))
                pairs.append(("keys", .list(obj.keys.sorted().map { .text($0) })))
            case .success(nil):
                break      // absent: the defaults apply and there is nothing to validate
            case .failure:
                pairs.append(("valid", .flag(false)))
            }
            return pairs
        }
        let logURL = c.paths.log()
        var logPairs: [(String, JSON)] = [("path", .text(c.short(logURL))), ("exists", .flag(FileManager.default.fileExists(atPath: logURL.path)))]
        if let size = fileSize(logURL) { logPairs.append(("bytes", .number(size))) }
        if let when = modified(logURL) { logPairs.append(("modifiedAt", .text(iso(when)))) }
        let lock = c.paths.home.appendingPathComponent(".cache/riskell/riskell.lock")
        return .object([
            ("config", .object(object(c.paths.config()))),
            ("layout", .object(object(c.paths.layout()))),
            ("log", .object(logPairs)),
            ("socket", .object([("path", .text(c.short(c.paths.socket()))), ("exists", .flag(c.socketExists)), ("answers", .flag(c.app != nil))])),
            ("omniwm", .object([
                ("settings", .text(c.short(c.paths.home.appendingPathComponent(".config/omniwm/settings.toml")))),
                ("gapsBackup", .flag(FileManager.default.fileExists(atPath: c.paths.home.appendingPathComponent(".config/omniwm/settings.toml.bak-riskell-gaps").path))),
            ])),
            ("lock", .object([("path", .text(c.short(lock))), ("held", .flag(lockHeld(lock)))])),
        ])
    }

    // MARK: the bundle

    /// One redacted report: `report.json`, `log.txt` (the last 200 lines under a header that says what is left out), as a tar.gz in DIR.
    /// Nothing is written anywhere else, and nothing outside DIR is touched.
    private static func writeBundle(_ dir: String, json: String, _ c: Context) throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = ConfigIO.timestamp()
        let name = "riskell-report-\(stamp)"
        let stage = root.appendingPathComponent(name)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try json.write(to: stage.appendingPathComponent("report.json"), atomically: true, encoding: .utf8)
        var text = header(c.generated) + "\n"
        for line in c.log.suffix(200) { text += redact(line, home: c.paths.home.path) + "\n" }
        try text.write(to: stage.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        let tarball = root.appendingPathComponent(name + ".tar.gz")
        guard Detect.run("/usr/bin/tar", ["-czf", tarball.path, "-C", root.path, name], quiet: true) != nil else {
            throw SetupError("tar could not write \(tarball.lastPathComponent)")
        }
        return tarball
    }

    /// The list of what a bundle never carries, as the archive's own header comment.
    static func header(_ generated: Date) -> String {
        """
        # riskell health report, generated \(iso(generated)).
        # The log tail is included; these are left out on purpose:
        #   keychain items, the OpenCode workspace id and its session cookie, the OmniWM IPC handshake key,
        #   tokens and account ids, hostnames, Wi-Fi network names and access-point identifiers,
        #   window titles and app names, the weather city and its coordinates,
        #   config values (key names only), and every absolute path under the home folder (written ~/...).
        """
    }

    /// A log line with everything a report must not carry taken out: the home folder, an id, a token, a network name or a secret word
    /// removes the line, and the debug lines that print window or app names do too.
    static func redact(_ line: String, home: String) -> String {
        let lower = line.lowercased()
        for word in ["secret", "token", "cookie", "password", "passphrase", "ssid", "bssid", "city", "coordinate", "weather", "lat=", "lon="]
        where lower.contains(word) {
            return "[redacted: the line mentions a credential, a place or a network]"
        }
        for verb in ["overview:", "overview-state:", "overview-snap", "window-order", "center-focused:", "focus-other:", "focus-latency:", "click-other:", "edit-test", "pop-frame"] {
            if lower.hasPrefix(verb) { return "[redacted: \(verb) prints window or app names]" }
        }
        var out = shorten(line, home: home)
        out = replacing(out, #"\bwrk_[A-Za-z0-9]{6,}"#, "wrk_<redacted>")
        out = replacing(out, #"\bsk-[A-Za-z0-9_\-]{8,}"#, "<redacted>")
        out = replacing(out, #"\b[A-Za-z0-9+/_\-]{24,}={0,2}\b"#, "<redacted>")     // a token or a hash
        out = replacing(out, #"\b\d{1,3}(\.\d{1,3}){3}\b"#, "<address>")
        out = replacing(out, #"-?\b\d{1,3}\.\d+,\s*-?\d{1,3}\.\d+\b"#, "<coordinates>")
        out = replacing(out, #"\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b"#, "<address>")
        return out
    }

    /// A path as the report prints it, anywhere in a line: the home folder becomes `~`, so no report carries a user name or a folder
    /// layout. A folder whose name merely starts with the home folder's (`/Users/rish` next to `/Users/rishabh`) is left alone.
    static func shorten(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        let out = path.replacingOccurrences(of: home + "/", with: "~/")
        return out == home ? "~" : out
    }

    private static func replacing(_ text: String, _ pattern: String, _ with: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: with)
    }

    // MARK: probes this report adds

    /// Asks the running bars for the state only they know: the `doctor` word over the event socket, at most a second. nil when nothing
    /// answers (not running, a build older than this check, or a socket that is there but dead).
    static func ask(_ paths: Paths) -> [String: Any]? {
        let socket = paths.socket()
        guard FileManager.default.fileExists(atPath: socket.path) else { return nil }
        guard let out = Detect.run("/bin/sh", ["-c", "printf doctor | /usr/bin/nc -U -w 1 " + quoted(socket.path)], quiet: true),
              let data = out.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj
    }

    /// The macOS Spaces on the main display: a window manager drives one desktop, so a second one makes windows jump between them.
    static func mainDisplaySpaces() -> Int? {
        guard let out = Detect.run("/usr/bin/defaults", ["export", "com.apple.spaces", "-"], quiet: true),
              let data = out.data(using: .utf8),
              let any = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = any as? [String: Any],
              let configuration = plist["SpacesDisplayConfiguration"] as? [String: Any],
              let management = configuration["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]] else { return nil }
        for monitor in monitors where (monitor["Display Identifier"] as? String) == "Main" {
            return (monitor["Spaces"] as? [Any])?.count
        }
        return nil
    }

    /// The last wake, from `kern.waketime`: the trackpad handles that MultitouchSupport gives out do not survive it.
    static func lastWake() -> Date? {
        guard let out = Detect.run("/usr/sbin/sysctl", ["-n", "kern.waketime"], quiet: true),
              let sec = out.range(of: "sec = "),
              let comma = out.range(of: ",", range: sec.upperBound..<out.endIndex),
              let value = Double(out[sec.upperBound..<comma.lowerBound]) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// True while another process holds the instance lock (InstanceLock.swift flocks the same file). Released at once: read only.
    static func lockHeld(_ url: URL) -> Bool {
        var fd = open(url.path, O_RDWR)
        if fd < 0 { fd = open(url.path, O_RDONLY) }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) != 0
    }

    // MARK: small helpers

    private static func notRunning(_ id: String, _ label: String) -> ReportCheck {
        ReportCheck(id: id, label: label, severity: .info, detail: "riskell is not running", source: .app)
    }

    /// Whether riskell owns the trackpad gestures: the app's setting when it answers, else the one in config.json.
    private static func gesturesAreRiskells(_ c: Context) -> Bool {
        (str(c.app, "gestures") ?? (c.facts.existing?["gestures"] as? String) ?? "system") == "riskell"
    }

    /// The binary a fix runs: the checkout's when there is one, else whatever `riskell` resolves to.
    private static func binary(_ repo: URL?, _ c: Context) -> String {
        guard let repo else { return "riskell" }
        let path = repo.appendingPathComponent(".build/release/riskell").path
        return FileManager.default.isExecutableFile(atPath: path) ? c.short(path) : "riskell"
    }

    private static func startCommand(_ wm: String) -> String {
        switch wm {
        case "OmniWM": return "open -a OmniWM"
        case "yabai": return "brew services start yabai"
        case "AeroSpace": return "brew services start aerospace"
        default: return "open -a \(wm)"
        }
    }

    private static func riskLink(_ paths: Paths) -> URL? {
        for dir in [Detect.linkDir(paths).dir, paths.localBin()] {
            let link = dir.appendingPathComponent("risk")
            if FileManager.default.fileExists(atPath: link.path) { return link }
        }
        return nil
    }

    /// The program a launch agent plist runs (its ProgramArguments[0], or Program).
    static func plistProgram(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let any = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = any as? [String: Any] else { return nil }
        if let args = dict["ProgramArguments"] as? [String], let first = args.first { return first }
        return dict["Program"] as? String
    }

    /// The last `count` lines of a file, read from its end so a large log costs one seek.
    static func logTail(_ url: URL, _ count: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        var lines = text.split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }      // the window's first line is half one
        return Array(lines.suffix(count))
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func fileSize(_ url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
    }

    private static func bytes(_ n: Int) -> String {
        n > 1_048_576 ? String(format: "%.1f MB", Double(n) / 1_048_576) : "\(n / 1024) KB"
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h"
    }

    private static func uid() -> String {
        Detect.run("/usr/bin/id", ["-u"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "501"
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }

    // reading the app's answer, which is JSON of unknown shape to this binary
    private static func str(_ o: [String: Any]?, _ key: String) -> String? { o?[key] as? String }
    private static func int(_ o: [String: Any]?, _ key: String) -> Int? { (o?[key] as? NSNumber)?.intValue }
    private static func bool(_ o: [String: Any]?, _ key: String) -> Bool? { (o?[key] as? NSNumber)?.boolValue }
    private static func double(_ o: [String: Any]?, _ key: String) -> Double? { (o?[key] as? NSNumber)?.doubleValue }
    private static func dict(_ o: [String: Any]?, _ key: String) -> [String: Any]? { o?[key] as? [String: Any] }
    private static func list(_ o: [String: Any]?, _ key: String) -> [[String: Any]] { (o?[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
    private static func strings(_ o: [String: Any]?, _ key: String) -> [String] { (o?[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
}
