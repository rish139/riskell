// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `risk help [command]`: the front door and per-command help, rendered from the command table. Styled on a terminal; a pipe gets the same
/// text with no escape sequences. Nothing is ever wider than the terminal (COLUMNS, else 80): a description that does not fit wraps under
/// itself, and a terminal too narrow for a table puts the description on the line below the name, so a reader never loses a word.
enum HelpScreen {
    /// Prints the front door with no name, one command when a name is given (an alias works too), or the group's subcommands. 0 when it
    /// printed, 2 for a name the table does not know.
    static func run(_ args: [String]) -> Int32 {
        let tty = Terminal.tty()
        let name = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { print(frontDoor(tty).joined(separator: "\n")); return 0 }
        if let row = command(named: name) { print(detail(tty, row).joined(separator: "\n")); return 0 }
        if !subcommands(of: name).isEmpty { print(group(tty, name).joined(separator: "\n")); return 0 }
        let head = String(name.split(separator: " ").first ?? "")      // `risk help ext add`: the pass-through's own page lists add
        if let row = command(named: head) { print(detail(tty, row).joined(separator: "\n")); return 0 }
        if !subcommands(of: head).isEmpty { print(group(tty, head).joined(separator: "\n")); return 0 }
        FileHandle.standardError.write(Data("risk: no command \"\(name)\": risk help lists them all\n".utf8))
        return 2
    }

    // MARK: screens

    /// The name and version, the agent's state, the one line that says what risk is, then commands by tier with their one-liners, then
    /// the three commands a first-time reader can start with.
    private static func frontDoor(_ tty: Tty) -> [String] {
        var lines: [String] = []
        let number = version()
        let head = wrap("riskell" + (number.map { " " + $0 } ?? ""), tty.width - 2)
        if head.count == 1, let number {
            lines.append("  " + tty.heading("riskell") + " " + tty.dim(number))
        } else {
            lines.append(contentsOf: head.map { "  " + tty.heading($0) })
        }
        lines.append(contentsOf: agentState(tty))
        lines.append("")
        lines.append(contentsOf: wrap("build it, run it, check it, extend it.", tty.width - 2).map { "  " + $0 })
        lines.append(contentsOf: wrap("risk help <command> for one, docs/CLI.md for all.", tty.width - 2).map { "  " + tty.dim($0) })
        lines.append("")

        // One table for every command, so the columns line up across both tiers; a tier heading is a row of its own.
        let dim = Style(fg: tty.palette.color(.text4, tty.mode))
        let headings = tty.rows(Tier.allCases.map { tier in
            [Cell("  " + tier.rawValue, .left, dim),
             Cell("\(commandTable.filter { $0.tier == tier }.count) commands", .right, Style(bold: true))]
        })
        let rows = commandTable.map { [Cell("    " + $0.display, .left, Style(bold: true)), Cell($0.summary)] }
        let rendered = table(tty, rows, rest: "      ")
        for (section, tier) in Tier.allCases.enumerated() {
            lines.append(headings[section])
            lines.append(contentsOf: commandTable.indices.filter { commandTable[$0].tier == tier }.flatMap { rendered[$0] })
            lines.append("")
        }

        lines.append("  " + tty.dim("start here"))
        for example in ["risk status --json", "risk log 50 --follow", "risk help <command>"] {
            lines.append(contentsOf: marked(tty, example, Style(bold: true)))
        }
        return lines
    }

    /// One command: its synopsis and one-liner, then aliases, tier, example and what it replaces, then its subcommands when it has any.
    private static func detail(_ tty: Tty, _ row: Command) -> [String] {
        let dim = Style(fg: tty.palette.color(.text4, tty.mode)), bold = Style(bold: true)
        var lines = heading(tty, "risk " + row.usage)
        lines.append("")
        lines.append(contentsOf: wrap(row.summary, tty.width - 2).map { "  " + $0 })
        lines.append("")
        var cells: [[Cell]] = []
        if !row.aliases.isEmpty {
            cells.append([Cell("    aliases", .left, dim), Cell(row.aliases.map { "risk " + $0 }.joined(separator: ", "), .left, bold)])
        }
        cells.append([Cell("    tier", .left, dim), Cell(tierText(tty, row.tier))])
        cells.append([Cell("    example", .left, dim), Cell(row.example, .left, bold)])
        for (i, source) in row.otherReplaces.enumerated() {
            cells.append([Cell(i == 0 ? "    replaces" : "", .left, dim), Cell(source, .left, bold)])
        }
        lines.append(contentsOf: table(tty, cells, rest: "      ").flatMap { $0 })
        if !row.children.isEmpty { lines.append(contentsOf: childBlock(tty, row.children)) }
        return lines
    }

    /// A group such as `wm` that has no row of its own: its subcommands, one per line.
    private static func group(_ tty: Tty, _ name: String) -> [String] {
        var lines = heading(tty, "risk \(name) <subcommand>")
        lines.append("")
        lines.append(contentsOf: wrap("pick one; risk help <command> prints its flags and example.", tty.width - 2).map { "  " + tty.dim($0) })
        lines.append(contentsOf: childBlock(tty, subcommands(of: name)))
        return lines
    }

    private static func childBlock(_ tty: Tty, _ children: [Child]) -> [String] {
        var lines = ["", "  " + tty.dim("subcommands")]
        let rows = children.map { [Cell("    " + $0.name, .left, Style(bold: true)), Cell($0.summary)] }
        lines.append(contentsOf: table(tty, rows, rest: "      ").flatMap { $0 })
        return lines
    }

    /// `stable` in the ok tone, `experimental` in the warn tone. No mark: `✓` means a check passed, and a tier is not a check.
    private static func tierText(_ tty: Tty, _ tier: Tier) -> String {
        let token: Palette.Token = tier == .stable ? .ok : .warn
        return tty.styling(tier.rawValue, Style(fg: tty.palette.color(token, tty.mode), bold: true))
    }

    // MARK: layout

    /// A heading on an indented line, wrapped when the terminal is narrow.
    private static func heading(_ tty: Tty, _ text: String) -> [String] {
        wrap(text, tty.width - 2).map { "  " + tty.heading($0) }
    }

    /// An indented line led by the neutral mark, `· text`, wrapped when the terminal is narrow; the rest lines up under the text.
    private static func marked(_ tty: Tty, _ text: String, _ style: Style = .plain) -> [String] {
        var wrapped = wrap(text, tty.width - 4)
        let bullet = tty.tone(Mark.info.rawValue, .info) + " "
        return ["  " + bullet + tty.styling(wrapped.removeFirst(), style)]
            + wrapped.map { "    " + tty.styling($0, style) }
    }

    /// Breaks `text` on spaces into lines no wider than `room`. A single word longer than the room is cut and ends in `…`, the only place a
    /// mark stands in for text.
    private static func wrap(_ text: String, _ room: Int) -> [String] {
        let room = max(1, room)
        var lines: [String] = []
        var line = ""
        for var word in text.split(separator: " ").map(String.init) {
            while word.count > room {
                if !line.isEmpty { lines.append(line); line = "" }
                let take = max(1, room - 1)
                lines.append(String(word.prefix(take)) + (room > 1 ? "…" : ""))
                word = String(word.dropFirst(take))
            }
            if line.isEmpty { line = word }
            else if line.count + 1 + word.count <= room { line += " " + word }
            else { lines.append(line); line = word }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.isEmpty ? [""] : lines
    }

    /// Two columns of styled text, the second wrapped under itself: a value starts at the widest label plus the gutter and its continuation
    /// lines start there too. When that leaves the value less than half the width the label is too wide for a table, so the value starts on
    /// the next line, at `rest`, instead of being cut. One array of lines per row, so a caller can keep the rows it wants.
    private static func table(_ tty: Tty, _ rows: [[Cell]], rest: String) -> [[String]] {
        let label = rows.map { $0.first?.text.count ?? 0 }.max() ?? 0
        let start = label + Tty.gutter
        let aligned = start <= tty.width / 2
        let indent = String(rest.prefix(max(0, tty.width - 1)))
        return rows.map { row in
            let head = row.first ?? Cell("")
            let value = row.count > 1 ? row[1] : Cell("")
            let rendered = tty.styling(head.text, head.style)
            if value.text.isEmpty { return [rendered] }
            if !aligned {
                var out = head.text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [rendered]
                for line in wrap(value.text, tty.width - indent.count) { out.append(indent + tty.styling(line, value.style)) }
                return out
            }
            let lines = wrap(value.text, tty.width - start)
            let pad = String(repeating: " ", count: max(0, label - head.text.count) + Tty.gutter)
            var out = [rendered + pad + tty.styling(lines[0], value.style)]
            for line in lines.dropFirst() { out.append(String(repeating: " ", count: start) + tty.styling(line, value.style)) }
            return out
        }
    }

    // MARK: the agent

    /// The launch agent's label, as `scripts/risk install` writes it under `~/Library/LaunchAgents`.
    private static let agentLabel = "com.rish.riskell"

    /// One line about the bar behind this command: `· running, pid 123`, `· loaded, not running`, `· not installed`, or no line when the
    /// agent cannot be asked. Cheap and never waiting on riskell: a live event socket answers with its peer pid at once (no word is
    /// written), the plist is a stat, and only an agent that is installed but silent costs one local `launchctl print`. riskell itself is
    /// never run, and a missing `launchctl` costs only the line.
    private static func agentState(_ tty: Tty) -> [String] {
        let socket = cacheDir() + "/ev.sock"
        if let pid = peerPid(at: socket) { return marked(tty, "running, pid \(pid)") }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let plist = home + "/Library/LaunchAgents/\(agentLabel).plist"
        guard FileManager.default.fileExists(atPath: plist) else { return marked(tty, "not installed") }
        // installed but not loaded: none of the three lines is true of that, so it prints nothing
        guard let report = launchctlPrint() else { return [] }
        if let pid = runningPid(report) { return marked(tty, "running, pid \(pid)") }
        return marked(tty, "loaded, not running")
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
