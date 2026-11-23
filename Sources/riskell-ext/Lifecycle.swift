// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `riskell-ext lifecycle`: the screens and the order for `risk install`, `risk dev` and `risk uninstall`. The mechanics stay in
/// `scripts/risk`, behind its internal `__step <name>` command: this file decides which steps happen, draws each one with the kit's
/// `Progress`, and turns a failure into the one error shape every command prints.
///
/// A step is a quiet program: it writes nothing when it succeeds, its diagnostics on failure, and its exit code is the failure. Every
/// step's output is captured, never streamed, so the screen stays the screen's. `RISKELL_STEPS` points at another program for tests
/// (it is called with the step name and nothing else); without it the steps are `scripts/risk __step <name>`.
///
///   riskell-ext lifecycle install [--no-build] [--dry-run]
///   riskell-ext lifecycle dev [--no-launch] [--dry-run]
///   riskell-ext lifecycle uninstall [--dry-run] [--yes]
enum Lifecycle {
    static let label = "com.rish.riskell"

    /// What one step did: its exit code and everything it wrote, both streams together.
    struct StepResult {
        let status: Int32
        let output: String
    }

    static func run(_ args: [String]) -> Int32 {
        guard let command = args.first else { return usage("--", "no command: install, dev or uninstall") }
        let flags = Array(args.dropFirst())
        if ["install", "dev", "uninstall"].contains(command) {
            print(Terminal.tty().header(command, detail: flags.contains("--dry-run") ? "dry run" : nil) + "\n")
        }
        switch command {
        case "install": return install(flags)
        case "dev": return dev(flags)
        case "uninstall": return uninstall(flags)
        default: return usage("--", "unknown command \"\(command)\": install, dev or uninstall")
        }
    }

    // MARK: install

    private static func install(_ flags: [String]) -> Int32 {
        if let bad = unknown(flags, beside: ["--no-build", "--dry-run"]) { return usage("install", "no flag \"\(bad)\"") }
        let dryRun = flags.contains("--dry-run")
        let noBuild = flags.contains("--no-build")
        let tty = Terminal.tty()

        if dryRun {
            let loaded = probe("loaded")
            let bundled = probe("bundled")
            var rows: [(verb: String, text: String, satisfied: Bool)] = []
            if !noBuild { rows.append((verb: "build", text: "the release binary and the app bundle", satisfied: false)) }
            rows.append((verb: "write", text: "the login agent at \(plistPath)", satisfied: bundled && plistIsPresent()))
            rows.append((verb: "load", text: "it with launchd, so riskell runs now and at login", satisfied: loaded))
            print(tty.plan(rows, note: "dry run, nothing changed").joined(separator: "\n"))
            return 0
        }

        var steps: [String] = noBuild ? [] : ["build"]
        steps += ["write", "load"]
        let progress = RiskellTTY.Progress(tty: tty, steps: steps)
        var index = 0
        if !noBuild {
            let result = perform(progress, index, "build")
            if result.status != 0 { return failed(tty, "build", result, progress, index) }
            progress.finish(index, .ok, detail: "built")
            index += 1
        }
        let plist = perform(progress, index, "plist")
        if plist.status != 0 { return failed(tty, "write", plist, progress, index) }
        progress.finish(index, .ok, detail: "wrote the login agent")
        index += 1
        let reload = perform(progress, index, "reload")
        if reload.status != 0 { return failed(tty, "load", reload, progress, index) }
        progress.finish(index, .ok, detail: "loaded the login agent")
        progress.done(summary: runningSummary)
        return 0
    }

    // MARK: dev

    private static func dev(_ flags: [String]) -> Int32 {
        if let bad = unknown(flags, beside: ["--no-launch", "--dry-run"]) { return usage("dev", "no flag \"\(bad)\"") }
        let dryRun = flags.contains("--dry-run")
        let noLaunch = flags.contains("--no-launch")
        let tty = Terminal.tty()
        let loaded = probe("loaded")
        let bundled = probe("bundled")

        if dryRun {
            var rows: [(verb: String, text: String, satisfied: Bool)] = [
                (verb: "build", text: "the release binary and the app bundle", satisfied: false),
            ]
            if !noLaunch {
                if !loaded {
                    rows.append((verb: "write", text: "the login agent at \(plistPath)", satisfied: false))
                    rows.append((verb: "load", text: "it with launchd, so riskell starts now and at login", satisfied: false))
                } else if !bundled {
                    rows.append((verb: "write", text: "the login agent at \(plistPath)", satisfied: false))
                    rows.append((verb: "load", text: "it with launchd, so the agent runs the app bundle", satisfied: false))
                } else {
                    rows.append((verb: "restart", text: "the agent\(pidText)", satisfied: false))
                }
            }
            print(tty.plan(rows, note: "dry run, nothing changed").joined(separator: "\n"))
            return 0
        }

        if noLaunch {
            let progress = RiskellTTY.Progress(tty: tty, steps: ["build"])
            let result = perform(progress, 0, "build")
            if result.status != 0 { return failed(tty, "build", result, progress, 0) }
            progress.finish(0, .ok, detail: "built")
            progress.done(summary: "built; --no-launch left the agent alone")
            return 0
        }

        // The wrapper's three cases, kept: nothing loaded, loaded but pointing elsewhere, or the agent already runs the bundle.
        let reinstalls = !loaded || !bundled
        let steps = reinstalls ? ["build", "write", "load"] : ["build", "restart"]
        let notBundled = !loaded ? "no agent was running: installed one" : "moved the agent into the app bundle"
        let progress = RiskellTTY.Progress(tty: tty, steps: steps)
        var index = 0
        let build = perform(progress, index, "build")
        if build.status != 0 { return failed(tty, "build", build, progress, index) }
        progress.finish(index, .ok, detail: "built")
        index += 1
        if reinstalls {
            let plist = perform(progress, index, "plist")
            if plist.status != 0 { return failed(tty, "write", plist, progress, index) }
            progress.finish(index, .ok, detail: "wrote the login agent")
            index += 1
            let reload = perform(progress, index, "reload")
            if reload.status != 0 { return failed(tty, "load", reload, progress, index) }
            progress.finish(index, .ok, detail: notBundled)
        } else {
            let kickstart = perform(progress, index, "kickstart")
            if kickstart.status != 0 { return failed(tty, "restart", kickstart, progress, index) }
            progress.finish(index, .ok, detail: "restarted the agent")
        }
        progress.done(summary: restartSummary)
        return 0
    }

    // MARK: uninstall

    private static func uninstall(_ flags: [String]) -> Int32 {
        // --all and --keep-config were advertised but the wrapper never implemented them: they are accepted and ignored, and the row no
        // longer offers them.
        if let bad = unknown(flags, beside: ["--dry-run", "--yes", "--all", "--keep-config"]) { return usage("uninstall", "no flag \"\(bad)\"") }
        let dryRun = flags.contains("--dry-run")
        let yes = flags.contains("--yes")
        let tty = Terminal.tty()

        if dryRun {
            let loaded = probe("loaded")
            let rows: [(verb: String, text: String, satisfied: Bool)] = [
                (verb: "stop", text: "the agent\(loaded ? pidText : "")", satisfied: !loaded),
                (verb: "remove", text: "the login agent at \(plistPath)", satisfied: !plistIsPresent()),
            ]
            print(tty.plan(rows, note: "dry run, nothing changed").joined(separator: "\n"))
            return 0
        }

        if !yes {
            guard let answer = tty.confirm("stop riskell and remove its login agent?", default: false) else {
                printError(tty.errorBlock(title: "uninstall needs --yes",
                                          detail: "there is no terminal to ask on, and uninstall stops riskell and removes its login agent.",
                                          tries: [(cmd: "risk uninstall --yes", note: "stop riskell and remove its login agent")]))
                return 2
            }
            guard answer else {
                print(tty.empty("cancelled; nothing changed", hint: nil).joined(separator: "\n"))
                return 0
            }
        }

        let progress = RiskellTTY.Progress(tty: tty, steps: ["stop", "remove"])
        let stop = perform(progress, 0, "stop")
        if stop.status != 0 { return failed(tty, "stop", stop, progress, 0) }
        progress.finish(0, .ok, detail: "stopped the agent")
        let remove = perform(progress, 1, "unplist")
        if remove.status != 0 { return failed(tty, "remove", remove, progress, 1) }
        progress.finish(1, .ok, detail: "removed the login agent")
        progress.done(summary: "stopped")
        return 0
    }

    // MARK: the steps

    /// Run one step under the progress line. The screen's label (`write`, `load`) and the shell's step (`plist`, `reload`) differ: this
    /// file names what the reader sees, scripts/risk keeps the name of the work.
    private static func perform(_ progress: RiskellTTY.Progress, _ index: Int, _ step: String) -> StepResult {
        progress.begin(index)
        return run(step)
    }

    /// Start the step's program and read both streams to the end. Reading before waiting keeps a chatty step (a Swift build) from filling
    /// the pipe and stopping.
    private static func run(_ step: String) -> StepResult {
        let env = ProcessInfo.processInfo.environment
        let program: String
        let arguments: [String]
        if let override = env["RISKELL_STEPS"], !override.isEmpty {
            program = override
            arguments = [step]
        } else {
            let root = env["RISKELL_ROOT"] ?? FileManager.default.currentDirectoryPath
            program = root + "/scripts/risk"
            arguments = ["__step", step]
        }
        guard FileManager.default.isExecutableFile(atPath: program) else {
            return StepResult(status: 127, output: "\(program) is not executable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return StepResult(status: 127, output: "\(program): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return StepResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// A read-only probe: `loaded`, `bundled` succeed when the answer is yes.
    private static func probe(_ step: String) -> Bool {
        run(step).status == 0
    }

    /// The agent's pid, waiting a moment after a restart for launchd to have one. nil when there is no pid to read.
    private static func pid() -> Int? {
        for attempt in 0..<20 {
            let result = run("pid")
            if result.status == 0, let value = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) { return value }
            if attempt < 19 { Thread.sleep(forTimeInterval: 0.1) }
        }
        return nil
    }

    /// `running · pid N`, or just `running` when launchd has not reported a pid.
    private static var runningSummary: String {
        if let value = pid() { return "running · pid \(value)" }
        return "running"
    }

    /// `restarted · pid N`, the last line of a dev run.
    private static var restartSummary: String {
        if let value = pid() { return "restarted · pid \(value)" }
        return "restarted"
    }

    /// `(pid N)` for a plan row about an agent that is loaded.
    private static var pidText: String {
        if let value = pid() { return " (pid \(value))" }
        return ""
    }

    // MARK: the screen

    /// A failed step: its own line says which one, then the one error shape every command prints. The 12 last lines are the detail,
    /// because that is the part a build or launchd error puts the reason in.
    private static func failed(_ tty: Tty, _ step: String, _ result: StepResult, _ progress: RiskellTTY.Progress, _ index: Int) -> Int32 {
        progress.finish(index, .crit, detail: "failed")
        printError(tty.errorBlock(title: "\(step) failed", detail: tail(result.output),
                                  tries: [(cmd: "risk status", note: "see what else is off")]))
        return 1
    }

    /// The last 12 non-empty lines, in one sentence: `errorBlock` wraps it under its title.
    private static func tail(_ output: String) -> String? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(12).joined(separator: " ")
    }

    private static func printError(_ lines: [String]) {
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func usage(_ command: String, _ problem: String) -> Int32 {
        return Usage.error(command == "--" ? "install" : command, problem)
    }

    private static func unknown(_ flags: [String], beside allowed: [String]) -> String? {
        flags.first { $0.hasPrefix("-") && !allowed.contains($0) }
    }

    // MARK: the login agent

    /// The agent's plist. Printed with `~` so a screen never depends on whose home it is, and a golden is the same on every machine.
    private static let plistPath = "~/Library/LaunchAgents/\(label).plist"

    /// The real path, from HOME when the shell names one: homePath() ignores it, and the tests use a scratch home.
    private static var absolutePlistPath: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? homePath()
        return (home as NSString).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Whether the agent's plist is there now. A dry run only reads it, to say a step is already done.
    private static func plistIsPresent() -> Bool {
        FileManager.default.fileExists(atPath: absolutePlistPath)
    }
}
