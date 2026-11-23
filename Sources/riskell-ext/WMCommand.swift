// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `riskell-ext wm use <omniwm|aerospace|none>`: switch the window-manager backend in one step, and back again. It changes riskell's own
/// `wm` setting (through the code `risk config set` uses) and starts or quits the two manager apps. It never reads or writes either
/// manager's own settings or config files, so switching back always finds them as they were. Without `--yes` it only prints the plan.
///
///   wm use <omniwm|aerospace|none> [--yes] [--dry-run] [--restart] [--login] [--json]
///
/// Exit status: 0 done, planned or already on that backend; 1 a step failed; 2 bad usage. Nothing here needs a rebuild, so 10 is not used.
enum WMCommand {
    static let schema = "riskell.wm-use/1"

    /// The manager apps, by the value of `wm` that selects them.
    private static let apps: [(backend: String, name: String)] = [("omniwm", "OmniWM"), ("aerospace", "AeroSpace")]

    static func run(_ args: [String]) -> Int32 {
        guard args.first == "use" else {
            return Usage.error("wm use", args.first.map { "\"\($0)\" is not handled here; this is wm use" } ?? "wm use <omniwm|aerospace|none>")
        }
        var yes = false, restart = false, login = false, json = false
        var backend: String?
        for arg in args.dropFirst() {
            switch arg {
            case "--yes": yes = true
            case "--dry-run": yes = false
            case "--restart": restart = true
            case "--login": login = true
            case "--json": json = true
            default:
                guard !arg.hasPrefix("-") else { return Usage.error("wm use", "no flag \"\(arg)\"") }
                guard backend == nil else { return Usage.error("wm use", "name one backend") }
                backend = arg
            }
        }
        guard let backend, backend == "none" || apps.contains(where: { $0.backend == backend }) else {
            return Usage.error("wm use", "name a backend: omniwm, aerospace or none")
        }
        // A dry run is the default: `--dry-run` and `--yes` together stay a dry run.
        if args.contains("--dry-run") { yes = false }

        let target = apps.first { $0.backend == backend }
        let others = apps.filter { $0.backend != backend }
        let current = ConfigCommand.string("wm") ?? "auto"
        let already = current == backend
        let loginNow = loginApp()
        let loginWant = target?.backend
        let changesLogin = login && loginNow != (loginWant ?? "none")

        var rows: [(verb: String, text: String, satisfied: Bool)] = []
        rows.append((verb: "set", text: "wm = \(backend) in the riskell config (now \(current))", satisfied: already))
        if !already {
            for other in others {
                rows.append((verb: "quit", text: "\(other.name), if it is running", satisfied: !isRunning(other.name)))
            }
            if let target { rows.append((verb: "open", text: target.name, satisfied: isRunning(target.name))) }
        }
        if login {
            rows.append((verb: "set", text: "\(loginWant.flatMap { name(of: $0) } ?? "no window manager") to start at login",
                         satisfied: !changesLogin))
        }
        let loginLine = "starts at login: \(loginNow == "none" ? "neither" : name(of: loginNow) ?? loginNow)"
        var failures: [String] = []
        var restarted = false

        if yes {
            if !already {
                if ConfigCommand.store("wm", backend) != 0 { return 1 }
                for other in others where isRunning(other.name) {
                    if !quit(other.name) { failures.append("could not quit \(other.name)") }
                }
                if let target, !isRunning(target.name), !open(target.name) { failures.append("could not open \(target.name)") }
            }
            if changesLogin, !setLogin(target.map { "/Applications/\($0.name).app" } ?? "off") {
                failures.append("could not change what starts at login")
            }
            if restart, failures.isEmpty { restarted = restartAgent(quietOut: json) }
            if restart, !restarted, failures.isEmpty { failures.append("risk restart failed") }
        }

        let nowLogin = yes ? loginApp() : loginNow
        if json {
            let list = failures.map(jsonQuoted).joined(separator: ", ")
            print("{\"schema\": \(jsonQuoted(schema)), \"wm\": \(jsonQuoted(backend)), \"was\": \(jsonQuoted(current)), " +
                  "\"changed\": \(yes && !already), \"dryRun\": \(!yes), \"already\": \(already), \"restarted\": \(restarted), " +
                  "\"login\": \(jsonQuoted(nowLogin)), \"loginChanged\": \(yes && changesLogin && failures.isEmpty), \"errors\": [\(list)]}")
            return failures.isEmpty ? 0 : 1
        }

        let tty = Terminal.tty()
        print(tty.header("wm use \(backend)", detail: yes ? nil : "dry run") + "\n")
        if yes {
            if already { print("wm is already \(backend); nothing to switch.") } else { print("wm \(current) → \(backend)") }
            for line in failures { print("failed: \(line)") }
        } else {
            print(tty.plan(rows, note: "dry run, nothing changed; add --yes to switch").joined(separator: "\n"))
        }
        print(loginLine + (login ? "" : " (--login changes it)"))
        if failures.isEmpty && !restarted && (!already || !yes) {
            print("run `risk restart` for riskell to pick up the change (or add --restart).")
        } else if restarted {
            print("riskell restarted.")
        }
        for line in failures { FileHandle.standardError.write(Data(("risk wm use: \(line)\n").utf8)) }
        return failures.isEmpty ? 0 : 1
    }

    private static func name(of backend: String) -> String? { apps.first { $0.backend == backend }?.name }

    // MARK: the apps

    private static func isRunning(_ app: String) -> Bool {
        run("/usr/bin/pgrep", ["-x", app]).status == 0
    }

    /// Quits the way a person would (the app saves and closes), then waits up to ten seconds for it to be gone.
    private static func quit(_ app: String) -> Bool {
        guard run("/usr/bin/osascript", ["-e", "tell application \"\(app)\" to quit"]).status == 0 else { return false }
        for _ in 0..<50 {
            if !isRunning(app) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private static func open(_ app: String) -> Bool {
        run("/usr/bin/open", ["-a", app]).status == 0
    }

    // MARK: start at login

    private static var loginPlist: String {
        (ProcessInfo.processInfo.environment["HOME"] ?? homePath()) + "/Library/LaunchAgents/com.rish.wm.plist"
    }

    /// Which manager riskell's agent opens at login: `omniwm`, `aerospace`, `other` for an app it does not know, or `none`.
    private static func loginApp() -> String {
        guard let text = try? String(contentsOfFile: loginPlist, encoding: .utf8) else { return "none" }
        for app in apps where text.contains("/\(app.name).app") { return app.backend }
        return text.contains(".app") ? "other" : "none"
    }

    /// The agent is written by `scripts/risk`, which owns launchd: `__step wm-login <app path>|off`.
    private static func setLogin(_ target: String) -> Bool {
        let root = ProcessInfo.processInfo.environment["RISKELL_ROOT"] ?? FileManager.default.currentDirectoryPath
        return run(root + "/scripts/risk", ["__step", "wm-login", target]).status == 0
    }

    private static func restartAgent(quietOut: Bool) -> Bool {
        let root = ProcessInfo.processInfo.environment["RISKELL_ROOT"] ?? FileManager.default.currentDirectoryPath
        return run(root + "/scripts/risk", ["dev"], passThrough: !quietOut).status == 0
    }

    private static func run(_ program: String, _ arguments: [String], passThrough: Bool = false) -> (status: Int32, output: String) {
        guard FileManager.default.isExecutableFile(atPath: program) else { return (127, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = passThrough ? FileHandle.standardOutput : pipe
        process.standardError = passThrough ? FileHandle.standardError : pipe
        do { try process.run() } catch { return (127, "") }
        let data = passThrough ? Data() : pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
