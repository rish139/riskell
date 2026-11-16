import Foundation

/// What the install will do, decided on the review screen. Nothing is written until the engine runs.
struct Plan {
    var paths: Paths
    var repo: URL
    var agentLabel: String
    /// Owned config.json keys: a value sets the key, nil removes it.
    var owned: [(String, Any?)]
    /// The layout.json text to write, or nil to keep the file as it is.
    var layoutText: String?
    var layoutLabel: String
    var gesturesFix: Bool
    var noLaunch: Bool
    var noBuild: Bool
    /// The folder of the risk link is not on PATH: add it to the shell start-up files (ShellPath.swift).
    var addPath: Bool
}

/// Progress from the engine, delivered on the main thread (TUI) or printed (--yes).
enum JobEvent {
    case stepStart(Int)
    case stepLog(Int, String)
    case stepDone(Int, String)
    case stepSkipped(Int, String)
    case failed(Int, String, [String])
    case finished([String])
}

let stepNames = ["Build riskell", "Write config.json", "Write layout.json", "Trackpad gestures", "Link risk", "Start the launch agent", "Health check"]

/// Runs a command and streams its output lines to `log`. Returns the exit status and the last lines of output.
@discardableResult
func runStreaming(_ path: String, _ args: [String], cwd: URL?, log: @escaping (String) -> Void) -> (status: Int32, tail: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.currentDirectoryURL = cwd
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    var tail: [String] = []
    var partial = Data()
    do { try p.run() } catch { return (127, ["could not start \(path)"]) }
    let handle = pipe.fileHandleForReading
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        partial.append(chunk)
        while let nl = partial.firstIndex(where: { $0 == 0x0a || $0 == 0x0d }) {
            let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            partial.removeSubrange(partial.startIndex...nl)
            if line.isEmpty { continue }
            tail.append(line)
            if tail.count > 12 { tail.removeFirst() }
            log(line)
        }
    }
    p.waitUntilExit()
    return (p.terminationStatus, tail)
}

/// Builds riskell in the background while the user answers the questions. `wait()` returns when the build has finished.
final class Builder {
    private let done = DispatchSemaphore(value: 0)
    private(set) var ok = false
    private(set) var tail: [String] = []
    private(set) var seconds = 0.0

    func start(repo: URL, log: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = Date()
            let r = runStreaming("/usr/bin/env", ["swift", "build", "-c", "release", "--product", "riskell"], cwd: repo, log: log)
            self.ok = r.status == 0
            self.tail = r.tail
            self.seconds = Date().timeIntervalSince(t0)
            self.done.signal()
        }
    }

    func wait() {
        done.wait()
        done.signal()
    }
}

/// The install engine: seven steps in order, each reporting through `post`. Runs on a background thread.
enum Installer {
    struct StepError: Error {
        let message: String
        let tail: [String]
    }

    static func run(_ plan: Plan, builder: Builder?, post: @escaping (JobEvent) -> Void) {
        var details: [String] = []
        for i in 0..<stepNames.count {
            post(.stepStart(i))
            do {
                let (detail, skipped) = try step(i, plan, builder: builder, log: { post(.stepLog(i, $0)) })
                if skipped { post(.stepSkipped(i, detail)) } else { post(.stepDone(i, detail)) }
                details.append("\(stepNames[i]): \(detail)")
            } catch let e as StepError {
                post(.failed(i, e.message, e.tail))
                return
            } catch {
                post(.failed(i, "\(error)", []))
                return
            }
        }
        post(.finished(details))
    }

    private static func step(_ i: Int, _ plan: Plan, builder: Builder?, log: @escaping (String) -> Void) throws -> (String, Bool) {
        let fm = FileManager.default
        switch i {
        case 0:
            guard let b = builder else {
                return (plan.noBuild ? "skipped (--no-build)" : "skipped, the build is current", true)
            }
            log("waiting for the build...")
            b.wait()
            guard b.ok else { throw StepError(message: "swift build failed", tail: b.tail) }
            return (String(format: "built in %.0f s", b.seconds), false)

        case 1:
            let existing: [String: Any]?
            switch ConfigIO.readObject(plan.paths.config()) {
            case .success(let o): existing = o
            case .failure(let e): throw StepError(message: "\(e)", tail: ["fix the file or move it aside, then run the setup again"])
            }
            let backup = try ConfigIO.backup(plan.paths.config())
            let merged = ConfigIO.merge(existing, owned: plan.owned)
            do { try ConfigIO.writeAtomic(plan.paths.config(), try ConfigIO.pretty(merged)) } catch {
                throw StepError(message: "could not write config.json", tail: ["\(error)"])
            }
            var detail = "merged \(plan.owned.count) owned keys, your other keys are kept"
            if let b = backup { detail += "; backup " + b.lastPathComponent }
            return (detail, false)

        case 2:
            guard let text = plan.layoutText else { return ("kept your layout.json", true) }
            let backup = try ConfigIO.backup(plan.paths.layout())
            do { try ConfigIO.writeAtomic(plan.paths.layout(), text) } catch {
                throw StepError(message: "could not write layout.json", tail: ["\(error)"])
            }
            var detail = plan.layoutLabel
            if let b = backup { detail += "; backup " + b.lastPathComponent }
            return (detail, false)

        case 3:
            guard plan.gesturesFix else { return ("left as they are", true) }
            let bin = plan.repo.appendingPathComponent(".build/release/riskell").path
            let r = runStreaming(bin, ["--gestures-fix", "--yes"], cwd: plan.repo, log: log)
            guard r.status == 0 else { throw StepError(message: "could not turn the gestures off", tail: r.tail) }
            return ("off, originals saved (undo: riskell --gestures-restore --yes)", false)

        case 4:
            if plan.noLaunch { return ("skipped (--no-launch)", true) }
            let target = plan.repo.appendingPathComponent("scripts/risk")
            let (dir, onPath) = Detect.linkDir(plan.paths)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let link = dir.appendingPathComponent("risk")
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path), dest == target.path {
                return ("already linked at \(link.path)", true)
            }
            if fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try? fm.removeItem(at: link)
            }
            do { try fm.createSymbolicLink(at: link, withDestinationURL: target) } catch {
                throw StepError(message: "could not link risk into \(dir.path)", tail: ["\(error)"])
            }
            if !onPath && plan.addPath {
                let done = ShellPath.add(dir: dir, paths: plan.paths)
                done.forEach { log($0) }
                return ("\(link.path); \(dir.path) added to PATH, open a new terminal to use it", false)
            }
            return (onPath ? "\(link.path)" : "\(link.path); add \(dir.path) to PATH to use it everywhere", false)

        case 5:
            if plan.noLaunch { return ("skipped (--no-launch)", true) }
            let r = runStreaming(plan.repo.appendingPathComponent("scripts/risk").path, ["install"], cwd: plan.repo, log: log)
            guard r.status == 0 else { throw StepError(message: "scripts/risk install failed", tail: r.tail) }
            return ("written and started", false)

        default:
            if plan.noLaunch { return ("skipped (--no-launch)", true) }
            return try health(plan)
        }
    }

    /// The agent is loaded, the socket appears, and the log has no fatal line. Waits up to 8 s for the socket.
    static func health(_ plan: Plan) throws -> (String, Bool) {
        let uid = Detect.run("/usr/bin/id", ["-u"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "501"
        let loaded = Detect.run("/bin/launchctl", ["print", "gui/\(uid)/\(plan.agentLabel)"], quiet: true) != nil
        guard loaded else { throw StepError(message: "the launch agent is not loaded", tail: ["run: risk status"]) }
        var socket = false
        for _ in 0..<16 where !socket {
            socket = FileManager.default.fileExists(atPath: plan.paths.socket().path)
            if !socket { Thread.sleep(forTimeInterval: 0.5) }
        }
        let logText = (try? String(contentsOf: plan.paths.log(), encoding: .utf8)) ?? ""
        let recent = logText.split(separator: "\n").suffix(40)
        let bad = recent.filter { $0.lowercased().contains("fatal") || $0.lowercased().contains("error") }
        guard socket else { throw StepError(message: "riskell started but its socket did not appear", tail: ["run: risk log 30"]) }
        guard bad.isEmpty else { throw StepError(message: "the log shows an error", tail: Array(bad.suffix(4)).map(String.init)) }
        return ("running, socket up, no errors in the log", false)
    }

    /// Stops riskell and removes its agent and the `risk` link. Config is removed only when `removeConfig` is set.
    static func uninstall(paths: Paths, label: String, removeConfig: Bool, restoreGestures: Bool, repo: URL?, log: @escaping (String) -> Void) -> [String] {
        var lines: [String] = []
        let uid = Detect.run("/usr/bin/id", ["-u"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "501"
        runStreaming("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], cwd: nil, log: log)
        try? FileManager.default.removeItem(at: paths.agentPlist(label))
        lines.append("stopped and removed the launch agent")
        for dir in [paths.localBin(), URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")] {
            let link = dir.appendingPathComponent("risk")
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), dest.hasSuffix("scripts/risk") {
                try? FileManager.default.removeItem(at: link)
                lines.append("removed \(link.path)")
            }
        }
        lines += ShellPath.remove(paths: paths)
        if restoreGestures, let repo = repo, FileManager.default.fileExists(atPath: paths.gestureBackup().path) {
            let r = runStreaming(repo.appendingPathComponent(".build/release/riskell").path, ["--gestures-restore", "--yes"], cwd: repo, log: log)
            lines.append(r.status == 0 ? "restored your trackpad gestures" : "could not restore the gestures: run riskell --gestures-restore --yes")
        }
        if removeConfig {
            try? FileManager.default.removeItem(at: paths.configDir())
            lines.append("removed ~/.config/riskell")
        } else {
            lines.append("kept ~/.config/riskell (your settings)")
        }
        return lines
    }
}
