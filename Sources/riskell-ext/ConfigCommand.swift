// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `riskell-ext config`: riskell's settings file as a command, so nothing about the settings needs hand-edited JSON. The file is read and
/// changed as text, not through `JSONSerialization`: a set splices only the value it names and the members it adds, so every other key keeps
/// its bytes and its place, which a dictionary cannot promise. A dot reaches into objects (`usage.claude`); an index into an array is not a
/// key and is refused. A key whose name looks like a credential is printed as `set`, never with its value.
enum ConfigCommand {
    static let schema = "riskell.config/1"

    static func run(_ args: [String]) -> Int32 {
        guard let sub = args.first else { return usage("path, show, get, set or edit") }
        let rest = Array(args.dropFirst())
        switch sub {
        case "path": return path(rest)
        case "show": return show(rest)
        case "get": return get(rest)
        case "set": return set(rest)
        case "edit": return edit(rest)
        default: return usage("no subcommand \"\(sub)\"")
        }
    }

    // MARK: paths

    /// The five places riskell keeps its own state. The config decides the folder, so a scratch `RISKELL_CONFIG` moves the layout beside it
    /// too; the cache, log and socket keep the paths `Services/EventSocket.swift` and the launch agent use unless their own variable is set.
    private struct Paths {
        let config: String
        let layout: String
        let cache: String
        let log: String
        let socket: String

        init() {
            let env = ProcessInfo.processInfo.environment
            config = Paths.absolute(env["RISKELL_CONFIG"] ?? NSHomeDirectory() + "/.config/riskell/config.json")
            layout = env["RISKELL_LAYOUT"].map(Paths.absolute)
                ?? URL(fileURLWithPath: config).deletingLastPathComponent().appendingPathComponent("layout.json").path
            cache = Paths.absolute(env["RISKELL_CACHE_DIR"] ?? NSHomeDirectory() + "/.cache/riskell")
            log = cache + "/riskell.log"
            socket = Paths.absolute(env["RISKELL_EVENT_SOCKET"] ?? cache + "/ev.sock")
        }

        /// Absolute, with a relative value read from here rather than from a helper's working folder.
        static func absolute(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardized.path
        }
    }

    /// A path as a person reads it: `~/…` under the home folder, absolute everywhere else.
    private static func shown(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + String(path.dropFirst(home.count + 1)) }
        return path
    }

    private static func path(_ args: [String]) -> Int32 {
        var json = false
        for arg in args {
            switch arg {
            case "--json": json = true
            default: return usage("path takes no argument \"\(arg)\"")
            }
        }
        let paths = Paths()
        if json {
            print("{\"schema\": \(jsonQuoted(schema)), \"paths\": {\"config\": \(jsonQuoted(shown(paths.config))), " +
                  "\"layout\": \(jsonQuoted(shown(paths.layout))), \"cache\": \(jsonQuoted(shown(paths.cache))), " +
                  "\"log\": \(jsonQuoted(shown(paths.log))), \"socket\": \(jsonQuoted(shown(paths.socket)))}}")
            return 0
        }
        let tty = Terminal.tty()
        let rows = [("config", paths.config), ("layout", paths.layout), ("cache", paths.cache), ("log", paths.log), ("socket", paths.socket)]
        let width = rows.map(\.0.count).max() ?? 0
        for (label, value) in rows {
            let pad = String(repeating: " ", count: width - label.count)
            print("  " + tty.dim(label + pad) + "  " + shown(value))
        }
        return 0
    }

    // MARK: show

    private static func show(_ args: [String]) -> Int32 {
        var json = false
        for arg in args {
            switch arg {
            case "--json": json = true
            default: return usage("show takes no argument \"\(arg)\"")
            }
        }
        let file = Paths().config
        let exists = FileManager.default.fileExists(atPath: file)
        let text = exists ? try? String(contentsOfFile: file, encoding: .utf8) : nil
        let parsed = text.map { ParsedJSON.parse($0) }
        let root = parsed?.root
        let object = root.flatMap { isObject($0) ? $0 : nil }
        let parses = root != nil
        let reason: String? = {
            guard exists else { return nil }
            if text == nil { return "the file cannot be read" }
            if let error = parsed?.error { return error }
            if object == nil { return "it is valid JSON but not an object, and riskell's config is an object" }
            return nil
        }()

        if json {
            var out = "{\n  \"schema\": \(jsonQuoted(schema)),\n  \"file\": \(jsonQuoted(shown(file))),\n  " +
                      "\"exists\": \(exists),\n  \"parses\": \(parses)"
            out += object.map { ",\n  \"config\": " + pretty($0, redact: true, indent: 2) } ?? ",\n  \"config\": null"
            if let reason { out += ",\n  \"error\": \(jsonQuoted(reason))" }
            print(out + "\n}")
        } else {
            let tty = Terminal.tty()
            print(tty.bold(shown(file)))
            print("  " + tty.dim("exists") + "  " + (exists ? "yes" : "no"))
            print("  " + tty.dim("parses") + "  " + (parses ? "yes" : "no"))
            if let reason { print("  " + tty.dim("reason") + "  " + reason) }
            if let object, let text {
                print("")
                print(redactedSource(text, root: object))
            } else if let text, !text.isEmpty {
                print("")
                print(text)
            }
        }
        return exists && !parses ? 1 : 0
    }

    // MARK: get

    private static func get(_ args: [String]) -> Int32 {
        var json = false
        var key: String?
        for arg in args {
            switch arg {
            case "--json": json = true
            default:
                guard !arg.hasPrefix("-") else { return usage("no flag \"\(arg)\"") }
                guard key == nil else { return usage("get takes one key") }
                key = arg
            }
        }
        guard let key else { return usage("get <key>") }
        let segments = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !segments.contains(where: \.isEmpty) else { return usage("\"\(key)\" is not a dotted key") }

        let file = Paths().config
        guard FileManager.default.fileExists(atPath: file) else {
            return report("risk config: there is no \(shown(file)) yet; `risk config set <key> <value>` starts one")
        }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            return report("risk config: cannot read \(shown(file))")
        }
        let parsed = ParsedJSON.parse(text)
        guard let root = parsed.root, isObject(root) else {
            return report("risk config: \(shown(file)) is not a JSON object\(parsed.error.map { ": " + $0 } ?? ""); \"\(key)\" is not set")
        }

        var node = root
        var walked: [String] = []
        for segment in segments {
            guard case .object(let members, _) = node else {
                return report("risk config: \"\(walked.joined(separator: "."))\" is \(kind(node)) in \(shown(file)), so \"\(key)\" is not set")
            }
            guard let member = members.last(where: { $0.key == segment }) else {
                return report("risk config: \"\(key)\" is not in \(shown(file))")
            }
            node = member.value
            walked.append(segment)
        }

        if json {
            print("{\"schema\": \(jsonQuoted(schema)), \"key\": \(jsonQuoted(key)), \"value\": \(compact(node)), " +
                  "\"file\": \(jsonQuoted(shown(file)))}")
        } else if case .string(let value, _) = node {
            print(value)
        } else {
            print(compact(node))
        }
        return 0
    }

    // MARK: set

    private static func set(_ args: [String]) -> Int32 {
        var json = false, dryRun = false
        var positional: [String] = []
        for arg in args {
            switch arg {
            case "--json": json = true
            case "--dry-run": dryRun = true
            default:
                if arg.hasPrefix("-") && positional.isEmpty { return usage("no flag \"\(arg)\"") }
                positional.append(arg)
            }
        }
        guard positional.count == 2 else { return usage("set <key> <value>") }
        let key = positional[0], raw = positional[1]
        let segments = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !segments.contains(where: \.isEmpty) else { return usage("\"\(key)\" is not a dotted key") }

        let file = Paths().config
        let exists = FileManager.default.fileExists(atPath: file)
        let old: String
        if exists {
            guard let read = try? String(contentsOfFile: file, encoding: .utf8) else {
                return report("risk config: cannot read \(shown(file))")
            }
            old = read
        } else {
            old = ""
        }
        let base = exists ? old : "{}"
        let parsed = ParsedJSON.parse(base)
        guard let root = parsed.root else {
            return report("risk config: \(shown(file)) is not valid JSON: \(parsed.error ?? "unknown error"). Not changed.")
        }
        guard isObject(root) else {
            return report("risk config: \(shown(file)) is not a JSON object (\(kind(root))). Not changed. Fix: make the file an object, e.g. {}")
        }

        let value: JSONNode
        let text: String
        do {
            (text, value) = try rewritten(chars: parsed.chars, root: root, segments: segments, raw: raw, file: shown(file), fresh: !exists)
        } catch let problem as RewriteError {
            return report("risk config: \(problem.message)")
        } catch {
            return report("risk config: could not change \(shown(file))")
        }
        guard let check = ParsedJSON.parse(text).root, isObject(check) else {
            return report("risk config: the change to \(shown(file)) would not parse; not written")
        }

        let changed = text != base
        if dryRun {
            writeFile(text)
            return 0
        }
        if changed, let problem = writeAtomically(text, to: file) {
            return report("risk config: \(problem)")
        }

        if json {
            print("{\"schema\": \(jsonQuoted(schema)), \"key\": \(jsonQuoted(key)), \"value\": \(compact(value)), " +
                  "\"file\": \(jsonQuoted(shown(file))), \"changed\": \(changed)}")
            return 0
        }
        let tty = Terminal.tty()
        let setting = tty.bold(key) + " = " + compact(value) + " " + tty.dim("in " + shown(file))
        print((changed ? tty.mark(.ok, "set") : tty.dim("unchanged")) + " " + setting)      // the mark's width must not clip the path
        return 0
    }

    /// The new file text and the value written. An existing value decides the type (`false` stays a bool, `3` a number, an array stays an
    /// array); with no value to go by, the argument is JSON when it parses and a string when it does not. Only the named value and the
    /// members added for a new key are written: everything else is the source's own bytes.
    private static func rewritten(chars: [Character], root: JSONNode, segments: [String], raw: String,
                                  file: String, fresh: Bool) throws -> (String, JSONNode) {
        let key = segments.joined(separator: ".")
        var node = root
        var walked: [String] = []
        for (depth, segment) in segments.enumerated() {
            guard case .object(let members, _) = node else {
                throw RewriteError("\"\(walked.joined(separator: "."))\" is \(kind(node)) in \(file), so \"\(key)\" cannot be set. Not changed.")
            }
            if let member = members.last(where: { $0.key == segment }) {
                if depth == segments.count - 1 {
                    let value = try convert(raw: raw, existing: member.value, key: key, file: file)
                    var out = chars
                    out.replaceSubrange(member.value.range, with: Array(writeValue(value)))
                    return (String(out), value)
                }
                node = member.value
                walked.append(segment)
                continue
            }
            // The key is new here: create it and every missing object below it, and leave the rest of the file alone.
            let value = try convert(raw: raw, existing: nil, key: key, file: file)
            var valueText = writeValue(value)
            for rest in segments[(depth + 1)...].reversed() {
                valueText = "{" + jsonQuoted(rest) + ": " + valueText + "}"
            }
            let memberText = jsonQuoted(segment) + ": " + valueText
            if fresh { return ("{\n  " + memberText + "\n}\n", value) }
            return (insert(memberText, into: node, chars: chars), value)
        }
        throw RewriteError("nothing to set")
    }

    private static func convert(raw: String, existing: JSONNode?, key: String, file: String) throws -> JSONNode {
        // Values made here have no range in a file: only nodes parsed from the source are sliced by range.
        let nowhere = 0..<0
        switch existing {
        case .string:
            return .string(raw, nowhere)
        case .number:
            guard let parsed = ParsedJSON.parse(raw).root, case .number = parsed else { throw mismatch(key, existing, raw, file) }
            return parsed
        case .bool:
            if raw == "true" { return .bool(true, nowhere) }
            if raw == "false" { return .bool(false, nowhere) }
            throw mismatch(key, existing, raw, file)
        case .array:
            guard let parsed = ParsedJSON.parse(raw).root, case .array = parsed else { throw mismatch(key, existing, raw, file) }
            return parsed
        case .object:
            guard let parsed = ParsedJSON.parse(raw).root, case .object = parsed else { throw mismatch(key, existing, raw, file) }
            return parsed
        case .null, .none:
            return ParsedJSON.parse(raw).root ?? .string(raw, nowhere)
        }
    }

    private static func mismatch(_ key: String, _ existing: JSONNode?, _ raw: String, _ file: String) -> RewriteError {
        switch existing {
        case .number(let number, _):
            return RewriteError("\"\(key)\" is the number \(number) in \(file), and \"\(raw)\" is not a number. Pass a number, e.g. risk config set \(key) 1")
        case .bool(let on, _):
            return RewriteError("\"\(key)\" is \(on ? "true" : "false") in \(file), and \"\(raw)\" is neither true nor false. Pass true or false")
        case .array:
            return RewriteError("\"\(key)\" is an array in \(file); pass a JSON array, e.g. risk config set \(key) '[]'")
        case .object:
            return RewriteError("\"\(key)\" is an object in \(file); pass a JSON object, e.g. risk config set \(key) '{}'")
        default:
            return RewriteError("\"\(raw)\" does not fit \"\(key)\" in \(file)")
        }
    }

    /// Adds one member to an object, matching the object's own layout: inline stays inline, and a member on its own line gets a comma and
    /// the indentation its neighbours use. An empty object has its inside replaced, so no stray newline is left behind.
    private static func insert(_ member: String, into object: JSONNode, chars: [Character]) -> String {
        guard case .object(let members, let range) = object else { return String(chars) }
        var out = chars
        let open = range.lowerBound + 1, close = range.upperBound - 1
        if members.isEmpty {
            if String(chars[open..<close]).contains("\n") {
                let indent = lineIndent(chars, at: range.lowerBound)
                out.replaceSubrange(open..<close, with: Array("\n" + indent + "  " + member + "\n" + indent))
            } else {
                out.replaceSubrange(open..<close, with: Array(member))
            }
            return String(out)
        }
        let first = members[0]
        let at = members[members.count - 1].value.range.upperBound
        if String(chars[open..<first.keyRange.lowerBound]).contains("\n") {
            let indent = lineIndent(chars, at: first.keyRange.lowerBound)
            out.insert(contentsOf: Array(",\n" + indent + member), at: at)
        } else {
            out.insert(contentsOf: Array(", " + member), at: at)
        }
        return String(out)
    }

    /// The whitespace before the first thing on a line, which is the indentation a new member beside it takes.
    private static func lineIndent(_ chars: [Character], at index: Int) -> String {
        var start = min(index, chars.count)
        while start > 0, chars[start - 1] != "\n" { start -= 1 }
        var end = start
        while end < chars.count, chars[end] == " " || chars[end] == "\t" { end += 1 }
        return String(chars[start..<end])
    }

    private static func writeAtomically(_ text: String, to path: String) -> String? {
        let fm = FileManager.default
        let folder = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: folder) {
            do { try fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            catch { return "cannot create \(folder): \(error.localizedDescription)" }
        }
        let permissions = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions]
        let temporary = folder + "/." + (path as NSString).lastPathComponent + ".tmp-\(UUID().uuidString)"
        do { try Data(text.utf8).write(to: URL(fileURLWithPath: temporary)) }
        catch { return "cannot write \(temporary): \(error.localizedDescription)" }
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary) }
        if rename(temporary, path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(atPath: temporary)
            return "cannot replace \(path): \(reason)"
        }
        return nil
    }

    /// The bytes themselves under `--dry-run`; a terminal needs the trailing newline its prompt sits on.
    private static func writeFile(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
        if !text.hasSuffix("\n") { print("") }
    }

    // MARK: edit

    private static func edit(_ args: [String]) -> Int32 {
        var yes = false
        for arg in args {
            switch arg {
            case "--yes": yes = true
            default: return usage("edit takes only --yes, not \"\(arg)\"")
            }
        }
        guard yes || (isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0) else {
            return report("risk config: edit opens an editor, and this is not a terminal. Run it in one, or pass --yes.", code: 2)
        }

        let file = Paths().config
        let fm = FileManager.default
        var before: String?
        if fm.fileExists(atPath: file) {
            guard let read = try? String(contentsOfFile: file, encoding: .utf8) else {
                return report("risk config: cannot read \(shown(file))")
            }
            before = read
        } else {
            do {
                try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try "{}\n".write(toFile: file, atomically: true, encoding: .utf8)
                before = "{}\n"
            } catch {
                return report("risk config: cannot create \(shown(file)): \(error.localizedDescription)")
            }
        }

        let environment = ProcessInfo.processInfo.environment
        let editor = environment["EDITOR"].flatMap { $0.isEmpty ? nil : $0 } ?? "vi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", editor + " \"$1\"", "risk-config-edit", file]      // an $EDITOR such as `code --wait` keeps its arguments
        do { try process.run() } catch {
            return report("risk config: could not start \(editor): \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let after = try? String(contentsOfFile: file, encoding: .utf8)
        let parsed = after.map { ParsedJSON.parse($0) }
        if let root = parsed?.root, isObject(root) {
            print("ok: \(shown(file)) is valid JSON")
            return 0
        }

        let reason = parsed?.error ?? (after == nil ? "the file is gone" : "it is valid JSON but not an object, and riskell's config is an object")
        var backup = ""
        if let before {
            do {
                try before.write(toFile: file + ".bak", atomically: true, encoding: .utf8)
                backup = ". The version from before your edit is \(shown(file)).bak; put it back with: cp \(shellQuoted(file + ".bak")) \(shellQuoted(file))"
            } catch {
                backup = ". The version from before your edit could not be copied to \(shown(file)).bak: \(error.localizedDescription)"
            }
        }
        return report("risk config: \(shown(file)) is not valid: \(reason). Your edit is left in the file, as you saved it\(backup).")
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: messages

    private static func usage(_ problem: String) -> Int32 {
        let message = "risk config: \(problem)\nusage: risk config path|show|get|set|edit [--json] [--dry-run] [--yes]\n"
        FileHandle.standardError.write(Data(message.utf8))
        return 2
    }

    @discardableResult
    private static func report(_ message: String, code: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return code
    }

    // MARK: the parsed file

    private struct JSONMember {
        let key: String
        let keyRange: Range<Int>
        let value: JSONNode
    }

    /// A value in the file's order. A member keeps the range its key and value occupy, so a set can replace one value and leave the rest of
    /// the bytes as they were; a number keeps its spelling (`3` does not become `3.0`).
    private indirect enum JSONNode {
        case object([JSONMember], Range<Int>)
        case array([JSONNode], Range<Int>)
        case string(String, Range<Int>)
        case number(String, Range<Int>)
        case bool(Bool, Range<Int>)
        case null(Range<Int>)

        var range: Range<Int> {
            switch self {
            case .object(_, let range), .array(_, let range), .string(_, let range),
                 .number(_, let range), .bool(_, let range), .null(let range):
                return range
            }
        }
    }

    private static func isObject(_ node: JSONNode) -> Bool {
        if case .object = node { return true }
        return false
    }

    private static func kind(_ node: JSONNode) -> String {
        switch node {
        case .object: return "an object"
        case .array: return "an array"
        case .string: return "a string"
        case .number: return "a number"
        case .bool: return "a bool"
        case .null: return "null"
        }
    }

    private struct RewriteError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private struct JSONSyntaxError: Error {
        let message: String
        let index: Int
    }

    private struct ParsedJSON {
        let chars: [Character]
        let root: JSONNode?
        let error: String?

        static func parse(_ text: String) -> ParsedJSON {
            let chars = Array(text)
            var parser = Parser(chars)
            do {
                parser.space()
                guard parser.index < chars.count else { throw JSONSyntaxError(message: "the file is empty", index: 0) }
                let root = try parser.value()
                parser.space()
                guard parser.index == chars.count else {
                    throw JSONSyntaxError(message: "unexpected text after the value", index: parser.index)
                }
                return ParsedJSON(chars: chars, root: root, error: nil)
            } catch let problem as JSONSyntaxError {
                return ParsedJSON(chars: chars, root: nil, error: describing(problem, chars))
            } catch {
                return ParsedJSON(chars: chars, root: nil, error: "not valid JSON")
            }
        }

        private static func describing(_ problem: JSONSyntaxError, _ chars: [Character]) -> String {
            let at = min(max(0, problem.index), chars.count)
            var line = 1, column = 1
            for i in 0..<at {
                if chars[i] == "\n" { line += 1; column = 1 } else { column += 1 }
            }
            return "\(problem.message) at line \(line), column \(column)"
        }
    }

    private struct Parser {
        let chars: [Character]
        var index = 0

        init(_ chars: [Character]) { self.chars = chars }

        var peek: Character? { index < chars.count ? chars[index] : nil }

        mutating func space() {
            while let ch = peek, ch == " " || ch == "\t" || ch == "\n" || ch == "\r" { index += 1 }
        }

        mutating func value() throws -> JSONNode {
            space()
            guard let ch = peek else { throw JSONSyntaxError(message: "the file ends where a value should start", index: index) }
            switch ch {
            case "{": return try object()
            case "[": return try array()
            case "\"": let (text, range) = try string(); return .string(text, range)
            case "t": let start = index; try expect("true"); return .bool(true, start..<index)
            case "f": let start = index; try expect("false"); return .bool(false, start..<index)
            case "n": let start = index; try expect("null"); return .null(start..<index)
            case "}", "]": throw JSONSyntaxError(message: "unexpected \"\(ch)\" where a value should start", index: index)
            default:
                guard ch == "-" || (ch >= "0" && ch <= "9") else {
                    throw JSONSyntaxError(message: "unexpected \"\(ch)\" where a value should start", index: index)
                }
                return try number()
            }
        }

        private mutating func object() throws -> JSONNode {
            let start = index
            index += 1
            var members: [JSONMember] = []
            space()
            if peek == "}" { index += 1; return .object(members, start..<index) }
            while true {
                space()
                guard peek == "\"" else {
                    throw JSONSyntaxError(message: "an object's key must be a quoted string", index: index)
                }
                let (key, keyRange) = try string()
                space()
                guard peek == ":" else {
                    throw JSONSyntaxError(message: "a colon must follow the key \"\(key)\"", index: index)
                }
                index += 1
                let value = try self.value()
                members.append(JSONMember(key: key, keyRange: keyRange, value: value))
                space()
                if peek == "," { index += 1; continue }
                if peek == "}" { index += 1; break }
                throw JSONSyntaxError(message: "a comma or } must follow a member", index: index)
            }
            return .object(members, start..<index)
        }

        private mutating func array() throws -> JSONNode {
            let start = index
            index += 1
            var items: [JSONNode] = []
            space()
            if peek == "]" { index += 1; return .array(items, start..<index) }
            while true {
                items.append(try value())
                space()
                if peek == "," { index += 1; continue }
                if peek == "]" { index += 1; break }
                throw JSONSyntaxError(message: "a comma or ] must follow an item", index: index)
            }
            return .array(items, start..<index)
        }

        private mutating func string() throws -> (String, Range<Int>) {
            let start = index
            index += 1
            var out = ""
            while true {
                guard index < chars.count else { throw JSONSyntaxError(message: "the file ends inside a string", index: start) }
                let ch = chars[index]
                if ch == "\"" { index += 1; return (out, start..<index) }
                if ch == "\n" || ch == "\r" { throw JSONSyntaxError(message: "a string cannot contain a line break", index: index) }
                guard ch == "\\" else { out.append(ch); index += 1; continue }
                index += 1
                guard index < chars.count else { throw JSONSyntaxError(message: "the file ends inside an escape", index: index) }
                let escape = chars[index]
                index += 1
                switch escape {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    let high = try hexadecimal(4)
                    if high >= 0xD800 && high <= 0xDBFF {
                        guard index + 1 < chars.count, chars[index] == "\\", chars[index + 1] == "u" else {
                            throw JSONSyntaxError(message: "a UTF-16 surrogate needs its pair", index: index)
                        }
                        index += 2
                        let low = try hexadecimal(4)
                        guard low >= 0xDC00 && low <= 0xDFFF else { throw JSONSyntaxError(message: "a UTF-16 surrogate needs its pair", index: index) }
                        let scalar = 0x10000 + (UInt32(high - 0xD800) << 10) + UInt32(low - 0xDC00)
                        guard let unicode = UnicodeScalar(scalar) else { throw JSONSyntaxError(message: "an escape is not a character", index: index) }
                        out.unicodeScalars.append(unicode)
                    } else {
                        guard let unicode = UnicodeScalar(UInt32(high)) else { throw JSONSyntaxError(message: "an escape is not a character", index: index) }
                        out.unicodeScalars.append(unicode)
                    }
                default: throw JSONSyntaxError(message: "unknown escape \\\(escape)", index: index - 1)
                }
            }
        }

        private mutating func hexadecimal(_ count: Int) throws -> UInt16 {
            var value: UInt16 = 0
            for _ in 0..<count {
                guard index < chars.count, let digit = hexadecimal(chars[index]) else {
                    throw JSONSyntaxError(message: "\\u needs four hexadecimal digits", index: index)
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        private func hexadecimal(_ ch: Character) -> UInt16? {
            if let digit = ch.wholeNumberValue, digit >= 0, digit < 10 { return UInt16(digit) }
            switch ch {
            case "a"..."f": return UInt16(ch.asciiValue! - Character("a").asciiValue! + 10)
            case "A"..."F": return UInt16(ch.asciiValue! - Character("A").asciiValue! + 10)
            default: return nil
            }
        }

        private mutating func number() throws -> JSONNode {
            let start = index
            if peek == "-" { index += 1 }
            guard let first = peek else { throw JSONSyntaxError(message: "a number cannot end with its minus sign", index: index) }
            if first == "0" {
                index += 1
                if let next = peek, next >= "0", next <= "9" {
                    throw JSONSyntaxError(message: "a number cannot start with a zero", index: start)
                }
            } else if first >= "1", first <= "9" {
                index += 1
                while let digit = peek, digit >= "0", digit <= "9" { index += 1 }
            } else {
                throw JSONSyntaxError(message: "expected a number", index: start)
            }
            if peek == "." {
                index += 1
                guard let digit = peek, digit >= "0", digit <= "9" else {
                    throw JSONSyntaxError(message: "a number needs a digit after its decimal point", index: index)
                }
                while let digit = peek, digit >= "0", digit <= "9" { index += 1 }
            }
            if peek == "e" || peek == "E" {
                index += 1
                if peek == "+" || peek == "-" { index += 1 }
                guard let digit = peek, digit >= "0", digit <= "9" else {
                    throw JSONSyntaxError(message: "a number needs a digit in its exponent", index: index)
                }
                while let digit = peek, digit >= "0", digit <= "9" { index += 1 }
            }
            return .number(String(chars[start..<index]), start..<index)
        }

        private mutating func expect(_ word: String) throws {
            let wanted = Array(word)
            guard index + wanted.count <= chars.count, Array(chars[index..<(index + wanted.count)]) == wanted else {
                throw JSONSyntaxError(message: "expected \(word)", index: index)
            }
            index += wanted.count
        }
    }

    // MARK: rendering

    private static func compact(_ node: JSONNode) -> String {
        switch node {
        case .object(let members, _):
            return "{" + members.map { jsonQuoted($0.key) + ":" + compact($0.value) }.joined(separator: ",") + "}"
        case .array(let items, _):
            return "[" + items.map(compact).joined(separator: ",") + "]"
        case .string(let text, _): return jsonQuoted(text)
        case .number(let text, _): return text
        case .bool(let on, _): return on ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func pretty(_ node: JSONNode, redact: Bool, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent + 2)
        let close = String(repeating: " ", count: indent)
        switch node {
        case .object(let members, _):
            guard !members.isEmpty else { return "{}" }
            var lines = ["{"]
            for (i, member) in members.enumerated() {
                let value = redact && isSecret(member.key)
                    ? jsonQuoted("set")
                    : pretty(member.value, redact: redact, indent: indent + 2)
                lines.append(pad + jsonQuoted(member.key) + ": " + value + (i == members.count - 1 ? "" : ","))
            }
            lines.append(close + "}")
            return lines.joined(separator: "\n")
        case .array(let items, _):
            guard !items.isEmpty else { return "[]" }
            var lines = ["["]
            for (i, item) in items.enumerated() {
                lines.append(pad + pretty(item, redact: redact, indent: indent + 2) + (i == items.count - 1 ? "" : ","))
            }
            lines.append(close + "]")
            return lines.joined(separator: "\n")
        case .string(let text, _): return jsonQuoted(text)
        case .number(let text, _): return text
        case .bool(let on, _): return on ? "true" : "false"
        case .null: return "null"
        }
    }

    /// A string that a set writes: the same JSON spelling the parser would read back.
    private static func writeValue(_ node: JSONNode) -> String {
        if case .string(let text, _) = node { return jsonQuoted(text) }
        return compact(node)
    }

    // MARK: redaction

    /// Keys whose value is never printed. The words are matched as words, so `fiveHourTokens` (a count) is not a `token` while `apiKey` and
    /// `access_token` are; the file's own key names decide, not the shape of the value.
    private static let secretWords: Set<String> = ["token", "key", "secret", "cookie", "cookies", "password", "passwd",
                                                   "credential", "credentials", "authorization", "bearer", "auth"]

    private static func isSecret(_ key: String) -> Bool {
        var words: [String] = []
        var current = ""
        for ch in key {
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if ch.isUppercase && !current.isEmpty { words.append(current); current = "" }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words.contains { secretWords.contains($0.lowercased()) }
    }

    /// The file's text with each secret value replaced by `"set"`: the rest keeps its whitespace and member order.
    private static func redactedSource(_ text: String, root: JSONNode) -> String {
        var ranges: [Range<Int>] = []
        secretRanges(root, into: &ranges)
        guard !ranges.isEmpty else { return text }
        var chars = Array(text)
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            chars.replaceSubrange(range, with: Array(jsonQuoted("set")))
        }
        return String(chars)
    }

    private static func secretRanges(_ node: JSONNode, into ranges: inout [Range<Int>]) {
        switch node {
        case .object(let members, _):
            for member in members {
                if isSecret(member.key) { ranges.append(member.value.range) }
                else { secretRanges(member.value, into: &ranges) }
            }
        case .array(let items, _):
            for item in items { secretRanges(item, into: &ranges) }
        default:
            break
        }
    }
}
