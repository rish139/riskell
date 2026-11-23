// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `risk help [command]`: the front door and per-command help, drawn by the kit from the command table. Styled on a terminal; a pipe gets
/// the same text with no escape sequences. Nothing is ever wider than the terminal (COLUMNS, else 80): the kit wraps a description under
/// itself, so a reader never loses a word.
enum HelpScreen {
    /// Prints the front door with no name, one command when a name is given (an alias works too), or the group's subcommands. 0 when it
    /// printed, 2 for a name the table does not know. `--unknown <word>` draws the wrapper's unknown-command error, also exit 2.
    static func run(_ args: [String]) -> Int32 {
        let tty = Terminal.tty()
        if args.first == "--unknown" { return fail(tty, title: "unknown command '\(args.dropFirst().joined(separator: " "))'") }
        let name = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { print(frontDoor(tty).joined(separator: "\n")); return 0 }
        if let row = command(named: name) { print(detail(tty, row).joined(separator: "\n")); return 0 }
        if !subcommands(of: name).isEmpty { print(group(tty, name).joined(separator: "\n")); return 0 }
        let head = String(name.split(separator: " ").first ?? "")      // `risk help ext add`: the pass-through's own page lists add
        if let row = command(named: head) { print(detail(tty, row).joined(separator: "\n")); return 0 }
        if !subcommands(of: head).isEmpty { print(group(tty, head).joined(separator: "\n")); return 0 }
        return fail(tty, title: "no command \"\(name)\"")
    }

    /// The error a name the table does not know prints: the kit's shape, on stderr, exit 2.
    private static func fail(_ tty: Tty, title: String) -> Int32 {
        let lines = tty.errorBlock(title: title, detail: nil, tries: [(cmd: "risk help", note: "every command")])
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return 2
    }

    // MARK: screens

    /// The four groups of the front door, in the order a reader meets them.
    private static let groupOrder = ["RUN", "LOOK", "CHANGE", "EXTEND"]

    /// The name and version, the agent's state, the one line that says what risk is, the user CLI in its four groups, then the two ways to
    /// read more. A row with no group and front line (`completions`, `help`) is not on the front door; `risk help <name>` still prints it.
    private static func frontDoor(_ tty: Tty) -> [String] {
        let groups = groupOrder.map { title in
            (title: title, rows: commandTable.compactMap { row in
                row.group == title ? row.front.map { (name: row.name, text: $0) } : nil
            })
        }
        var out = tty.masthead(version: version() ?? "", lines: ["a desktop shell for macOS: bars, cards and extensions"], state: agentState())
        out.append("")
        out += tty.commandList(groups)
        out.append("")
        out.append(tty.footerHint([(cmd: "risk help <command>", text: "for one"), (cmd: "docs/CLI.md", text: "for all")]))
        return out
    }

    /// One command: its synopsis and one-liner, then its aliases, example and what it replaces, then its subcommands when it has any.
    /// A developer command says what it is under the summary: it still runs, but it is not part of the user CLI.
    private static func detail(_ tty: Tty, _ row: Command) -> [String] {
        var fields: [(String, [String])] = []
        if !row.aliases.isEmpty { fields.append(("aliases", [row.aliases.joined(separator: ", ")])) }
        fields.append(("example", [row.example]))
        if !row.otherReplaces.isEmpty { fields.append(("replaces", row.otherReplaces)) }
        let children = row.children.map { ($0.name, $0.summary) }
        var lines = tty.detail(usage: row.usage, summary: row.summary, fields: fields, children: children)
        if row.tier == .dev { lines.insert("  " + tty.dim(devNote), at: endOfSummary(lines)) }
        return [tty.header("help " + row.display), ""] + lines
    }

    /// A group such as `gestures` that has no row of its own: its subcommands, one per line.
    private static func group(_ tty: Tty, _ name: String) -> [String] {
        [tty.header("help " + name), ""] + tty.detail(usage: "\(name) <subcommand>", summary: "pick one; risk help <command> prints its flags and example.",
                   fields: [], children: subcommands(of: name).map { ($0.name, $0.summary) })
    }

    /// The line a developer command keeps under its summary, in the dimmest text.
    private static let devNote = "developer command: not part of the user CLI"

    /// Where a command's summary block ends: the blank line the kit keeps between the summary and the fields.
    private static func endOfSummary(_ lines: [String]) -> Int {
        guard let afterUsage = lines.firstIndex(of: ""),
              let afterSummary = lines[(afterUsage + 1)...].firstIndex(of: "") else { return lines.count }
        return afterSummary
    }

    // MARK: the agent

    /// The launch agent's label, as `scripts/risk install` writes it under `~/Library/LaunchAgents`.
    private static let agentLabel = "com.rish.riskell"

    /// The bar behind this command, as the masthead draws it: `running, pid 123`, `stopped`, or `state unknown` when the agent is installed
    /// but will not say. Cheap and never waiting on riskell: a live event socket answers with its peer pid at once (no word is written), the
    /// plist is a stat, and only an agent that is installed but silent costs one local `launchctl print`. riskell itself is never run, and a
    /// missing `launchctl` costs only the line.
    private static func agentState() -> MastheadState {
        let socket = cacheDir() + "/ev.sock"
        if let pid = peerPid(at: socket) { return .running("running · pid \(pid)") }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? homePath()
        let plist = home + "/Library/LaunchAgents/\(agentLabel).plist"
        guard FileManager.default.fileExists(atPath: plist) else { return .stopped("stopped") }
        // installed but not loaded: launchd says which, and one that cannot be asked leaves the state unknown
        guard let report = launchctlPrint() else { return .unknown("state unknown") }
        if let pid = runningPid(report) { return .running("running · pid \(pid)") }
        return .stopped("stopped")
    }

    /// `launchctl print` for this user's agent: what launchd says, or nil when `launchctl` is missing or the service is not loaded.
    private static func launchctlPrint() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(agentLabel)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The `pid = 123` line of a `launchctl print` report: a top-level value sits one tab in, and the nested endpoint blocks are deeper.
    private static func runningPid(_ report: String) -> pid_t? {
        for line in report.split(separator: "\n") where line.hasPrefix("\tpid = ") {
            return pid_t(line.dropFirst("\tpid = ".count))
        }
        return nil
    }

    /// The pid of the process serving the event socket, or nil when nothing is: a connect and one `getsockopt`, no handshake and no word.
    private static func peerPid(at path: String) -> pid_t? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, length) } }
        guard connected == 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }
}
