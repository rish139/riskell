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

        let path = cacheDir() + "/riskell.log"
        guard let fd = openFile(path) else {
            if json { print(object(path: path, lines: [], truncated: false)) }
            FileHandle.standardError.write(Data("risk log: there is no log at \(path) yet; riskell writes it while it runs\n".utf8))
            return 1
        }

        guard let data = read(from: 0, descriptor: fd) else {
            close(fd)
            FileHandle.standardError.write(Data("risk log: could not read \(path)\n".utf8))
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
                for line in selected where !writeOut(decorate(line, tty) + "\n") { return 0 }
            }
            return 0
        }

        let tty = Terminal.tty()      // tail -f prints the last lines first, then follows
        for line in selected where !writeOut(decorate(line, tty) + "\n") { close(fd); return 0 }
        signal(SIGPIPE, SIG_IGN)      // a closed pipe is a write error, not a crash
        exitWhenStdoutCloses()
        let follower = Follower(path: path, descriptor: fd, offset: off_t(data.count), tty: tty)
        follower.start()
        dispatchMain()
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
                    if !writeOut(decorate(line, tty) + "\n") { return false }
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
        FileHandle.standardError.write(Data("risk log: \(problem)\nusage: risk log [N] [--follow] [--json]\n".utf8))
        return 2
    }

    // MARK: styling

    /// A leading timestamp, bare or in brackets: `2026-11-18T15:50:00Z`, `[2026-11-18 15:50:00]`, `15:50:00`.
    private static let timestamp = try? NSRegularExpression(pattern:
        #"^\s*(?:\[[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:?[0-9]{2})?\]|[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:?[0-9]{2})?|[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?)"#)

    /// A level only where a line puts one: at the start, after the timestamp, as a whole word, optionally bracketed or followed by a colon.
    private static let level = try? NSRegularExpression(pattern:
        #"^(\s*)(\[?(?i:debug|info|warn|warning|error|fatal)\]?)(:?)(?=\s|$)"#)

    private static func decorate(_ line: String, _ tty: Tty) -> String {
        guard tty.mode != .none else { return line }
        let source = line as NSString
        var cursor = 0
        var out = ""
        if let regex = timestamp,
           let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: source.length)), match.range.location == 0 {
            out += tty.dim(source.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        let rest = source.substring(from: cursor)
        if let regex = level, let match = regex.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
            let tail = rest as NSString
            out += tail.substring(with: match.range(at: 1))
            out += styledLevel(tail.substring(with: match.range(at: 2)), tty)
            out += tail.substring(with: match.range(at: 3))
            cursor += match.range.location + match.range.length
        }
        out += source.substring(from: cursor)
        return out
    }

    private static func styledLevel(_ token: String, _ tty: Tty) -> String {
        switch token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) {
        case "error", "fatal": return tty.styling(token, Style(fg: tty.palette.color(.crit, tty.mode)))
        case "warn", "warning": return tty.styling(token, Style(fg: tty.palette.color(.warn, tty.mode)))
        default: return token      // info and debug stay plain: only a severity earns a colour
        }
    }
}
