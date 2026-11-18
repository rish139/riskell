// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation

// risk ext (this tool, built as riskell-ext): validate, scaffold and install riskell extensions (docs/EXTENSION-KIT.md). Foundation only.
//   risk ext validate <dir>            check riskell.json and, for compiled kinds, the source against the kit's rules
//   risk ext new <kind> <name>         scaffold: reading | atom | pill | theme
//   risk ext search <words>            what the registry lists (RISKELL_REGISTRY points at another one)
//   risk ext info <name>               one listing
//   risk ext add <name|dir|git-url> [rev] [--yes]   a name is installed at the commit the registry pins; a pill or theme is just files, applied live
//   risk ext update [name] [--yes]     what the registry pins now; shows the change first, applies only with --yes
//   risk ext publish [dir]             check an extension is ready to be listed and print its registry listing
//   risk ext remove <id>               take it out again
//   risk ext list                      what is installed
//   risk ext sync                      regenerate Sources/riskell/Generated/InstalledPackages.swift and InstalledSettings.swift from the lock
// The same binary renders the `risk` command line from the table in CommandTable.swift:
//   help [command]                     the front door, or one command in detail (aliases work too; a group lists its subcommands)
//   completions <zsh|fish|bash>        the table as a shell completion script, descriptions included
//   docs                               docs/CLI.md: the table as markdown, for redirecting to the file
//   ctl <word> [--json] [--dry-run]    one word to the running bar, or --list: the socket without `printf | nc -U`
//   log [N] [--follow] [--json]        the last log lines, or a follower
//   snap <maker>…|all --out DIR        the picture set from scratch instances (Snap.swift), or --list: what it is
//   bench [idle|card <atom>|all] [--runs N] [--json]   the numbers docs/EFFICIENCY.md publishes, measured again (Bench.swift), or --list
// Exit status: 0 ok, 1 findings or a failed command, 2 usage.

let fm = FileManager.default
let compiled: Set<String> = ["reading", "atom", "behaviour"]
let kinds = ["pill", "theme", "preset", "reading", "atom", "behaviour"]

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
func usage() -> Never {
    print("usage: risk ext search <words> | info <name> | add <name|dir|git-url> [rev] | update [name] [--yes] | publish [dir] | remove <id> | list | validate <dir> | new <reading|atom|pill|theme> <name> | sync | help [command] | completions <zsh|fish|bash> | docs | ctl <word|--list> [--json] [--dry-run] | log [N] [--follow] [--json] | snap <maker>…|all --out DIR [--json] [--dry-run] | bench [idle|card <atom>|all|--list] [--runs N] [--json] [--emit-doc]")
    exit(2)
}
func read(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }
func write(_ s: String, _ p: String) { try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true); try? s.write(toFile: p, atomically: true, encoding: .utf8) }
func matches(_ s: String, _ re: String) -> Bool { s.range(of: re, options: .regularExpression) != nil }

/// The riskell checkout this tool is run from (Checkout.swift): RISKELL_ROOT when scripts/risk sets it, else the nearest parent holding
/// extensions.lock.json. A command run outside one has nothing to work on, so it stops here.
func root() -> String {
    if let found = checkout() { return found }
    fail("risk ext: run it inside the riskell checkout (no extensions.lock.json found above here)")
}

// MARK: manifest

struct Finding { var rule: String; var file: String; var line: Int?; var message: String; var fix: String }
var findings: [Finding] = []
func report(_ rule: String, _ file: String, _ line: Int? = nil, _ message: String, fix: String) { findings.append(Finding(rule: rule, file: file, line: line, message: message, fix: fix)) }

/// SPDX identifiers that are common in open source; anything else is a warning to check the spelling against spdx.org/licenses.
let spdx: Set<String> = ["MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "MPL-2.0", "GPL-2.0-only", "GPL-3.0-only", "GPL-3.0-or-later",
                         "LGPL-3.0-only", "AGPL-3.0-only", "Unlicense", "CC0-1.0", "0BSD", "Zlib", "BUSL-1.1", "FSL-1.1-MIT", "FSL-1.1-Apache-2.0",
                         "PolyForm-Noncommercial-1.0.0", "PolyForm-Small-Business-1.0.0", "Prosperity-3.0.0"]

func validateManifest(_ dir: String) -> [String: Any]? {
    let file = dir + "/riskell.json"
    guard let text = read(file) else { report("manifest.missing", "riskell.json", nil, "no riskell.json in \(dir)", fix: "run `risk ext new <kind> <name>` or add the file"); return nil }
    guard let j = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
        report("manifest.json", "riskell.json", nil, "not a JSON object", fix: "fix the syntax"); return nil
    }
    func str(_ k: String) -> String? { j[k] as? String }
    for k in ["id", "kind", "name", "version", "license", "summary"] where str(k)?.isEmpty != false {
        report("manifest.required", "riskell.json", nil, "\"\(k)\" is required", fix: "add \"\(k)\"")
    }
    if let id = str("id"), !matches(id, "^[a-z0-9][a-z0-9-]{0,38}$") { report("manifest.id", "riskell.json", nil, "id \"\(id)\" must be lowercase letters, digits and - (at most 39)", fix: "rename it, e.g. \"gpu-load\"") }
    if let k = str("kind"), !kinds.contains(k) { report("manifest.kind", "riskell.json", nil, "kind \"\(k)\" is not one of \(kinds.joined(separator: ", "))", fix: "use one of them") }
    if let v = str("version"), !matches(v, #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#) { report("manifest.version", "riskell.json", nil, "version \"\(v)\" is not SemVer", fix: "use MAJOR.MINOR.PATCH, e.g. 1.0.0") }
    if let l = str("license"), !spdx.contains(l), !matches(l, #"^LicenseRef-"#) { report("manifest.license", "riskell.json", nil, "license \"\(l)\" is not a common SPDX identifier (warning)", fix: "check the spelling at spdx.org/licenses") }
    if let s = str("summary"), s.count > 140 { report("manifest.summary", "riskell.json", nil, "summary is \(s.count) characters (140 at most)", fix: "shorten it") }
    if let k = str("kind"), compiled.contains(k) {
        for f in ["kit", "module", "entry"] where str(f)?.isEmpty != false { report("manifest.required", "riskell.json", nil, "\"\(f)\" is required for kind \(k)", fix: "add \"\(f)\"") }
        if let kit = str("kit"), !matches(kit, #"^\^?\d+\.\d+(\.\d+)?$"#) { report("manifest.kit", "riskell.json", nil, "kit \"\(kit)\" must be a SemVer range such as ^0.6", fix: "write ^MAJOR.MINOR") }
        if !fm.fileExists(atPath: dir + "/Package.swift") { report("package.missing", "Package.swift", nil, "a compiled extension is a Swift package", fix: "add a Package.swift with a library product named after \"module\"") }
    }
    if let k = str("kind"), ["pill", "theme", "preset"].contains(k) {
        let files = j["files"] as? [String] ?? []
        if files.isEmpty { report("manifest.required", "riskell.json", nil, "\"files\" is required for kind \(k)", fix: "list the files to install, e.g. [\"pill.json\"]") }
        for f in files where !fm.fileExists(atPath: dir + "/" + f) { report("manifest.files", "riskell.json", nil, "\"\(f)\" is listed but not in the repo", fix: "add the file or remove it from \"files\"") }
    }
    if let list = j["settings"] {
        if let k = str("kind"), !compiled.contains(k) { report("manifest.settings", "riskell.json", nil, "\"settings\" is for compiled kinds", fix: "remove it, or make the kind reading, atom or behaviour") }
        guard let items = list as? [[String: Any]] else { report("manifest.settings", "riskell.json", nil, "\"settings\" must be a list of objects", fix: "write [{\"key\": ..., \"label\": ..., \"type\": ..., \"default\": ...}]"); return j }
        var seen = Set<String>()
        for (i, s) in items.enumerated() {
            let at = "settings[\(i)]"
            guard let key = s["key"] as? String, matches(key, "^[A-Za-z][A-Za-z0-9_]*$"), seen.insert(key).inserted else { report("manifest.settings", "riskell.json", nil, "\(at): \"key\" must be plain letters and digits and unique", fix: "e.g. \"warnAt\""); continue }
            if let l = s["label"] as? String, !l.isEmpty, l.count <= 24 {} else { report("manifest.settings", "riskell.json", nil, "\(at) (\(key)): \"label\" is required and at most 24 characters", fix: "add a short label for the card") }
            switch s["type"] as? String {
            case "number":
                guard let lo = (s["min"] as? NSNumber)?.doubleValue, let hi = (s["max"] as? NSNumber)?.doubleValue, let st = (s["step"] as? NSNumber)?.doubleValue, let d = (s["default"] as? NSNumber)?.doubleValue, lo < hi, st > 0, d >= lo, d <= hi
                else { report("manifest.settings", "riskell.json", nil, "\(at) (\(key)): a number needs min < max, step > 0 and a default between them", fix: "add min, max, step and default"); continue }
            case "bool":
                if !(s["default"] is Bool) { report("manifest.settings", "riskell.json", nil, "\(at) (\(key)): a bool needs \"default\": true or false", fix: "add the default") }
            case "choice":
                guard let o = s["options"] as? [String], o.count >= 2, o.count <= 4, Set(o).count == o.count, let d = s["default"] as? String, o.contains(d)
                else { report("manifest.settings", "riskell.json", nil, "\(at) (\(key)): a choice needs 2 to 4 distinct options and a default among them", fix: "add options and default"); continue }
            default: report("manifest.settings", "riskell.json", nil, "\(at) (\(key)): \"type\" must be number, bool or choice", fix: "use one of them (text settings stay in the file)")
            }
        }
    }
    if let pv = j["preview"] as? String {
        let f = dir + "/" + pv
        if !pv.lowercased().hasSuffix(".png") || !fm.fileExists(atPath: f) { report("manifest.preview", "riskell.json", nil, "preview \"\(pv)\" is not a PNG in the repository", fix: "add the picture, e.g. docs/preview.png") }
        else if let size = (try? fm.attributesOfItem(atPath: f))?[.size] as? Int, size > 500_000 { report("manifest.preview", "riskell.json", nil, "preview is \(size / 1000) KB (500 KB at most)", fix: "shrink it") }
    }
    if let a = j["atoms"] as? [String] {
        var seen = Set<String>()
        for id in a where !matches(id, "^[A-Za-z0-9_-]+$") || !seen.insert(id).inserted { report("manifest.atoms", "riskell.json", nil, "atom id \"\(id)\" is not plain or is repeated", fix: "letters, digits, - and _, each once") }
    }
    // A port says what it came from: the original project, the commit, its license and its authors. All four, or none.
    if let df = j["derivedFrom"], !(df is [String: Any]) {
        report("manifest.derived-from", "riskell.json", nil, "\"derivedFrom\" must be an object saying what the extension was ported from", fix: "write {\"repo\": \"https://github.com/author/project\", \"rev\": \"<40 or 64 hex>\", \"license\": \"MIT\", \"authors\": [\"their name\"]}")
    } else if let d = j["derivedFrom"] as? [String: Any] {
        if (d["repo"] as? String)?.isEmpty != false { report("manifest.derived-from", "riskell.json", nil, "\"derivedFrom\" has no \"repo\": a port must name the project it came from", fix: "add \"repo\": its https address, e.g. \"https://github.com/author/project\"") }
        if let rev = d["rev"] as? String, !rev.isEmpty {
            if !matches(rev, "^(?:[0-9a-f]{40}|[0-9a-f]{64})$") { report("manifest.derived-from", "riskell.json", nil, "derivedFrom.rev \"\(rev)\" is not a full commit hash", fix: "use the 40- or 64-character hex commit (`git rev-parse HEAD`), not a short one") }
        } else { report("manifest.derived-from", "riskell.json", nil, "\"derivedFrom\" has no \"rev\": a port must say which commit it came from", fix: "add \"rev\": the full hash, `git rev-parse HEAD` in the original repository") }
        if let l = d["license"] as? String, !l.isEmpty {
            if !spdx.contains(l) { report("manifest.derived-from", "riskell.json", nil, "derivedFrom.license \"\(l)\" is not an SPDX identifier this tool knows", fix: "use the original project's SPDX id, e.g. MIT or Apache-2.0") }
        } else { report("manifest.derived-from", "riskell.json", nil, "\"derivedFrom\" has no \"license\": a port must say what the original is licensed under", fix: "add \"license\": its SPDX id, e.g. MIT") }
        if let a = d["authors"] as? [String], !a.isEmpty, a.allSatisfy({ !$0.isEmpty }) {} else { report("manifest.derived-from", "riskell.json", nil, "\"derivedFrom\" needs \"authors\": one or more non-empty names", fix: "add \"authors\": [\"who wrote the original\"]") }
        if str("license")?.isEmpty != false { report("manifest.derived-from", "riskell.json", nil, "\"derivedFrom\" on a manifest with no \"license\" of its own: you cannot claim provenance while claiming nothing about yourself", fix: "add \"license\": yours, e.g. the original's if you kept it") }
    }
    return j
}

// MARK: source rules

let rules: [(id: String, re: String, why: String, fix: String)] = [
    ("no-raw-color", #"\bColor\(|\bColor\.(red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|white|black|gray|primary|secondary)\b|\bNSColor\b"#,
     "colours come from the theme", "use Pal.text1 ... Pal.accent, Pal.heat(x) or a Tone"),
    ("no-fixed-font", #"\.font\(\s*\.system\("#, "type comes from the type scale", "use T.value, T.unit, T.cap, T.sub or Pal.font(size, weight)"),
    ("no-screen-api", #"\bNSScreen\b|\bCGDisplay|\bbackingScaleFactor\b"#, "an extension must not see the screen: lengths are design units",
     "use G.pill, G.strip and relative layout; the app scales everything"),
    ("no-own-timers", #"\bTimer\b|\bDispatchSource\w*|\bThread\b|\bCADisplayLink\b|\bCVDisplayLink\b|\bRunLoop\.\w+\.add"#, "nothing may wake up on its own",
     "use env.every, env.watch, env.on (readings) or env.repeating (custom atoms)"),
    ("no-window-api", #"\bNSWindow\b|\bNSPanel\b|\bNSApplication\b|\bNSApp\b"#, "the app owns every window", "draw a view; the app places it"),
]

func lint(_ dir: String) {
    guard let en = fm.enumerator(atPath: dir + "/Sources") else { return }
    var any = false
    for case let rel as String in en where rel.hasSuffix(".swift") {
        any = true
        guard let src = read(dir + "/Sources/" + rel) else { continue }
        for (i, raw) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            for r in rules where matches(line, r.re) { report(r.id, "Sources/" + rel, i + 1, r.why, fix: r.fix) }
        }
    }
    if !any { report("source.missing", "Sources/", nil, "no Swift sources", fix: "a compiled extension needs code under Sources/<module>") }
}

func validate(_ dir: String) -> Bool {
    findings = []
    let j = validateManifest(dir)
    if let k = j?["kind"] as? String, compiled.contains(k) {
        lint(dir)
        if let ids = j?["atoms"] as? [String], let all = allSource(dir) {
            for id in ids where !all.contains("id: \"\(id)\"") { report("manifest.atoms", "riskell.json", nil, "atom \"\(id)\" is listed but no AtomMeta(id: \"\(id)\") is in the source", fix: "make the manifest and the code agree") }
        }
    }
    for f in findings.sorted(by: { ($0.file, $0.line ?? 0) < ($1.file, $1.line ?? 0) }) {
        print("\(f.file)\(f.line.map { ":\($0)" } ?? ""): rule \(f.rule): \(f.message). Fix: \(f.fix).")
    }
    let errors = findings.filter { !$0.message.hasSuffix("(warning)") }
    print(errors.isEmpty ? "ok: \((j?["id"] as? String) ?? dir) is valid" + (findings.isEmpty ? "" : " (\(findings.count) warning)") : "\(errors.count) problem(s)")
    return errors.isEmpty
}
func allSource(_ dir: String) -> String? {
    guard let en = fm.enumerator(atPath: dir + "/Sources") else { return nil }
    return en.compactMap { ($0 as? String).flatMap { $0.hasSuffix(".swift") ? read(dir + "/Sources/" + $0) : nil } }.joined(separator: "\n")
}

// MARK: lock and generated list

/// A setting as the manifest declares it, kept in the lock so the generated list does not need the package's source (a git package is cloned to a temporary folder).
struct SettingDecl: Codable { var key: String; var label: String; var type: String; var min: Double?; var max: Double?; var step: Double?; var number: Double?; var on: Bool?; var options: [String]?; var choice: String? }
struct Locked: Codable { var id: String; var module: String; var entry: String; var product: String; var package: String; var path: String?; var url: String?; var revision: String?; var settings: [SettingDecl]?; var version: String? }
func loadLock(_ r: String) -> [Locked] { (read(r + "/extensions.lock.json").flatMap { try? JSONDecoder().decode([Locked].self, from: Data($0.utf8)) }) ?? [] }
func saveLock(_ l: [Locked], _ r: String) {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
    write(String(decoding: (try? e.encode(l)) ?? Data("[]".utf8), as: UTF8.self) + "\n", r + "/extensions.lock.json")
}
func sync(_ r: String) {
    let l = loadLock(r)
    var out = "import RiskellKit\n" + l.map { "import \($0.module)\n" }.joined()
    out += "\n// Generated by `risk ext sync` from extensions.lock.json. Do not edit.\n"
    out += "let installedPackages: [(id: String, package: any RiskellPackage.Type)] = [" + l.map { "(\"\($0.id)\", \($0.module).\($0.entry).self)" }.joined(separator: ", ") + "]\n"
    write(out, r + "/Sources/riskell/Generated/InstalledPackages.swift")
    func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    let decls: [String] = l.flatMap { e in (e.settings ?? []).compactMap { s -> String? in
        let kind: String
        switch s.type {
        case "number": guard let lo = s.min, let hi = s.max, let st = s.step, let d = s.number else { return nil }; kind = ".number(min: \(lo), max: \(hi), step: \(st), def: \(d))"
        case "bool": kind = ".bool(def: \(s.on ?? false))"
        case "choice": guard let o = s.options, let d = s.choice else { return nil }; kind = ".choice([" + o.map(q).joined(separator: ", ") + "], def: \(q(d)))"
        default: return nil
        }
        return "    ExtSetting(ext: \(q(e.id)), key: \(q(s.key)), label: \(q(s.label)), kind: \(kind))"
    } }
    write("// Generated by `risk ext sync` from extensions.lock.json. Do not edit.\nlet installedSettings: [ExtSetting] = [" + (decls.isEmpty ? "]" : "\n" + decls.joined(separator: ",\n") + "\n]") + "\n",
          r + "/Sources/riskell/Generated/InstalledSettings.swift")
    // the same list as a literal inside Package.swift (see the comment there)
    func lit(_ v: String?) -> String { v.map { "\"" + $0 + "\"" } ?? "nil" }
    let rows = l.map { "    Locked(module: \(lit($0.module)), product: \(lit($0.product)), package: \(lit($0.package)), path: \(lit($0.path)), url: \(lit($0.url)), revision: \(lit($0.revision)))" }
    let block = "// BEGIN generated\nlet locked: [Locked] = [" + (rows.isEmpty ? "]" : "\n" + rows.joined(separator: ",\n") + "\n]") + "\n// END generated"
    if var pk = read(r + "/Package.swift"), let b = pk.range(of: "// BEGIN generated"), let e = pk.range(of: "// END generated") {
        pk.replaceSubrange(b.lowerBound..<e.upperBound, with: block)
        write(pk, r + "/Package.swift")
    }
}

func sh(_ args: [String], in dir: String? = nil, env: [String: String] = [:]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
    if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new } }
    if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (127, "") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func add(_ source: String, rev: String?, version: String? = nil, expectID: String? = nil, userTyped: Bool = false, yes: Bool = false) {
    let r = root()
    var dir = source, url: String?, revision = rev
    if source.contains("://") || source.hasPrefix("git@") {      // a git URL (https, ssh, file); anything else is a folder
        guard safeRepoURL(source, userTyped: userTyped) else { fail("risk ext: \(source) is not an address this tool will clone (https only; ssh and local paths only when you type them yourself)") }
        if let rev, !matches(rev, "^[0-9a-f]{7,40}$") { fail("risk ext: \(rev) is not a commit hash") }
        dir = NSTemporaryDirectory() + "risk-ext-" + UUID().uuidString
        let (c, _) = git(["clone", "--quiet", "--", source, dir], userTyped: userTyped)
        guard c == 0 else { fail("risk ext: could not clone \(source)") }
        if let rev { _ = git(["checkout", "--quiet", rev], in: dir, userTyped: userTyped) }
        revision = git(["rev-parse", "HEAD"], in: dir, userTyped: userTyped).1
        if let rev, revision != rev { fail("risk ext: commit \(rev.prefix(10)) is not in \(source)") }
        url = source
    } else { dir = URL(fileURLWithPath: source, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardized.path }
    guard validate(dir), let j = (read(dir + "/riskell.json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any],
          let id = j["id"] as? String, let module = j["module"] as? String, let entry = j["entry"] as? String
    else { fail("risk ext: not added: fix the findings above") }
    if let e = expectID, e != id { fail("risk ext: not added: the listing says \"\(e)\" but riskell.json says \"\(id)\"") }
    if let v = version, let mv = j["version"] as? String, mv != v { fail("risk ext: not added: the listing says v\(v) but riskell.json says v\(mv)") }
    if url != nil {      // a repository you did not write: show it, and ask, before anything is built
        let lic = j["license"] as? String ?? "?", nm = j["name"] as? String ?? id, ver = j["version"] as? String ?? "?"
        consent("Install \"\(nm)\" (\(id))?", ["\(nm) \(ver), license \(lic)", "source: \(source) at \(revision ?? "?")",
            "It is Swift code that is compiled into riskell and runs with your user's rights. There is no sandbox and no permission system.",
            "Read it before you say yes."], yes: yes)
    }
    var l = loadLock(r).filter { $0.id != id }
    let pkg = ((url ?? dir) as NSString).lastPathComponent.replacingOccurrences(of: ".git", with: "")
    // a path is stored relative to the checkout when it is inside it, so the lock can be committed
    let rel = url == nil ? (dir.hasPrefix(r + "/") ? String(dir.dropFirst(r.count + 1)) : dir) : nil
    let decls: [SettingDecl] = (j["settings"] as? [[String: Any]] ?? []).compactMap { s in
        guard let key = s["key"] as? String, let label = s["label"] as? String, let type = s["type"] as? String else { return nil }
        func n(_ k: String) -> Double? { (s[k] as? NSNumber)?.doubleValue }
        return SettingDecl(key: key, label: label, type: type, min: n("min"), max: n("max"), step: n("step"), number: type == "number" ? n("default") : nil,
                           on: type == "bool" ? s["default"] as? Bool : nil, options: s["options"] as? [String], choice: type == "choice" ? s["default"] as? String : nil)
    }
    l.append(Locked(id: id, module: module, entry: entry, product: module, package: pkg, path: rel, url: url, revision: revision, settings: decls.isEmpty ? nil : decls, version: version ?? (j["version"] as? String)))
    saveLock(l, r); sync(r)
    print("added \(id); the lock and the import list are updated. `risk dev` rebuilds and restarts riskell (`risk ext add` does that for you).")
}

// MARK: scaffolds

func scaffold(_ kind: String, _ name: String) {
    guard matches(name, "^[a-z][a-z0-9-]{0,38}$") else { fail("risk ext: the name must be lowercase letters, digits and - (e.g. gpu-load)") }
    let dir = fm.currentDirectoryPath + "/" + name
    guard !fm.fileExists(atPath: dir) else { fail("risk ext: \(name) already exists here") }
    let type = name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    let module = type + "Ext"
    func manifest(_ kind: String, _ extra: String = "") -> String {
        """
        {
          "$schema": "https://raw.githubusercontent.com/rish139/riskell/main/schemas/riskell-extension.schema.json",
          "id": "\(name)",
          "kind": "\(kind)",
          "name": "\(type)",
          "version": "0.1.0",
          "license": "MIT",
          "summary": "What \(type) shows, in one sentence."\(extra)
        }

        """
    }
    func package() -> String {
        """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(
            name: "\(name)",
            platforms: [.macOS(.v14)],
            products: [.library(name: "\(module)", targets: ["\(module)"])],
            dependencies: [.package(url: "https://github.com/rish139/riskell-kit", .upToNextMinor(from: "0.6.0"))],
            targets: [.target(name: "\(module)", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")])]
        )

        """
    }
    let compiledExtra = ",\n  \"kit\": \"^0.6\",\n  \"module\": \"\(module)\",\n  \"entry\": \"\(type)Package\",\n  \"atoms\": [\"\(name)\"]"
    switch kind {
    case "reading":
        write(manifest("reading", compiledExtra), dir + "/riskell.json"); write(package(), dir + "/Package.swift")
        write("""
        import SwiftUI
        import RiskellKit

        public enum \(type)Package: RiskellPackage {
            public static var readings: [any ReadingAtom.Type] { [\(type).self] }
        }

        /// The kit draws the row, the column and the card. Only the numbers are ours.
        public struct \(type): ReadingAtom {
            public static let meta = AtomMeta(id: "\(name)", name: "\(type)")
            public init() {}
            public func readings(_ env: Env) -> AsyncStream<Reading?> {
                env.every(.seconds(10)) {
                    Reading(text: "42", icon: "bolt.fill", tone: .heat(0.42), value: 0.42, lines: ["Replace me with a real figure"])
                }
            }
        }

        """, dir + "/Sources/\(module)/\(type).swift")
    case "atom":
        write(manifest("atom", compiledExtra), dir + "/riskell.json"); write(package(), dir + "/Package.swift")
        write("""
        import SwiftUI
        import RiskellKit

        public enum \(type)Package: RiskellPackage {
            public static var atoms: [any CustomAtom.Type] { [\(type).self] }
        }

        /// Both forms are required. Colours only through Pal, type only through T, lengths in design units.
        public struct \(type): CustomAtom {
            public static let meta = AtomMeta(id: "\(name)", name: "\(type)")
            public init() {}
            public func horizontal(_ env: Env) -> some View {
                HStack(spacing: T.gap) { Cap(text: "\(type.uppercased())"); Num(value: "42", unit: "%") }.frame(height: G.pill)
            }
            public func vertical(_ env: Env) -> some View {
                VStack(spacing: 3) { Cap(text: "\(type.uppercased())"); Num(value: "42", unit: nil) }.fixedSize().frame(width: 40)
            }
        }

        """, dir + "/Sources/\(module)/\(type).swift")
    case "pill":
        write(manifest("pill", ",\n  \"files\": [\"pill.json\"]"), dir + "/riskell.json")
        write("{ \"id\": \"\(name)\", \"name\": \"\(type)\", \"run\": \"echo 42\", \"every\": 30 }\n", dir + "/pill.json")
    case "theme":
        write(manifest("theme", ",\n  \"files\": [\"\(name).yaml\"]"), dir + "/riskell.json")
        var yaml = "name: \"\(type)\"\nauthor: \"you\"\nvariant: \"dark\"\n"
        for i in 0..<16 {
            let hex = String(format: "%02x", i * 16)
            yaml += "base0" + String(i, radix: 16, uppercase: true) + ": \"" + hex + hex + hex + "\"\n"
        }
        write(yaml, dir + "/\(name).yaml")
    default: fail("risk ext: new <reading|atom|pill|theme> <name>")
    }
    print("created \(name)/ (\(kind)). Next: edit it, then `risk ext validate \(name)`.")
}

// MARK: dispatch

let a = Array(CommandLine.arguments.dropFirst())
switch a.first {
case "help": exit(HelpScreen.run(Array(a.dropFirst())))
case "completions":
    guard a.count == 2, let script = Completions.script(a[1]) else {
        FileHandle.standardError.write(Data("risk: completions <zsh|fish|bash>\n".utf8)); exit(2)
    }
    print(script)
case "docs": print(Docs.markdown())
case "ctl": exit(Ctl.run(Array(a.dropFirst())))
case "log": exit(LogCommand.run(Array(a.dropFirst())))
case "snap": exit(Snap.run(Array(a.dropFirst())))
case "bench": exit(Bench.run(Array(a.dropFirst())))
case "validate": exit(a.count > 1 && validate(a[1]) ? 0 : 1)
case "new": if a.count == 3 { scaffold(a[1], a[2]) } else { usage() }
case "add":
    let yes = a.contains("--yes"), args = a.filter { !$0.hasPrefix("--") }
    guard args.count >= 2 else { usage() }
    // a name is looked up in the registry; a folder or a git URL is installed as it is
    if args[1].contains("/") || args[1].contains(":") || fm.fileExists(atPath: args[1]) { add(args[1], rev: args.count > 2 ? args[2] : nil, userTyped: true, yes: yes); exit(needsRebuild) } else { addByName(args[1], yes: yes) }
case "remove":
    guard a.count == 2 else { usage() }
    if removeFiles(a[1]) { break }
    let r = root(); let before = loadLock(r)
    saveLock(before.filter { $0.id != a[1] }, r); sync(r)
    print(before.contains { $0.id == a[1] } ? "removed \(a[1]); `risk dev` rebuilds and restarts riskell (`risk ext remove` does that for you)" : "\(a[1]) is not installed")
    if before.contains(where: { $0.id == a[1] }) { exit(needsRebuild) }
case "list":
    let l = loadLock(root()), f = loadInstalled()
    if l.isEmpty && f.isEmpty { print("no extensions installed") }
    else {
        for e in l { print("\(e.id)  \(e.module).\(e.entry)  \(e.version.map { "v" + $0 + "  " } ?? "")\(e.url ?? e.path ?? "")\(e.revision.map { " @ " + $0.prefix(8) } ?? "")") }
        for e in f { print("\(e["id"] as? String ?? "")  \(e["kind"] as? String ?? "")  v\(e["version"] as? String ?? "")  \((e["files"] as? [String] ?? []).joined(separator: ", "))") }
    }
case "search": search(Array(a.dropFirst()))
case "info": if a.count == 2 { info(a[1]) } else { usage() }
case "update": update(Array(a.dropFirst()))
case "publish": publish(a.count > 1 ? a[1] : nil)
case "sync": sync(root()); print("synced")
default: usage()
}
