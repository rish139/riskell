// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `riskell-ext ctl`: a thin client over the running bar's event socket. A word is one line; the app answers in its log, never to the caller,
/// so this prints what it sent and what can honestly be said about the result. It never guesses a reply.
enum Ctl {
    static let schema = "riskell.ctl/1"

    enum Group: String, CaseIterable {
        case settings
        case bar
        case workspace
        case windowManager = "window manager"
        case debug
    }

    /// What a word does to the bar. A read prints into the log; a state change is visible on screen; a debug word drives something only a
    /// developer would ask for.
    enum Effect {
        case read, state, debug
    }

    struct Word {
        let name: String
        let group: Group
        let summary: String
        let effect: Effect
        let destructive: Bool       // writes a file or moves the screen and cannot be put back by another word

        var note: String {
            switch effect {
            case .state: return "sent; risk status to confirm"
            case .read, .debug: return "sent; the reply goes to the log: risk log"
            }
        }
    }

    /// Everything the app registers on its socket (`Sources/riskell/main.swift` and `Services/AeroSpace.swift`).
    static let words: [Word] = {
        var out: [Word] = [
            Word(name: "settings", group: .settings, summary: "open or close the bar settings panel", effect: .state, destructive: false),
        ]
        for side in ["left", "right", "bottom"] {
            out.append(Word(name: "bar-\(side)-on", group: .bar, summary: "turn the \(side) bar on", effect: .state, destructive: false))
            out.append(Word(name: "bar-\(side)-off", group: .bar, summary: "turn the \(side) bar off", effect: .state, destructive: false))
        }
        for n in 1...9 {
            out.append(Word(name: "workspace-\(n)", group: .workspace, summary: "switch to workspace \(n)", effect: .state, destructive: false))
        }
        out.append(Word(name: "overview", group: .workspace, summary: "open or close the workspace overview", effect: .state, destructive: false))
        out += [
            Word(name: "wm", group: .windowManager, summary: "re-read the window manager's state", effect: .read, destructive: false),
            Word(name: "aerospace", group: .windowManager, summary: "AeroSpace's focus changed (its backend)", effect: .read, destructive: false),
        ]
        out += [
            Word(name: "compat", group: .debug, summary: "print what the running build was verified against", effect: .read, destructive: false),
            Word(name: "touch-state", group: .debug, summary: "print the trackpad and scroll-guard state", effect: .read, destructive: false),
            Word(name: "scroll-guard", group: .debug, summary: "print the scroll guard's state", effect: .read, destructive: false),
            Word(name: "window-order", group: .debug, summary: "list the frontmost windows, front first", effect: .read, destructive: false),
            Word(name: "overview-state", group: .debug, summary: "print the overview's live state", effect: .read, destructive: false),
            Word(name: "overview-bench", group: .debug, summary: "open and close the overview; log gaps", effect: .debug, destructive: true),
            Word(name: "overview-snap", group: .debug, summary: "write the overview and screen as PNGs", effect: .debug, destructive: true),
            Word(name: "screen-snap", group: .debug, summary: "write the screen as a PNG", effect: .debug, destructive: true),
            Word(name: "overview-lift", group: .debug, summary: "lift the bars as three fingers down does", effect: .debug, destructive: true),
            Word(name: "overview-drop", group: .debug, summary: "drop the bars back down", effect: .debug, destructive: true),
            Word(name: "gesture-up", group: .debug, summary: "run the swipe-up gesture without fingers", effect: .debug, destructive: true),
            Word(name: "center-focused", group: .debug, summary: "put the pointer on the focused window", effect: .debug, destructive: true),
            Word(name: "floating-top", group: .debug, summary: "toggle floating windows staying on top", effect: .debug, destructive: true),
            Word(name: "touch-reattach", group: .debug, summary: "re-attach the trackpad listener", effect: .debug, destructive: true),
            Word(name: "focus-latency", group: .debug, summary: "switch window; time the workspace follow", effect: .debug, destructive: true),
            Word(name: "focus-other", group: .debug, summary: "focus a window on another workspace", effect: .debug, destructive: true),
            Word(name: "overview-click-other", group: .debug, summary: "open the overview and click a window", effect: .debug, destructive: true),
        ]
        return out
    }()

    /// The socket the app listens on: the same path, and the same `RISKELL_EVENT_SOCKET` override, as `Services/EventSocket.swift`.
    static var socketPath: String {
        ProcessInfo.processInfo.environment["RISKELL_EVENT_SOCKET"] ?? cacheDir() + "/ev.sock"
    }

    /// A path as a person reads it: `~/…` under the home folder, absolute everywhere else.
    private static func shown(_ path: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? homePath()
        let normal = URL(fileURLWithPath: home).standardized.path
        if path == normal { return "~" }
        if path.hasPrefix(normal + "/") { return "~/" + String(path.dropFirst(normal.count + 1)) }
        return path
    }

    static func run(_ args: [String]) -> Int32 {
        if args.isEmpty { return HelpScreen.run(["ctl"]) }
        var json = false, dryRun = false, yes = false, list = false
        var name: String?
        for arg in args {
            switch arg {
            case "--json": json = true
            case "--dry-run": dryRun = true
            case "--yes": yes = true
            case "--list": list = true
            case "--all": break
            default:
                guard !arg.hasPrefix("-") else { return usage("no flag \"\(arg)\"") }
                guard name == nil else { return usage("one word at a time") }
                name = arg
            }
        }
        if list {
            guard name == nil else { return usage("--list takes no word") }
            return printList(json: json, all: args.contains("--all"))
        }
        guard let word = name else { return usage("ctl <word>, or ctl --list") }
        guard let entry = words.first(where: { $0.name == word }) else {
            return fail(word, code: 2, json: json, note: "no such word: ctl --list prints them all", message: "risk ctl: no word \"\(word)\": ctl --list prints them all")
        }
        if yes && entry.destructive {
            return fail(word, code: 2, json: json, note: "--yes is refused for a destructive word",
                        message: "risk ctl: --yes is refused for \"\(word)\": it writes or moves something no word can put back")
        }

        if dryRun {
            if json {
                print(object(word: word, sent: false, ok: true, note: "dry run; nothing was written"))
            } else {
                let tty = Terminal.tty()
                print(tty.plan([(verb: "send", text: word, satisfied: false)],
                               note: "dry run, nothing sent; take out --dry-run to send it").joined(separator: "\n"))
            }
            return 0
        }

        let path = socketPath
        guard FileManager.default.fileExists(atPath: path) else {
            if json {
                return fail(word, code: 1, json: true, note: "riskell is not running: no socket at \(path)",
                            message: "risk ctl: riskell is not running (no socket at \(path)); start it with risk install")
            }
            let tty = Terminal.tty()
            let block = tty.errorBlock(title: "riskell is not running",
                                       detail: "the bar's socket does not answer: \(shown(path))",
                                       tries: [(cmd: "risk dev", note: "start it from this checkout"),
                                               (cmd: "risk status", note: "see what else is off")])
            FileHandle.standardError.write(Data((block.joined(separator: "\n") + "\n").utf8))
            return 1
        }
        do {
            try send(word + "\n", to: path)
        } catch {
            let message = "risk ctl: could not write to \(path): \(error)"
            if json { return fail(word, code: 1, json: true, note: message, message: message) }
            let tty = Terminal.tty()
            let block = tty.errorBlock(title: "could not send \(word)", detail: "the socket at \(shown(path)) did not take it: \(error)",
                                       tries: [(cmd: "risk status", note: "see what else is off")])
            FileHandle.standardError.write(Data((block.joined(separator: "\n") + "\n").utf8))
            return 1
        }

        if json {
            print(object(word: word, sent: true, ok: true, note: entry.note))
        } else {
            let tty = Terminal.tty()
            print(tty.check(.ok, word, "sent", keyWidth: word.count + 1).joined(separator: "\n"))
        }
        return 0
    }

    // MARK: output

    private static func printList(json: Bool, all: Bool = false) -> Int32 {
        if json {
            var rows: [String] = []
            for word in words {
                rows.append("{\"word\": \(jsonQuoted(word.name)), \"group\": \(jsonQuoted(word.group.rawValue)), " +
                            "\"summary\": \(jsonQuoted(word.summary)), \"destructive\": \(word.destructive)}")
            }
            print("{\"schema\": \(jsonQuoted(schema)), \"verbs\": [\n  " + rows.joined(separator: ",\n  ") + "\n]}")
            return 0
        }

        let tty = Terminal.tty()
        if !all {
            // One line per group: the words, with numbered runs (workspace-1 ... workspace-9) folded into one.
            var lines = [tty.header("ctl", detail: "\(words.count) words"), ""]
            let labelWidth = Group.allCases.map(\.rawValue.count).max() ?? 0
            for group in Group.allCases {
                let names = words.filter { $0.group == group }.map(\.name)
                if !names.isEmpty { lines += tty.chips(label: group.rawValue, items: folded(names), labelWidth: labelWidth) }
            }
            lines += ["", tty.footerHint([(cmd: "risk ctl <word>", text: "send one"), (cmd: "risk ctl --list --all", text: "what each word does")])]
            print(lines.joined(separator: "\n"))
            return 0
        }
        var groups: [(title: String, rows: [(name: String, text: String)])] = []
        for group in Group.allCases {
            let rows = words.filter { $0.group == group }.map { word -> (name: String, text: String) in
                (name: word.name, text: word.summary + (word.destructive ? " (destructive)" : ""))
            }
            if !rows.isEmpty { groups.append((group.rawValue, rows)) }
        }
        var lines = [tty.header("ctl", detail: "\(words.count) words"), ""] + tty.commandList(groups)
        lines.append("")
        lines.append(tty.footerHint([(cmd: "risk ctl <word>", text: "send one")]))
        print(lines.joined(separator: "\n"))
        return 0
    }

    /// `workspace-1 ... workspace-9` become `workspace-1…9`: a run of words that differ only by a trailing number.
    private static func folded(_ names: [String]) -> [String] {
        var out: [String] = [], run: [String] = []
        func base(_ n: String) -> String? { n.range(of: "-[0-9]+$", options: .regularExpression).map { String(n[..<$0.lowerBound]) } }
        func flush() {
            if run.count > 2, let b = base(run[0]), let last = run.last?.dropFirst(b.count + 1) { out.append("\(run[0])\u{2026}\(last)") } else { out += run }
            run = []
        }
        for name in names {
            if let b = base(name), let first = run.first, base(first) == b { run.append(name) }
            else { flush(); run = [name] }
        }
        flush()
        return out
    }

    private static func object(word: String, sent: Bool, ok: Bool, note: String?) -> String {
        var out = "{\"schema\": \(jsonQuoted(schema)), \"word\": \(jsonQuoted(word)), \"sent\": \(sent), \"ok\": \(ok)"
        if let note { out += ", \"note\": \(jsonQuoted(note))" }
        return out + "}"
    }

    private static func usage(_ problem: String) -> Int32 {
        return Usage.error("ctl", problem)
    }

    private static func fail(_ word: String, code: Int32, json: Bool, note: String, message: String) -> Int32 {
        Usage.failure(message, tries: [("risk ctl --list", "every word")])
        if json { print(object(word: word, sent: false, ok: false, note: note)) }
        return code
    }

    // MARK: the socket

    private enum SendError: Error, CustomStringConvertible {
        case connect(String), write(String)

        var description: String {
            switch self {
            case .connect(let reason), .write(let reason): return reason
            }
        }
    }

    /// Connects, writes one line and closes: the app reads one word per connection and trims it (`Services/EventSocket.swift`).
    static func send(_ line: String, to path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SendError.connect(String(cString: strerror(errno))) }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SendError.connect("the socket path is too long") }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                for (i, byte) in bytes.enumerated() { destination[i] = CChar(bitPattern: byte) }
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, length) }
        }
        guard connected == 0 else { throw SendError.connect(String(cString: strerror(errno))) }

        let data = Array(line.utf8)
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { write(descriptor, $0.baseAddress!.advanced(by: written), data.count - written) }
            if n < 0 {
                if errno == EINTR { continue }
                throw SendError.write(String(cString: strerror(errno)))
            }
            if n == 0 { throw SendError.write("the connection closed") }
            written += n
        }
    }
}
