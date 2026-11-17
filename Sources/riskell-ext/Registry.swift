// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation

// The storefront side of `risk ext` (docs/STOREFRONT.md): search, info, add by name, update. The registry is one JSON file (index.json, built by
// the riskell-registry repository's CI). RISKELL_REGISTRY points at another one: a URL, a file, or a folder holding index.json (tests, a mirror).
// Foundation only, like the rest of the tool.

let defaultRegistry = "https://rish139.github.io/riskell-registry/index.json"

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
}

func configDir() -> String {
    if let c = ProcessInfo.processInfo.environment["RISKELL_CONFIG"] { return (c as NSString).deletingLastPathComponent }
    return NSHomeDirectory() + "/.config/riskell"
}
func cacheDir() -> String { ProcessInfo.processInfo.environment["RISKELL_CACHE_DIR"] ?? NSHomeDirectory() + "/.cache/riskell" }

/// The registry's listings: fetched (and cached for offline use), or read from a file or folder.
func registry() -> [Listing] {
    let src = ProcessInfo.processInfo.environment["RISKELL_REGISTRY"] ?? defaultRegistry
    var text: String?
    if src.hasPrefix("http://") || src.hasPrefix("https://") {
        let (c, out) = sh(["curl", "-fsSL", "--max-time", "15", src])
        let cache = cacheDir() + "/registry-index.json"
        if c == 0, !out.isEmpty { text = out; write(out, cache) }
        else if let cached = read(cache) { text = cached; FileHandle.standardError.write(Data("risk ext: the registry could not be reached; using the copy from the last time\n".utf8)) }
        else { fail("risk ext: the registry could not be reached (\(src)). Set RISKELL_REGISTRY to a local copy, or try again online.") }
    } else {
        var p = src.hasPrefix("file://") ? String(src.dropFirst(7)) : src
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { p += "/index.json" }
        text = read(p)
        if text == nil { fail("risk ext: cannot read the registry at \(p)") }
    }
    guard let t = text, let j = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any], let l = j["listings"] as? [[String: Any]]
    else { fail("risk ext: the registry's index.json is not valid") }
    return l.map { Listing(d: $0) }
}

func installedIDs() -> Set<String> {
    Set(loadLock(root()).map(\.id)).union(loadInstalled().map { $0["id"] as? String ?? "" })
}

func printListing(_ l: Listing, _ installed: Set<String>) {
    let tag = installed.contains(l.id) ? "  [installed]" : (l.bundled ? "  [ships with riskell]" : "")
    print("\(l.id)  \(l.kind)  v\(l.version)  \(l.summary)\(tag)")
}

func search(_ words: [String]) {
    let q = words.map { $0.lowercased() }, inst = installedIDs()
    let hits = registry().filter { l in
        let hay = ([l.id, l.name, l.summary, l.kind] + l.keywords + l.atoms).joined(separator: " ").lowercased()
        return q.allSatisfy { hay.contains($0) }
    }
    if hits.isEmpty { print("nothing matches \"\(words.joined(separator: " "))\""); return }
    hits.forEach { printListing($0, inst) }
}

func info(_ name: String) {
    guard let l = registry().first(where: { $0.id == name }) else { fail("risk ext: \"\(name)\" is not in the registry (`risk ext search <words>`)") }
    print("\(l.name) (\(l.id))  \(l.kind)  v\(l.version)\n\(l.summary)")
    print("repository  \(l.repo)\(l.path.map { "/" + $0 } ?? "")\npinned to   \(l.rev)")
    for k in ["license", "kit"] { if let v = l.d[k] as? String { print("\(k.padding(toLength: 11, withPad: " ", startingAt: 0))\(v)") } }
    if !l.atoms.isEmpty { print("atoms       \(l.atoms.map { "ext:" + $0 }.joined(separator: " "))") }
    if let a = l.d["authors"] as? [String] { print("authors     \(a.joined(separator: ", "))") }
    print(l.bundled ? "ships with riskell" : "install: risk ext add \(l.id)")
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

func installFiles(_ l: Listing) {
    let tmp = NSTemporaryDirectory() + "risk-ext-" + UUID().uuidString
    guard sh(["git", "clone", "--quiet", l.repo, tmp]).0 == 0 else { fail("risk ext: could not clone \(l.repo)") }
    guard sh(["git", "checkout", "--quiet", l.rev], in: tmp).0 == 0 else { fail("risk ext: commit \(l.rev.prefix(10)) is not in \(l.repo)") }
    guard validate(tmp), let j = (read(tmp + "/riskell.json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any],
          let files = j["files"] as? [String], j["id"] as? String == l.id
    else { fail("risk ext: not installed: fix the findings above (the listing and riskell.json must agree on the id)") }
    var done: [String] = []
    for f in files {
        let rel = destination(kind: l.kind, id: l.id, file: f, only: files.count == 1)
        let dest = configDir() + "/" + rel
        try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: dest)
        guard (try? fm.copyItem(atPath: tmp + "/" + f, toPath: dest)) != nil else { fail("risk ext: could not write \(dest)") }
        done.append(rel)
    }
    var inst = loadInstalled().filter { $0["id"] as? String != l.id }
    inst.append(["id": l.id, "kind": l.kind, "name": l.name, "version": l.version, "repo": l.repo, "rev": l.rev, "files": done])
    saveInstalled(inst)
    print("installed \(l.id) (\(l.kind)): \(done.joined(separator: ", ")) in \(configDir()). It applies at once; nothing to rebuild.")
}

func removeFiles(_ id: String) -> Bool {
    let inst = loadInstalled()
    guard let rec = inst.first(where: { $0["id"] as? String == id }) else { return false }
    for f in rec["files"] as? [String] ?? [] { try? fm.removeItem(atPath: configDir() + "/" + f) }
    saveInstalled(inst.filter { $0["id"] as? String != id })
    print("removed \(id); its files are gone from \(configDir()).")
    return true
}

// MARK: add by name

/// `risk ext add <name>`: the name is looked up in the registry and installed at the commit the listing pins.
func addByName(_ name: String) {
    guard let l = registry().first(where: { $0.id == name }) else { fail("risk ext: \"\(name)\" is not in the registry (`risk ext search <words>`)") }
    if l.bundled {
        let r = root()
        if loadLock(r).contains(where: { $0.id == l.id }) { print("\(l.id) ships with riskell and is installed already."); return }
        guard let p = l.path, fm.fileExists(atPath: r + "/" + p) else { fail("risk ext: \(l.id) ships with riskell but its folder is not in this checkout") }
        add(r + "/" + p, rev: nil, version: l.version, expectID: l.id)
        exit(needsRebuild)
    }
    switch l.kind {
    case "pill", "theme": installFiles(l)
    case "atom", "reading":
        add(l.repo, rev: l.rev, version: l.version, expectID: l.id)
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
    if items.isEmpty { print(only.map { "\($0) is up to date (or not installed from the registry)" } ?? "everything installed from the registry is up to date"); return }
    var rebuild = false
    for it in items {
        print("\(it.l.id): \(it.from.prefix(8)) -> \(it.l.rev.prefix(8))  (v\(it.l.version))")
        let tmp = NSTemporaryDirectory() + "risk-ext-" + UUID().uuidString
        if sh(["git", "clone", "--quiet", it.l.repo, tmp]).0 == 0, !it.from.isEmpty {
            let stat = sh(["git", "diff", "--stat", it.from, it.l.rev], in: tmp).1
            print(stat.isEmpty ? "  (no file changes shown)" : stat.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        }
        guard yes else { continue }
        if it.compiled { add(it.l.repo, rev: it.l.rev, version: it.l.version, expectID: it.l.id); rebuild = true } else { installFiles(it.l) }
    }
    if !yes { print("nothing was changed. `risk ext update --yes` (or `risk ext update <name> --yes`) applies the update.") }
    if rebuild { exit(needsRebuild) }
}

// MARK: publish

/// `risk ext publish [dir]`: checks an extension's repository is ready to be listed and prints its listing (what goes in the registry's
/// listings/<id>.json). The listing pins the commit you have checked out, so push it (and tag it v<version>) first.
func publish(_ dirArg: String?) {
    let dir = URL(fileURLWithPath: dirArg ?? fm.currentDirectoryPath, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardized.path
    guard validate(dir), let j = (read(dir + "/riskell.json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any],
          let id = j["id"] as? String, let kind = j["kind"] as? String, let name = j["name"] as? String, let summary = j["summary"] as? String,
          let version = j["version"] as? String, let license = j["license"] as? String
    else { fail("risk ext: not ready: fix the findings above") }
    var problems: [String] = []
    guard sh(["git", "rev-parse", "--git-dir"], in: dir).0 == 0 else { fail("risk ext: \(dir) is not a git repository") }
    let remote = sh(["git", "remote", "get-url", "origin"], in: dir).1
    let https = remote.hasPrefix("git@github.com:") ? "https://github.com/" + remote.dropFirst("git@github.com:".count).replacingOccurrences(of: ".git", with: "") : remote.replacingOccurrences(of: ".git", with: "")
    if !https.hasPrefix("https://") { problems.append("the origin remote is not an https or github.com address (\(remote.isEmpty ? "none" : remote))") }
    if !sh(["git", "status", "--porcelain"], in: dir).1.isEmpty { problems.append("there are uncommitted changes: the listing pins a commit, not your working folder") }
    let rev = sh(["git", "rev-parse", "HEAD"], in: dir).1
    if sh(["git", "branch", "-r", "--contains", rev], in: dir).1.isEmpty { problems.append("HEAD is not pushed (`git push`)") }
    if !sh(["git", "tag", "--points-at", rev], in: dir).1.split(separator: "\n").contains(Substring("v" + version)) { problems.append("HEAD has no tag v\(version) (`git tag v\(version) && git push --tags`)") }
    if !fm.fileExists(atPath: dir + "/LICENSE") { problems.append("no LICENSE file") }
    var listing: [String: Any] = ["id": id, "kind": kind, "name": name, "summary": summary, "repo": https, "rev": rev, "version": version, "license": license]
    for k in ["kit", "atoms", "keywords", "authors", "homepage"] { if let v = j[k] { listing[k] = v } }
    let d = (try? JSONSerialization.data(withJSONObject: listing, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    print(String(decoding: d, as: UTF8.self))
    FileHandle.standardError.write(Data((problems.isEmpty ? "\nready. Save this as listings/\(id).json in https://github.com/rish139/riskell-registry and open a pull request.\n"
        : "\nnot ready:\n" + problems.map { "  - " + $0 }.joined(separator: "\n") + "\n").utf8))
    exit(problems.isEmpty ? 0 : 1)
}
