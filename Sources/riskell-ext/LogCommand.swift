// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `riskell-ext log`: the launch agent's log at `~/.cache/riskell/riskell.log`, the last few lines or a follower. A line is shown as it was
/// written; a leading timestamp is dimmed and a real level word carries the theme's severity colour, but a message is never mined for a level
/// it does not have.
enum LogCommand {
    static let schema = "riskell.log/1"

    static func run(_ args: [String]) -> Int32 {
        var count = 20, follow = false, json = false
        for arg in args {
            switch arg {
            case "--json": json = true
            case "--follow", "-f": follow = true
            default:
                guard let n = Int(arg), n >= 0 else { return usage("unexpected \"\(arg)\"") }
                count = n
            }
        }
        if follow && json { return usage("--follow and --json do not go together: --json is one snapshot") }

        let path = logPath
        guard let fd = openFile(path) else {
            if json {
                print(object(path: path, lines: [], truncated: false))
                Usage.failure("there is no log at \(path) yet; riskell writes it while it runs", tries: [("risk dev", "start riskell")])
            } else {
                let tty = Terminal.tty()
                print(tty.empty("the log is empty", hint: (cmd: "risk dev", text: "start riskell")).joined(separator: "\n"))
            }
            return 1
        }

        guard let data = read(from: 0, descriptor: fd) else {
            close(fd)
            if json {
                FileHandle.standardError.write(Data("risk log: could not read \(path)\n".utf8))
            } else {
                let tty = Terminal.tty()
                let block = tty.errorBlock(title: "could not read the log", detail: shown(path),
                                           tries: [(cmd: "risk log", note: "try again")])
                FileHandle.standardError.write(Data((block.joined(separator: "\n") + "\n").utf8))
            }
            return 1
        }
        var lines = text(data).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }      // the file ends in a newline: no extra empty line
        let selected = lines.suffix(count)
        let truncated = lines.count > selected.count
        let first = lines.count - selected.count + 1      // the file line number of the first one printed

        if !follow {
            close(fd)
            if json {
                let rows = selected.enumerated().map { i, line in (text: line, number: first + i) }
                print(object(path: path, lines: rows, truncated: truncated))
            } else {
                let tty = Terminal.tty()
                print(screen(lines: Array(selected), empty: lines.isEmpty, path: path, count: count, tty: tty).joined(separator: "\n"))
            }
            return 0
        }

        let tty = Terminal.tty()      // tail -f prints the last lines first, then follows
        let head = screen(lines: Array(selected), empty: lines.isEmpty, path: path, count: count, tty: tty)
        for line in head where !writeOut(line + "\n") { close(fd); return 0 }
        signal(SIGPIPE, SIG_IGN)      // a closed pipe is a write error, not a crash
        exitWhenStdoutCloses()
        let follower = Follower(path: path, descriptor: fd, offset: off_t(data.count), tty: tty)
        follower.start()
        dispatchMain()
    }

    /// The file this command reads: `RISKELL_LOG_FILE` when a test or another tool names one, else the launch agent's log.
    private static var logPath: String {
        if let named = ProcessInfo.processInfo.environment["RISKELL_LOG_FILE"], !named.isEmpty { return named }
        return cacheDir() + "/riskell.log"
    }

    /// A path as a person reads it: `~/…` under the home folder, absolute everywhere else.
    private static func shown(_ path: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? homePath()
        let normal = URL(fileURLWithPath: home).standardized.path
        if path == normal { return "~" }
        if path.hasPrefix(normal + "/") { return "~/" + String(path.dropFirst(normal.count + 1)) }
        return path
    }

    /// The header and the lines, or the one screen an empty log gets.
    private static func screen(lines: [String], empty: Bool, path: String, count: Int, tty: Tty) -> [String] {
        guard !empty else { return tty.empty("the log is empty", hint: (cmd: "risk dev", text: "start riskell")) }
        var out = tty.tableHead(title: "log", detail: shown(path), meta: "last \(count) \(tty.glyphs.note) --follow")
        out += lines.map { render($0, tty) }
        return out
    }

    // MARK: reading

    private static func openFile(_ path: String) -> Int32? {
        let fd = open(path, O_RDONLY)
        return fd >= 0 ? fd : nil
    }

    /// Everything from `offset` to the end, or nil on a read error.
    private static func read(from offset: off_t, descriptor: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var at = offset
        while true {
            let n = pread(descriptor, &buffer, buffer.count, at)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return data }
            data.append(contentsOf: buffer[0..<n])
            at += off_t(n)
        }
    }

    private static func text(_ data: Data) -> String {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }      // a byte-order mark is not the first line's text
        return String(decoding: data, as: UTF8.self)
    }

    /// The last lines, then whatever is appended. A regular file has no blocking read, so its changes arrive as a file event, not a timer.
    private final class Follower {
        private let path: String
        private var descriptor: Int32
        private var offset: off_t
        private var partial = Data()
        private let tty: Tty
        private var source: DispatchSourceFileSystemObject?

        init(path: String, descriptor: Int32, offset: off_t, tty: Tty) {
            self.path = path
            self.descriptor = descriptor
            self.offset = offset
            self.tty = tty
        }

        func start() {
            _ = pump()      // anything appended between the snapshot and the watcher
            arm()
        }

        private func arm() {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename],
                                                                   queue: .global())
            source.setEventHandler { [weak self] in self?.event(source) }
            self.source = source
            source.resume()
        }

        private func event(_ source: DispatchSourceFileSystemObject) {
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                source.cancel()
                close(descriptor)
                guard let fd = openFile(path) else {
                    FileHandle.standardError.write(Data("risk log: \(path) went away\n".utf8))
                    exit(1)
                }
                descriptor = fd
                offset = 0
                partial = Data()
                arm()
            }
            guard pump() else { exit(0) }
        }

        private func pump() -> Bool {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = pread(descriptor, &buffer, buffer.count, offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return true }
                offset += off_t(n)
                partial.append(contentsOf: buffer[0..<n])
                while let end = partial.firstIndex(of: 0x0A) {
                    let line = text(partial[partial.startIndex..<end])
                    partial.removeSubrange(partial.startIndex...end)
                    if !writeOut(render(line, tty) + "\n") { return false }
                }
            }
        }
    }

    /// `tail -f` has to stop when the reader does. A thread waits in `poll` on stdout: a pipe or terminal that loses its reader reports
    /// `POLLHUP`, and the process leaves without a timer or a wake-up of its own.
    private static func exitWhenStdoutCloses() {
        Thread.detachNewThread {
            var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLHUP | POLLERR), revents: 0)
            while true {
                let ready = poll(&descriptor, 1, -1)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 { continue }
                if descriptor.revents & Int16(POLLHUP | POLLERR) != 0 { exit(0) }
                return      // POLLNVAL: stdout is a file or /dev/null, with no reader to lose
            }
        }
    }

    // MARK: output

    @discardableResult
    private static func writeOut(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            var written = 0
            while written < buffer.count {
                let n = write(STDOUT_FILENO, buffer.baseAddress! + written, buffer.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                written += n
            }
            return true
        }
    }

    private static func object(path: String, lines: [(text: String, number: Int)], truncated: Bool) -> String {
        var out = "{\n  \"schema\": \(jsonQuoted(schema)),\n  \"path\": \(jsonQuoted(path)),\n  \"lines\": ["
        for (i, line) in lines.enumerated() {
            out += (i == 0 ? "\n" : ",\n") + "    {\"line\": \(jsonQuoted(line.text)), \"n\": \(line.number)}"
        }
        out += lines.isEmpty ? "],\n" : "\n  ],\n"
        out += "  \"truncated\": \(truncated)\n}"
        return out
    }

    private static func usage(_ problem: String) -> Int32 {
        return Usage.error("log", problem)
    }

    // MARK: reading a line

    /// One line as the log screen shows it. The agent's log is its own output, so a line may carry a timestamp, a level and a source
    /// (`12:04:11 warn touch no frame for 2 s`), the source first (`wm: subscribed`), or only a message. A line that names none of them is
    /// still shown, as information from source `-`, because the log is the place a reader looks when nothing else parses.
    private struct Entry {
        let time: String
        let level: Level
        let source: String
        let message: String
    }

    /// `HH:MM:SS level source message`, the shape the log screen draws.
    private static let stamped = try? NSRegularExpression(pattern:
        #"^\s*(\d{2}:\d{2}:\d{2})(?:\.\d+)?\s+\[?(debug|info|warn|warning|error|fatal)\]?\s+([^\s:]+)\s+(.*)$"#,
        options: [.caseInsensitive])

    /// A source in brackets, as the gestures code writes it: `[touch 123.4] …`, `[+ 5 ms] …`.
    private static let bracketed = try? NSRegularExpression(pattern: #"^\s*\[([^\]]+)\]\s*(.*)$"#)

    /// The agent's own lines: `source: message`, where the source may be more than one word, as in `window manager: …`.
    private static let prefixed = try? NSRegularExpression(pattern: #"^\s*([A-Za-z][A-Za-z0-9 _-]*):\s+(.*)$"#)

    private static func parse(_ line: String) -> Entry {
        if let match = stamped?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), match.range.location == 0 {
            let time = group(match, 1, line) ?? "--:--:--"
            let level = named(group(match, 2, line) ?? "info")
            let source = group(match, 3, line) ?? "-"
            return Entry(time: time, level: level, source: source, message: group(match, 4, line) ?? "")
        }
        if let match = bracketed?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), match.range.location == 0 {
            let inside = group(match, 1, line) ?? ""
            let message = group(match, 2, line) ?? ""
            if inside.hasPrefix("+") { return Entry(time: "--:--:--", level: .info, source: "trace", message: message) }
            let parts = inside.split(separator: " ", maxSplits: 1).map(String.init)
            let source = parts.count == 2 && Double(parts[1].split(separator: " ").first ?? "") != nil ? parts[0] : inside
            return Entry(time: "--:--:--", level: .info, source: source, message: message)
        }
        if let match = prefixed?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), match.range.location == 0 {
            return Entry(time: "--:--:--", level: .info, source: group(match, 1, line) ?? "-", message: group(match, 2, line) ?? "")
        }
        return Entry(time: "--:--:--", level: .info, source: "-", message: line)
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ line: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }

    private static func named(_ token: String) -> Level {
        switch token.lowercased() {
        case "warn", "warning": return .warn
        case "error", "fatal": return .error
        default: return .info
        }
    }

    private static func render(_ line: String, _ tty: Tty) -> String {
        let entry = parse(line)
        let source = entry.source.count <= 9 ? entry.source
            : String((entry.source.split(separator: " ").last ?? Substring(entry.source)).prefix(9))
        return tty.logLine(time: entry.time, level: entry.level, source: source, message: entry.message)
    }
}
