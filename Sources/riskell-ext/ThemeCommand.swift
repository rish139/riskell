// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `riskell-ext theme`: riskell's colour schemes as a command, so nobody types `riskell --list-themes`. The maths stays in the app
/// (`Themes/Theme.swift` resolves a scheme and moves a colour that misses its floor); this asks the built `riskell` what it resolved and
/// reports that, and it is the one place a scheme file is put where the app reads it.
enum ThemeCommand {
    static let schema = "riskell.theme/1"

    static func run(_ args: [String]) -> Int32 {
        guard let sub = args.first else { return usage("theme", "list, check or import") }
        switch sub {
        case "list": return list(Array(args.dropFirst()))
        case "check": return check(Array(args.dropFirst()))
        case "import": return importScheme(Array(args.dropFirst()))
        default: return usage("theme", "no subcommand \"\(sub)\"")
        }
    }

    // MARK: - the folders

    /// The app's themes folder is `AppConfig.directory`'s `themes` (`Themes/Theme.swift`), so `RISKELL_CONFIG` moves it with the config.
    /// `RISKELL_THEME_DIR` is not the app's: it is this tool's own scratch folder, for trying an import without writing where the app looks.
    /// An import there says so rather than claiming the app sees it.
    private struct Themes {
        let folder: String      // where this tool writes
        let app: String         // where the built riskell reads

        init() {
            let environment = ProcessInfo.processInfo.environment
            let config = ThemeCommand.absolute(environment["RISKELL_CONFIG"] ?? homePath() + "/.config/riskell/config.json")
            app = URL(fileURLWithPath: config).deletingLastPathComponent().appendingPathComponent("themes").path
            folder = environment["RISKELL_THEME_DIR"].map(ThemeCommand.absolute) ?? app
        }
    }

    /// Absolute, with a relative value read from here rather than from a helper's working folder.
    private static func absolute(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardized.path
    }

    /// A path as a person reads it: `~/…` under the home folder, absolute everywhere else.
    private static func shown(_ path: String) -> String {
        let home = homePath()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + String(path.dropFirst(home.count + 1)) }
        return path
    }

    // MARK: - asking the app

    /// `.build/release/riskell`: nil when it is not built, which is a thing to say rather than to build here.
    private static func binary() -> String? {
        guard let root = checkout() else { return nil }
        let path = root + "/.build/release/riskell"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static let notBuilt = "riskell is not built, and this asks the app rather than guessing"

    /// The app's answer to one question, or nil when it is not built or did not finish. The environment is inherited, so a scratch
    /// `RISKELL_CONFIG` has the app read the same folder this wrote to.
    private static func ask(_ arguments: [String]) -> String? {
        guard let binary = binary() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `riskell --list-themes`: every scheme with the tokens the app resolved from it. The array's own text comes back too, so the JSON a
    /// script gets is the app's own spelling of it. A user file the app cannot read is warned about on stdout before the JSON, so the array
    /// starts at the first `[`.
    private static func catalog() -> (text: String, rows: [[String: Any]])? {
        guard let output = ask(["--list-themes"]), let start = output.firstIndex(of: "[") else { return nil }
        let text = String(output[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rows = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return nil }
        return (text, rows)
    }

    // MARK: - list

    private static func list(_ args: [String]) -> Int32 {
        var json = false
        for arg in args {
            switch arg {
            case "--json": json = true
            default: return usage("theme list", "takes only --json, not \"\(arg)\"")
            }
        }
        guard binary() != nil else { return fail(notBuilt, tries: [(cmd: "swift build -c release", note: "builds .build/release/riskell")]) }
        guard let listed = catalog() else { return fail("riskell --list-themes printed no list of schemes") }
        let themes = Themes()

        if json {
            print("{\n  \"schema\": \(jsonQuoted(schema)),\n  \"action\": \"list\",\n  \"folder\": \(jsonQuoted(shown(themes.app))),\n  \"schemes\": \(listed.text)\n}")
            return 0
        }

        let tty = Terminal.tty()
        let count = listed.rows.count
        var lines = tty.tableHead(title: "theme list", meta: "\(count) scheme\(count == 1 ? "" : "s")")
        lines += tty.entries(listed.rows.map { row in
            let isDefault = row["default"] as? Bool ?? false
            return (tone: isDefault ? Tone.ok : Tone.note, name: row["id"] as? String ?? "",
                    tag: "", version: row["variant"] as? String ?? "", mark: isDefault ? "default" : nil,
                    text: row["name"] as? String ?? "")
        })
        lines.append("")
        lines += tty.paragraph("in \(shown(themes.app)); a Base16 .yaml there is one of them")
        lines.append(tty.footerHint([(cmd: "risk theme check", text: "every scheme's contrast"),
                                     (cmd: "risk theme import <file.yaml>", text: "bring one in")]))
        print(lines.joined(separator: "\n"))
        return 0
    }

    // MARK: - check

    /// One line of `riskell --check-themes`: the scheme, its variant and the eight WCAG ratios, each carrying the app's own `*` when it is
    /// below its floor. The floors are the app's (`Theme.Floor`), so a `*` is read, never recomputed.
    private struct Ratio {
        let token: String
        let value: String
        let below: Bool
    }

    private struct Checked {
        let id: String
        let variant: String
        let ratios: [Ratio]

        var belowFloor: Bool { ratios.contains(where: \.below) }
    }

    /// The columns `Theme.check` prints, in its order.
    private static let ratioTokens = ["text1", "text2", "text3", "text4", "accent", "ok", "warn", "crit"]

    private static func check(_ args: [String]) -> Int32 {
        var json = false
        var wanted: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json": json = true; index += 1
            case "--scheme":
                guard index + 1 < args.count else { return usage("theme check", "--scheme needs a scheme id") }
                wanted = args[index + 1]; index += 2
            default: return usage("theme check", "unexpected \"\(args[index])\"")
            }
        }
        guard binary() != nil else { return fail(notBuilt, tries: [(cmd: "swift build -c release", note: "builds .build/release/riskell")]) }
        guard let output = ask(["--check-themes", "--rows"]) else { return fail("riskell --check-themes printed nothing") }
        let rows = output.split(whereSeparator: \.isNewline).map(String.init)
        let checked = rows.compactMap { row(in: $0) }
        guard !checked.isEmpty else { return fail("riskell --check-themes printed no scheme rows") }

        let picked = wanted.map { id in checked.filter { $0.id == id } } ?? checked
        if let wanted, picked.isEmpty { return fail("no scheme \"\(wanted)\": risk theme list has them all") }
        let below = picked.filter(\.belowFloor).map(\.id)

        if json {
            let rows = picked.map { scheme -> String in
                let ratios: [String] = scheme.ratios.map { r -> String in
                    jsonQuoted(r.token) + ": {\"ratio\": " + String(describing: r.value) + ", \"below\": " + String(r.below) + "}"
                }
                var row: String = "    {\"id\": " + jsonQuoted(scheme.id) + ", \"variant\": " + jsonQuoted(scheme.variant)
                row += ", \"belowFloor\": " + String(scheme.belowFloor) + ", "
                row += "\"ratios\": {" + ratios.joined(separator: ", ") + "}}"
                return row
            }
            // Built in pieces: one long interpolated concatenation is more than some compilers will type-check in reasonable time.
            let schemaText: String = jsonQuoted(schema)
            let rowsText: String = rows.isEmpty ? "]" : "\n" + rows.joined(separator: ",\n") + "\n  ]"
            let belowText: String = below.map(jsonQuoted).joined(separator: ", ")
            var document: String = "{\n  \"schema\": " + schemaText + ",\n  \"action\": \"check\",\n"
            document += "  \"schemes\": [" + rowsText + ",\n  \"below\": [" + belowText + "]}"
            print(document)
            return below.isEmpty ? 0 : 1
        }

        let tty = Terminal.tty()
        let keyWidth = max(picked.map(\.id.count).max() ?? 0, "floors".count) + 1
        var lines = [tty.header("theme check", detail: "WCAG ratio against the surface; * is below its floor")]
        lines += picked.flatMap { scheme -> [String] in
            let ratios = scheme.ratios.map { "\($0.token) \($0.value)\($0.below ? "*" : "")" }.joined(separator: ", ")
            return tty.check(scheme.belowFloor ? .crit : .ok, scheme.id, "\(scheme.variant) · \(ratios)", keyWidth: keyWidth)
        }
        lines.append("")
        let schemes = "\(picked.count) scheme\(picked.count == 1 ? "" : "s")"
        let floors = picked.count == 1 ? "its floor" : "their floors"
        if below.isEmpty {
            lines += tty.check(.ok, "floors", "\(schemes) above \(floors)", keyWidth: keyWidth)
        } else {
            lines += tty.check(.crit, "floors", "\(below.count) of \(schemes) below \(floors): \(below.joined(separator: ", "))", keyWidth: keyWidth)
        }
        lines.append(tty.footerHint([(cmd: "risk theme list", text: "every scheme in the catalog")]))
        print(lines.joined(separator: "\n"))
        return below.isEmpty ? 0 : 1
    }

    /// One `riskell --check-themes` row, or nil for the header and for anything else the app printed. Two names and the eight ratios, so a
    /// warning about a user file cannot be mistaken for a scheme.
    private static func row(in line: String) -> Checked? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == ratioTokens.count + 2, fields[1] == "dark" || fields[1] == "light" else { return nil }
        var ratios: [Ratio] = []
        for (token, field) in zip(ratioTokens, fields.dropFirst(2)) {
            let below = field.hasSuffix("*")
            let value = below ? String(field.dropLast()) : field
            guard Double(value) != nil else { return nil }
            ratios.append(Ratio(token: token, value: value, below: below))
        }
        return Checked(id: fields[0], variant: fields[1], ratios: ratios)
    }

    // MARK: - import

    /// A Base16 scheme as its file spells it. The sixteen slots are the whole test of "is this one"; `name` and `variant` are what the app
    /// reads from the same lines (`Theme.parseBase16`), so nothing here is a second opinion about them.
    private struct Imported {
        let name: String
        let variant: String
    }

    private static func importScheme(_ args: [String]) -> Int32 {
        var file: String?
        var id: String?
        var force = false, dryRun = false, json = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json": json = true; index += 1
            case "--force": force = true; index += 1
            case "--dry-run": dryRun = true; index += 1
            case "--id":
                guard index + 1 < args.count else { return usage("theme import", "--id needs a name") }
                guard id == nil else { return usage("theme import", "--id once") }
                id = args[index + 1]; index += 2
            case let arg where arg.hasPrefix("-"):
                return usage("theme import", "no flag \"\(arg)\"")
            default:
                guard file == nil else { return usage("theme import", "one scheme file at a time") }
                file = args[index]; index += 1
            }
        }
        guard let file else { return usage("theme import", "name the scheme file: import <file.yaml> [--id ID] [--force] [--dry-run]") }

        let source = absolute(file)
        guard let text = try? String(contentsOfFile: source, encoding: .utf8) else {
            return fail("cannot read \(shown(source))",
                        tries: [(cmd: "risk theme import <file.yaml>", note: "the file that holds the scheme, a Base16 .yaml or .yml")])
        }
        let name = id ?? ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        guard matches(name, "^[A-Za-z0-9][A-Za-z0-9._-]*$") else {
            return fail("\"\(name)\" cannot be a scheme id, and it names the file",
                        tries: [(cmd: "risk theme import <file> --id my-scheme", note: "letters, digits, . - and _")])
        }
        let (scheme, problems) = parse(text, id: name)
        guard let scheme, problems.isEmpty else {
            let tty = Terminal.tty()
            var lines = [tty.header("theme import", detail: "not written; \(shown(source))")]
            lines += tty.checks(problems.enumerated().map { index, problem in
                (Tone.crit, "problem \(index + 1)", problem.0, (cmd: problem.1, note: nil) as (cmd: String, note: String?)?)
            })
            for line in lines { FileHandle.standardError.write(Data((line + "\n").utf8)) }
            return 1
        }

        let themes = Themes()
        let target = themes.folder + "/" + name + ".yaml"
        var notes: [String] = []
        if let existing = [themes.folder + "/" + name + ".yaml", themes.folder + "/" + name + ".yml"]
            .first(where: { FileManager.default.fileExists(atPath: $0) }), !force {
            return fail("\(shown(existing)) is already there, and nothing was written",
                        tries: [(cmd: "risk theme import <file> --force", note: "replace it"),
                                (cmd: "risk theme import <file> --id <name>", note: "keep it and add another")])
        }
        if let known = catalog()?.rows.first(where: { ($0["id"] as? String) == name }),      // nil when riskell is not built: nothing to check against
           !FileManager.default.fileExists(atPath: themes.folder + "/" + name + ".yaml"),
           !FileManager.default.fileExists(atPath: themes.folder + "/" + name + ".yml") {
            guard force else {
                return fail("\"\(name)\" is the scheme riskell ships as \"\(known["name"] as? String ?? name)\", and a user file would replace it from now on",
                            tries: [(cmd: "risk theme import <file> --force", note: "replace the shipped scheme"),
                                    (cmd: "risk theme import <file> --id <name>", note: "keep it and add another")])
            }
            notes.append("this replaces the scheme riskell shipped as \"\(name)\"")
        }
        if dryRun {
            if json {
                print(importJSON(name: name, target: target, scheme: scheme, themes: themes, app: nil, notes: notes, dryRun: true))
                return 0
            }
            let tty = Terminal.tty()
            let lines = tty.plan([(verb: "write", text: shown(target))],
                                 note: "dry run, nothing written; the scheme's own bytes go to stdout")
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))      // the bytes go to stdout
            FileHandle.standardOutput.write(Data(text.utf8))
            if !text.hasSuffix("\n") { print("") }
            return 0
        }

        if let problem = write(text, to: target) { return fail(problem) }

        var app: (tokens: [(String, String)], ratios: [Ratio])? = nil
        if themes.folder != themes.app {
            notes.append("RISKELL_THEME_DIR is set and riskell does not read it: the app reads \(shown(themes.app)), so the scheme is not in its catalog")
        } else if binary() == nil {
            notes.append("riskell is not built, so the name was not checked against the app's catalog and the scheme was not shown to it")
        } else if let row = catalog()?.rows.first(where: { ($0["id"] as? String) == name }) {
            let keys = ["bg", "tile", "text1", "text2", "text3", "text4", "accent", "ok", "warn", "crit", "info"]
            app = (keys.compactMap { key in (row[key] as? String).map { (key, $0) } }, checked(name)?.ratios ?? [])
        } else {
            return fail("riskell does not list \"\(name)\" after the write, so it could not read what was just written",
                        tries: [(cmd: "risk theme check --scheme \(name)", note: "what the app resolved"),
                                (cmd: "risk theme import <file> --force", note: "write it again")])
        }

        if json {
            print(importJSON(name: name, target: target, scheme: scheme, themes: themes, app: app, notes: notes, dryRun: false))
            return 0
        }
        let tty = Terminal.tty()
        var rows: [(Tone, String, String, (cmd: String, note: String?)?)] = [
            (.ok, "imported", "\(scheme.name), \(scheme.variant)", nil),
            (.ok, "file", shown(target), nil),
        ]
        for (i, group) in batches(app?.tokens ?? []).enumerated() {
            rows.append((.note, i == 0 ? "tokens" : "", group, nil))
        }
        for (i, group) in batches((app?.ratios ?? []).map { ($0.token, $0.value + ($0.below ? "*" : "")) }).enumerated() {
            rows.append((.note, i == 0 ? "ratios" : "", group, nil))
        }
        if let app, !app.ratios.isEmpty {
            let below = app.ratios.filter(\.below).map(\.token)
            rows.append(below.isEmpty
                        ? (.ok, "floors", "every token above its floor, by the app's own WCAG check", nil)
                        : (.warn, "floors", "\(below.count == 1 ? "below its floor" : "below their floors"): \(below.joined(separator: ", "))", nil))
        }
        for note in notes { rows.append((.note, "note", note, nil)) }
        var lines = [tty.header("theme import", detail: name)]
        lines += tty.checks(rows)
        lines.append("")
        lines.append(tty.footerHint([(cmd: "risk theme check --scheme \(name)", text: "its ratios, read from the app")]))
        print(lines.joined(separator: "\n"))
        return 0
    }

    /// The four slots to a line: a whole palette on one line is wider than a terminal, and a cut token is not a token.
    private static func batches(_ pairs: [(String, String)]) -> [String] {
        stride(from: 0, to: pairs.count, by: 4).map { start in
            pairs[start..<min(start + 4, pairs.count)].map { "\($0.0) \($0.1)" }.joined(separator: "  ")
        }
    }

    /// The app's ratios for one scheme, from the same rows `check` reads.
    private static func checked(_ id: String) -> Checked? {
        guard let output = ask(["--check-themes", "--rows"]) else { return nil }
        return output.split(whereSeparator: \.isNewline).compactMap { row(in: String($0)) }.first { $0.id == id }
    }

    /// The JSON of one import, written in one place so a dry run and a real one cannot describe themselves differently.
    private static func importJSON(name: String, target: String, scheme: Imported, themes: Themes,
                                   app: (tokens: [(String, String)], ratios: [Ratio])?, notes: [String], dryRun: Bool) -> String {
        var out = "{\n  \"schema\": \(jsonQuoted(schema)),\n  \"action\": \"import\",\n  \"id\": \(jsonQuoted(name)),\n" +
                  "  \"file\": \(jsonQuoted(shown(target))),\n  \"dryRun\": \(dryRun),\n" +
                  "  \"scheme\": {\"name\": \(jsonQuoted(scheme.name)), \"variant\": \(jsonQuoted(scheme.variant))}"
        if let app {
            let tokens = app.tokens.map { "\(jsonQuoted($0.0)): \(jsonQuoted($0.1))" }
            let ratios = app.ratios.map { "\(jsonQuoted($0.token)): {\"ratio\": \($0.value), \"below\": \($0.below)}" }
            out += ",\n  \"app\": {\"folder\": \(jsonQuoted(shown(themes.app))), \"belowFloor\": \(app.ratios.contains(where: \.below))," +
                   "\n    \"tokens\": {" + tokens.joined(separator: ", ") + "}," +
                   "\n    \"ratios\": {" + ratios.joined(separator: ", ") + "}}"
        } else {
            out += ",\n  \"app\": null"
        }
        out += ",\n  \"notes\": [" + notes.map(jsonQuoted).joined(separator: ", ") + "]\n}"
        return out
    }

    /// A Base16 scheme as the app's own reader would see it (`Theme.parseBase16`), with the shape checked harder: sixteen slots, each
    /// `#rrggbb`, and a variant that is one of the two. Everything refused comes back with the fix, so a refusal is actionable.
    private static func parse(_ text: String, id: String) -> (scheme: Imported?, problems: [(String, String)]) {
        var name = "", variant = "", system = ""
        var seen = Set<String>()
        var problems: [(String, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]), value = bare(String(line[line.index(after: colon)...]))
            switch key {
            case "name": name = value
            case "variant": variant = value.lowercased()
            case "system": system = value.lowercased()
            case let slot where slot.lowercased().hasPrefix("base0"):
                let key = slot.uppercased()
                guard matches(key, "^BASE0[0-9A-F]$") else { continue }
                seen.insert(key)      // a slot that is there and wrong is one problem, not also a missing one
                let hex = firstWord(value).lowercased()
                guard matches(hex, "^#[0-9a-f]{6}$") else {
                    problems.append(("\(slot) is \"\(firstWord(value))\", and each of the sixteen slots is #rrggbb",
                                     "write six hex digits after the #, e.g. \(slot): \"#2e3440\""))
                    continue
                }
            default: continue
            }
        }
        if !system.isEmpty, system != "base16" {
            problems.append(("system is \"\(system)\", and this reads Base16 schemes (sixteen slots)",
                             "import a Base16 scheme, or set system: \"base16\" if it is one"))
        }
        if !["", "dark", "light"].contains(variant) {
            problems.append(("variant is \"\(variant)\", and a scheme is dark or light",
                             "write variant: \"dark\" or variant: \"light\""))
        }
        let wanted = (0..<16).map { "BASE0" + String($0, radix: 16, uppercase: true) }
        let missing = wanted.filter { !seen.contains($0) }.map { $0.lowercased() }
        if !missing.isEmpty {
            problems.append(("not a Base16 scheme: \(missing.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") missing",
                             "add each one as base0X: \"#rrggbb\"; the sixteen slots are the whole format (docs/THEMES.md)"))
        }
        guard problems.isEmpty else { return (nil, problems) }
        return (Imported(name: name.isEmpty ? id : name, variant: variant.isEmpty ? "dark" : variant), problems)
    }

    /// A YAML value as the app reads it: quotes off, whitespace trimmed.
    private static func bare(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    /// And its first word, which is what the app takes for a slot (`"#2e3440"   # a note`).
    private static func firstWord(_ value: String) -> String {
        bare(value).split(separator: " ").first.map(String.init) ?? ""
    }

    /// The scheme file: the bytes go to a temporary file in the same folder and a rename puts it in place, so a failure leaves what was
    /// there before and never half a scheme.
    private static func write(_ text: String, to path: String) -> String? {
        let fm = FileManager.default
        let folder = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: folder) {
            do { try fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            catch { return "cannot create \(shown(folder)): \(error.localizedDescription)" }
        }
        let temporary = folder + "/." + (path as NSString).lastPathComponent + ".tmp-\(UUID().uuidString)"
        do { try Data(text.utf8).write(to: URL(fileURLWithPath: temporary)) }
        catch { return "cannot write \(shown(temporary)): \(error.localizedDescription)" }
        if rename(temporary, path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(atPath: temporary)
            return "cannot put \(shown(path)) in place: \(reason)"
        }
        return nil
    }

    // MARK: - messages

    private static func usage(_ command: String, _ problem: String) -> Int32 {
        Usage.error(command, problem)
    }

    private static func fail(_ message: String,
                             tries: [(cmd: String, note: String)] = [("risk theme list", "every scheme in the catalog")]) -> Int32 {
        Usage.failure(message, tries: tries)
        return 1
    }
}
