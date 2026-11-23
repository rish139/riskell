// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

// The storefront side of `risk ext` (docs/STOREFRONT.md): search, info, add by name, update. The registry is one JSON file (index.json, built by
// the riskell-registry repository's CI). RISKELL_REGISTRY points at another one: a URL, a file, or a folder holding index.json (tests, a mirror).
// The screens are the kit's (Sources/RiskellTTY): a table of listings, one listing in full, and a check line per action.

let defaultRegistry = "https://rish139.github.io/riskell-registry/index.json"

/// The kit's terminal for these screens: the theme in force, or plain text when the app is not built (Terminal.swift).
func screen() -> Tty { Terminal.tty() }

func printAll(_ lines: [String]) { print(lines.joined(separator: "\n")) }

/// A failure in the shape every command's failure takes: what went wrong, then what to try. stderr and exit 1, as before.
func failBlock(_ title: String, detail: String? = nil, tries: [(cmd: String, note: String)]) -> Never {
    FileHandle.standardError.write(Data((screen().errorBlock(title: title, detail: detail, tries: tries).joined(separator: "\n") + "\n").utf8))
    exit(1)
}

/// A path as a person reads it: `~/...` under the home folder, absolute everywhere else (the same rule as config path).
func shortPath(_ path: String) -> String {
    let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? homePath()
    let normal = URL(fileURLWithPath: home).standardized.path
    if path == normal { return "~" }
    if path.hasPrefix(normal + "/") { return "~/" + String(path.dropFirst(normal.count + 1)) }
    return path
}

/// Exit status that tells `risk` the build changed (a compiled extension was added, removed or updated): it then rebuilds and restarts.
let needsRebuild: Int32 = 10

struct Listing {
    let d: [String: Any]
    var id: String { d["id"] as? String ?? "" }
    var kind: String { d["kind"] as? String ?? "" }
    var name: String { d["name"] as? String ?? id }
    var summary: String { d["summary"] as? String ?? "" }
    var repo: String { d["repo"] as? String ?? "" }
    var rev: String { d["rev"] as? String ?? "" }
    var version: String { d["version"] as? String ?? "" }
    var path: String? { d["path"] as? String }
    var bundled: Bool { d["bundled"] as? Bool ?? false }
    var keywords: [String] { d["keywords"] as? [String] ?? [] }
    var atoms: [String] { d["atoms"] as? [String] ?? [] }
    /// What a ported extension came from, when its manifest says `derivedFrom` (schemas/riskell-extension.schema.json).
    var provenance: String? {
        guard let p = d["derivedFrom"] as? [String: Any], let repo = p["repo"] as? String, let rev = p["rev"] as? String, !repo.isEmpty, !rev.isEmpty else { return nil }
        return "Ported from \(repo) at \(rev.prefix(7)) (\(p["license"] as? String ?? ""))"
    }
}

func configDir() -> String {
    if let c = ProcessInfo.processInfo.environment["RISKELL_CONFIG"] { return (c as NSString).deletingLastPathComponent }
    return homePath() + "/.config/riskell"
}
func cacheDir() -> String { ProcessInfo.processInfo.environment["RISKELL_CACHE_DIR"] ?? homePath() + "/.cache/riskell" }

/// The registry's listings: fetched (and cached for offline use), or read from a file or folder.
func registry() -> [Listing] {
    let src = ProcessInfo.processInfo.environment["RISKELL_REGISTRY"] ?? defaultRegistry
    var text: String?
    if src.contains("://") && !src.hasPrefix("file://") {
        guard src.hasPrefix("https://") else {
            failBlock("the registry must be an https address (or a file or folder)", detail: src,
                      tries: [(cmd: "RISKELL_REGISTRY=<path>", note: "point it at a local index.json")])
        }
        let (c, out) = sh(["curl", "-fsSL", "--proto", "=https", "--proto-redir", "=https", "--max-time", "15", "--max-filesize", "5000000", src])
        let cache = cacheDir() + "/registry-index.json"
        if c == 0, !out.isEmpty { text = out; write(out, cache) }
        else if let cached = read(cache) { text = cached; FileHandle.standardError.write(Data("risk ext: the registry could not be reached; using the copy from the last time\n".utf8)) }
        else {
            failBlock("the registry could not be reached", detail: src,
                      tries: [(cmd: "RISKELL_REGISTRY=<path>", note: "use a local copy"), (cmd: "risk ext search <words>", note: "try again online")])
        }
    } else {
        var p = src.hasPrefix("file://") ? String(src.dropFirst(7)) : src
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { p += "/index.json" }
        text = read(p)
        if text == nil { failBlock("cannot read the registry", detail: p, tries: [(cmd: "RISKELL_REGISTRY=<path>", note: "point it at index.json")]) }
    }
    guard let t = text, let j = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any], let l = j["listings"] as? [[String: Any]]
    else {
        failBlock("the registry's index.json is not valid", tries: [(cmd: "RISKELL_REGISTRY=<path>", note: "use a local copy")])
    }
    return l.map { Listing(d: $0) }.filter { l in !l.id.isEmpty }
}

func installedIDs() -> Set<String> {
    Set(loadLock(root()).map(\.id)).union(loadInstalled().map { $0["id"] as? String ?? "" })
}

/// `list`'s columns, in the table's own order: the name, the kind, the version and what it does. When a narrow terminal must lose a
/// column it loses the version first: the summary is what tells two extensions apart.
let listingColumns = [Column(priority: 4), Column(priority: 3), Column(priority: 1), Column(priority: 2)]

/// `search`'s columns: the same four, then the installed marker, which a narrow terminal drops before anything else.
let searchColumns = [Column(priority: 5), Column(priority: 4), Column(priority: 2), Column(priority: 3), Column(priority: 1)]

/// One listing as table cells: the name bold, the kind in the information colour, the version dim, the summary softer than the name.
func listingCells(_ t: Tty, name: String, kind: String, version: String, summary: String) -> [Cell] {
    [Cell(name, .left, Style(fg: t.palette.color(.text1, t.mode), bold: true)),
     Cell(kind, .left, Style(fg: t.palette.color(.info, t.mode))),
     Cell(version, .left, Style(fg: t.palette.color(.text4, t.mode))),
     Cell(summary, .left, Style(fg: t.palette.color(.text3, t.mode)))]
}

/// One installed extension as `list` shows it: what it is, and whether it is on.
struct InstalledRow {
    let id: String
    let kind: String
    let version: String
    let summary: String
    let enabled: Bool
}

/// Whether the config uses a file extension: a pill when a bar's layout names `pill:<id>`, a theme when it is the scheme in force.
/// A compiled extension is on by being in the lock, because it is built into riskell (the caller sets that).
func fileExtensionInUse(_ id: String, kind: String) -> Bool {
    let env = ProcessInfo.processInfo.environment
    func absolute(_ path: String) -> String { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardized.path }
    let config = absolute(env["RISKELL_CONFIG"] ?? homePath() + "/.config/riskell/config.json")
    let layout = env["RISKELL_LAYOUT"].map(absolute)
        ?? URL(fileURLWithPath: config).deletingLastPathComponent().appendingPathComponent("layout.json").path
    if kind == "pill" { return [config, layout].contains { read($0)?.contains("\"pill:\(id)\"") == true } }
    guard let text = read(config), let j = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return false }
    return j["theme"] as? String == id
}

/// What `risk ext list` prints: the compiled extensions from the lock, then the pill and theme files from the config folder.
func installedRows(_ r: String) -> [InstalledRow] {
    var out: [InstalledRow] = []
    for e in loadLock(r) {
        // A lock written before the manifest's name, kind and summary were recorded still has its folder here, so read it there.
        let manifest = e.path.map { $0.hasPrefix("/") ? $0 : r + "/" + $0 }
            .flatMap { read($0 + "/riskell.json") }
            .flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        out.append(InstalledRow(id: e.id,
                                kind: e.kind ?? manifest?["kind"] as? String ?? "package",
                                version: e.version ?? manifest?["version"] as? String ?? "?",
                                summary: e.summary ?? manifest?["summary"] as? String ?? "",
                                enabled: true))
    }
    for e in loadInstalled() {
        let id = e["id"] as? String ?? "", kind = e["kind"] as? String ?? ""
        let summary = e["summary"] as? String ?? (e["files"] as? [String] ?? []).joined(separator: ", ")
        out.append(InstalledRow(id: id, kind: kind, version: e["version"] as? String ?? "?", summary: summary,
                                enabled: fileExtensionInUse(id, kind: kind)))
    }
    return out
}

/// Cut a cell to `room` characters with an ellipsis: a free-text column then stays a column instead of being dropped whole by the table
/// when one long summary would not fit (the table drops columns, it does not shrink them).
func fit(_ text: String, _ room: Int) -> String {
    if room <= 1 { return "\u{2026}" }
    return text.count <= room ? text : String(text.prefix(room - 1)) + "\u{2026}"
}

/// `risk ext list`: one row per extension, the dot saying whether it is on.
func list() {
    let rows = installedRows(root())
    let t = screen()
    guard !rows.isEmpty else {
        printAll(t.empty("no extensions installed", hint: (cmd: "risk ext add <name>", text: "to install one")))
        return
    }
    var lines = t.tableHead(title: "extensions", meta: "\(rows.count) installed")
    lines += t.entries(rows.map { (tone: $0.enabled ? .ok : .note, name: $0.id, tag: $0.kind, version: $0.version, mark: nil, text: $0.summary) })
    lines.append("")
    lines.append(t.footerHint([(cmd: "risk ext add <name>", text: "to install one"), (cmd: "risk ext search", text: "what the registry lists")]))
    printAll(lines)
}

func search(_ words: [String]) {
    let q = words.map { $0.lowercased() }, inst = installedIDs()
    let hits = registry().filter { l in
        let hay = ([l.id, l.name, l.summary, l.kind] + l.keywords + l.atoms).joined(separator: " ").lowercased()
        return q.allSatisfy { hay.contains($0) }
    }
    let t = screen()
    if hits.isEmpty {
        printAll(t.empty("nothing matches \"\(words.joined(separator: " "))\"", hint: (cmd: "risk ext search <words>", text: "try a shorter word")))
        return
    }
    var lines = t.tableHead(title: "registry", meta: "\(hits.count) listed")
    lines += t.entries(hits.map { (tone: .ok, name: $0.id, tag: $0.kind, version: $0.version, mark: inst.contains($0.id) ? "installed" : nil, text: $0.summary) })
    lines.append("")
    lines.append(t.footerHint([(cmd: "risk ext info <name>", text: "one in full"), (cmd: "risk ext add <name>", text: "to install one")]))
    printAll(lines)
}

/// One setting as a line: its key, its label, and what may be chosen, in the words the manifest used.
func settingLine(_ s: [String: Any]) -> String {
    let key = s["key"] as? String ?? "?", label = s["label"] as? String ?? ""
    func number(_ k: String) -> String? { (s[k] as? NSNumber).map { "\($0)" } }
    let what: String
    switch s["type"] as? String {
    case "number":
        what = "number \(number("min") ?? "?") to \(number("max") ?? "?"), step \(number("step") ?? "?"), default \(number("default") ?? "?")"
    case "bool":
        what = "\(s["default"] as? Bool == true ? "on" : "off") by default"
    case "choice":
        what = "one of \((s["options"] as? [String] ?? []).joined(separator: ", ")), default \(s["default"] as? String ?? "?")"
    default:
        what = s["type"] as? String ?? "?"
    }
    return key + " · " + label + " · " + what
}

func info(_ name: String) {
    guard let l = registry().first(where: { $0.id == name }) else {
        failBlock("\"\(name)\" is not in the registry", tries: [(cmd: "risk ext search <words>", note: "look at what is listed")])
    }
    var fields: [(String, [String])] = [
        ("repo", [l.repo + (l.path.map { "/" + $0 } ?? "")]),
        ("license", [l.d["license"] as? String ?? "?"]),
        ("kind", [l.kind]),
        ("version", [l.version]),
        ("pinned to", [l.rev]),
    ]
    if let kit = l.d["kit"] as? String { fields.append(("kit", [kit])) }
    if !l.atoms.isEmpty { fields.append(("atoms", [l.atoms.map { "ext:" + $0 }.joined(separator: " ")])) }
    if let a = l.d["authors"] as? [String], !a.isEmpty { fields.append(("authors", [a.joined(separator: ", ")])) }
    if let p = l.provenance { fields.append(("derived from", [p])) }
    if let settings = l.d["settings"] as? [[String: Any]], !settings.isEmpty { fields.append(("settings", settings.map(settingLine))) }
    // The one line to copy, in the accent, unless the extension already ships with riskell.
    fields.append(l.bundled ? ("bundled", ["ships with riskell, nothing to install"]) : ("example", ["risk ext add \(l.id)"]))
    printAll(screen().detail(usage: "\(l.name) (\(l.id))  \(l.kind)  v\(l.version)", summary: l.summary,
                             fields: fields, children: []))
}

// MARK: files extensions (pills and themes): dropped into the config folder, applied live, recorded in extensions.json

func installedFile() -> String { configDir() + "/extensions.json" }
func loadInstalled() -> [[String: Any]] {
    (read(installedFile()).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [[String: Any]] ?? []
}
func saveInstalled(_ l: [[String: Any]]) {
    let d = (try? JSONSerialization.data(withJSONObject: l, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
    write(String(decoding: d, as: UTF8.self) + "\n", installedFile())
}

/// Where a pill or theme file goes: pills/<id>.json, themes/<id>.yaml (several files: <id>-<name>).
func destination(kind: String, id: String, file: String, only: Bool) -> String {
    let ext = (file as NSString).pathExtension
    let base = only ? id : id + "-" + (file as NSString).deletingPathExtension
    return (kind == "pill" ? "pills/" : "themes/") + base + "." + ext
}

func installFiles(_ l: Listing, yes: Bool = false, announce: Bool = true) {
    requireValid(l)
    let tmp = NSTemporaryDirectory() + "risk-ext-" + UUID().uuidString
    guard git(["clone", "--quiet", "--", l.repo, tmp]).0 == 0 else {
        failBlock("could not clone \(l.repo)", tries: [(cmd: "risk ext add \(l.id)", note: "try again")])
    }
    guard git(["checkout", "--quiet", l.rev], in: tmp).0 == 0 else {
        failBlock("commit \(l.rev.prefix(10)) is not in \(l.repo)", detail: "the registry pins a commit the repository no longer has",
                  tries: [(cmd: "risk ext search \(l.id)", note: "see what it pins now")])
    }
    guard validate(tmp, announce: false), let j = (read(tmp + "/riskell.json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any],
          let files = j["files"] as? [String], j["id"] as? String == l.id, j["kind"] as? String == l.kind
    else { fail("risk ext: not installed: fix the findings above (the listing and riskell.json must agree on the id and the kind)") }
    let exts = l.kind == "pill" ? ["json"] : ["yaml", "yml"]
    var sources: [(String, String)] = []
    for f in files {
        guard let p = safeFile(f, in: tmp, extensions: exts) else { fail("risk ext: not installed: \"\(f)\" is not a plain small \(exts.joined(separator: "/")) file inside the repository") }
        sources.append((f, p))
    }
    if l.kind == "pill" {      // a pill runs commands on your Mac: show them
        consent("Install the pill \"\(l.name)\" (\(l.id))?", ["source: \(l.repo) at \(l.rev)", "It will run these commands on your Mac, as you, whenever it refreshes:"] + pillCommands(sources.map(\.1)).map { "  " + $0 }, yes: yes)
    }
    var done: [String] = []
    for (f, src) in sources {
        let rel = destination(kind: l.kind, id: l.id, file: f, only: files.count == 1)
        let dest = configDir() + "/" + rel
        try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: dest)
        guard (try? fm.copyItem(atPath: src, toPath: dest)) != nil else { fail("risk ext: could not write \(dest)") }
        done.append(rel)
    }
    var inst = loadInstalled().filter { $0["id"] as? String != l.id }
    inst.append(["id": l.id, "kind": l.kind, "name": l.name, "version": l.version, "summary": l.summary,
                 "repo": l.repo, "rev": l.rev, "files": done])
    saveInstalled(inst)
    guard announce else { return }
    let t = screen()
    printAll(t.checks([(.ok, l.id, "installed · \(l.kind) · \(done.joined(separator: ", ")) · applies at once, nothing to rebuild", nil)]))
}

func removeFiles(_ id: String) -> Bool {
    let inst = loadInstalled()
    guard let rec = inst.first(where: { $0["id"] as? String == id }) else { return false }
    for f in rec["files"] as? [String] ?? [] { try? fm.removeItem(atPath: configDir() + "/" + f) }
    saveInstalled(inst.filter { $0["id"] as? String != id })
    let t = screen()
    printAll(t.checks([(.ok, id, "removed · its files are gone from \(shortPath(configDir()))", nil)]))
    return true
}

// MARK: add by name

/// `risk ext add <name>`: the name is looked up in the registry and installed at the commit the listing pins.
func addByName(_ name: String, yes: Bool = false) {
    guard let l = registry().first(where: { $0.id == name }) else {
        failBlock("\"\(name)\" is not in the registry", tries: [(cmd: "risk ext search <words>", note: "look at what is listed")])
    }
    requireValid(l)
    if l.bundled {
        let r = root()
        if loadLock(r).contains(where: { $0.id == l.id }) {
            printAll(screen().checks([(.note, l.id, "ships with riskell and is installed already", nil)]))
            return
        }
        guard let p = l.path, fm.fileExists(atPath: r + "/" + p) else {
            failBlock("\(l.id) ships with riskell but its folder is not in this checkout", tries: [(cmd: "git pull", note: "get the folder from the checkout")])
        }
        add(r + "/" + p, rev: nil, version: l.version, expectID: l.id)
        exit(needsRebuild)
    }
    switch l.kind {
    case "pill", "theme": installFiles(l, yes: yes)
    case "atom", "reading", "behaviour":
        add(l.repo, rev: l.rev, version: l.version, expectID: l.id, yes: yes)
        exit(needsRebuild)
    default: fail("risk ext: kind \"\(l.kind)\" cannot be installed yet")
    }
}

// MARK: update

/// `risk ext update [name] [--yes]`: what the registry pins now against what is installed. Shows the change between the two commits first;
/// nothing is applied without --yes.
func update(_ args: [String]) {
    let yes = args.contains("--yes"), only = args.first(where: { !$0.hasPrefix("--") })
    let reg = registry(), r = root()
    struct Item { let l: Listing; let from: String; let compiled: Bool }
    var items: [Item] = []
    for e in loadLock(r) where e.url != nil {
        if let l = reg.first(where: { $0.id == e.id }), !l.bundled, l.rev != e.revision, only == nil || only == l.id { items.append(Item(l: l, from: e.revision ?? "", compiled: true)) }
    }
    for e in loadInstalled() {
        if let id = e["id"] as? String, let l = reg.first(where: { $0.id == id }), l.rev != e["rev"] as? String, only == nil || only == id { items.append(Item(l: l, from: e["rev"] as? String ?? "", compiled: false)) }
    }
    let t = screen()
    if items.isEmpty {
        let value = only == nil ? "everything installed from the registry is up to date" : "is up to date (or not installed from the registry)"
        printAll(t.checks([(.ok, only ?? "extensions", value, nil)]))
        return
    }
    var rebuild = false
    if yes {
        for it in items {
            requireValid(it.l)
            printAll(t.checks([(.ok, it.l.id, "updated · \(it.from.prefix(8)) -> \(it.l.rev.prefix(8)) · v\(it.l.version)", nil)]))
            if it.compiled {
                add(it.l.repo, rev: it.l.rev, version: it.l.version, expectID: it.l.id, yes: true, next: false, announce: false)
                rebuild = true
            } else { installFiles(it.l, yes: true, announce: false) }
        }
        if rebuild {
            print(t.next(cmd: "risk dev", why: "a compiled extension changed the build"))
            exit(needsRebuild)
        }
        return
    }
    // The dry run: the plan first, then the file changes behind each row, so a reader sees what would happen before the detail.
    let rows = items.map { (verb: "update", text: "\($0.l.id) \($0.from.prefix(8)) -> \($0.l.rev.prefix(8)) · v\($0.l.version)") }
    var detail: [String] = []
    for it in items {
        let tmp = NSTemporaryDirectory() + "risk-ext-" + UUID().uuidString
        requireValid(it.l)
        guard git(["clone", "--quiet", "--", it.l.repo, tmp]).0 == 0 else { continue }
        guard !it.from.isEmpty, matches(it.from, "^[0-9a-f]{7,40}$") else { continue }
        let stat = git(["diff", "--stat", it.from, it.l.rev], in: tmp).1
        guard !stat.isEmpty else { continue }
        detail += stat.split(separator: "\n").map { "  " + t.dim("\(it.l.id): \($0)") }
    }
    var lines = t.plan(rows, note: "dry run, nothing written; add --yes to apply the updates")
    if !detail.isEmpty {
        lines.append("")
        lines += detail
    }
    printAll(lines)
}

// MARK: publish

/// `risk ext publish [dir]`: checks an extension's repository is ready to be listed and prints its listing (what goes in the registry's
/// listings/<id>.json). The listing pins the commit you have checked out, so push it (and tag it v<version>) first.
func publish(_ dirArg: String?) {
    let dir = URL(fileURLWithPath: dirArg ?? fm.currentDirectoryPath, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardized.path
    guard validate(dir, announce: false), let j = (read(dir + "/riskell.json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any],
          let id = j["id"] as? String, let kind = j["kind"] as? String, let name = j["name"] as? String, let summary = j["summary"] as? String,
          let version = j["version"] as? String, let license = j["license"] as? String
    else {
        failBlock("not ready: fix the findings above", tries: [(cmd: "risk ext validate \(dir)", note: "see every problem")])
    }
    var problems: [String] = []
    guard sh(["git", "rev-parse", "--git-dir"], in: dir).0 == 0 else {
        failBlock("\(shortPath(dir)) is not a git repository", tries: [(cmd: "git init", note: "the listing pins a commit, so it needs one")])
    }
    let remote = sh(["git", "remote", "get-url", "origin"], in: dir).1
    let ssh = ["git", "github.com:"].joined(separator: "@")      // an ssh remote, written as https
    let https = remote.hasPrefix(ssh) ? "https://github.com/" + remote.dropFirst(ssh.count).replacingOccurrences(of: ".git", with: "") : remote.replacingOccurrences(of: ".git", with: "")
    if !https.hasPrefix("https://") { problems.append("the origin remote is not an https or github.com address (\(remote.isEmpty ? "none" : remote))") }
    if !sh(["git", "status", "--porcelain"], in: dir).1.isEmpty { problems.append("there are uncommitted changes: the listing pins a commit, not your working folder") }
    let rev = sh(["git", "rev-parse", "HEAD"], in: dir).1
    if sh(["git", "branch", "-r", "--contains", rev], in: dir).1.isEmpty { problems.append("HEAD is not pushed (`git push`)") }
    if !sh(["git", "tag", "--points-at", rev], in: dir).1.split(separator: "\n").contains(Substring("v" + version)) { problems.append("HEAD has no tag v\(version) (`git tag v\(version) && git push --tags`)") }
    if !fm.fileExists(atPath: dir + "/LICENSE") { problems.append("no LICENSE file") }
    var listing: [String: Any] = ["id": id, "kind": kind, "name": name, "summary": summary, "repo": https, "rev": rev, "version": version, "license": license]
    for k in ["kit", "atoms", "keywords", "authors", "homepage", "preview", "derivedFrom"] { if let v = j[k] { listing[k] = v } }
    if j["preview"] == nil { problems.append("no \"preview\" in riskell.json: a picture of the widget is what the storefront shows (a PNG, at least 600 px wide, up to 500 KB)") }
    let d = (try? JSONSerialization.data(withJSONObject: listing, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    print(String(decoding: d, as: UTF8.self))      // stdout is the listing itself, so it can be saved with a redirect
    // What to do with it goes to stderr, drawn by the kit: stdout must stay the JSON.
    let t = screen()
    let note: [String] = problems.isEmpty
        ? t.checks([(.ok, id, "ready · save this as listings/\(id).json in https://github.com/rish139/riskell-registry and open a pull request", nil)])
        : t.checks([(.crit, id, "not ready", nil)] + problems.enumerated().map { (.crit, "problem \($0.offset + 1)", $0.element, nil) })
    FileHandle.standardError.write(Data(("\n" + note.joined(separator: "\n") + "\n").utf8))
    exit(problems.isEmpty ? 0 : 1)
}
