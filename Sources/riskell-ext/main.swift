// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation

// risk ext (this tool, built as riskell-ext): validate, scaffold and install riskell extensions (docs/EXTENSION-KIT.md). Foundation only.
//   risk ext validate <dir>            check riskell.json and, for compiled kinds, the source against the kit's rules
//   risk ext new <kind> <name>         scaffold: reading | atom | pill | theme
//   risk ext add <dir|git-url> [rev]   record a package in extensions.lock.json and regenerate the import list
//   risk ext remove <id>               take it out again
//   risk ext list                      what is installed
//   risk ext sync                      regenerate Sources/riskell/Generated/InstalledPackages.swift from the lock
// Exit status: 0 ok, 1 findings or a failed command, 2 usage.

let fm = FileManager.default
let compiled: Set<String> = ["reading", "atom", "behaviour"]
let kinds = ["pill", "theme", "preset", "reading", "atom", "behaviour"]

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
func usage() -> Never {
    print("usage: risk ext validate <dir> | new <reading|atom|pill|theme> <name> | add <dir|git-url> [rev] | remove <id> | list | sync")
    exit(2)
}
func read(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }
func write(_ s: String, _ p: String) { try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true); try? s.write(toFile: p, atomically: true, encoding: .utf8) }
func matches(_ s: String, _ re: String) -> Bool { s.range(of: re, options: .regularExpression) != nil }

/// The riskell checkout this tool is run from: the nearest parent holding extensions.lock.json.
func root() -> String {
    if let e = ProcessInfo.processInfo.environment["RISKELL_ROOT"], fm.fileExists(atPath: e + "/extensions.lock.json") { return e }      // set by scripts/risk
    var d = fm.currentDirectoryPath
    while d != "/" { if fm.fileExists(atPath: d + "/extensions.lock.json") { return d }; d = (d as NSString).deletingLastPathComponent }
    fail("risk ext: run it inside the riskell checkout (no extensions.lock.json found above here)")
}

// MARK: manifest

struct Finding { var rule: String; var file: String; var line: Int?; var message: String; var fix: String }
var findings: [Finding] = []
func report(_ rule: String, _ file: String, _ line: Int? = nil, _ message: String, fix: String) { findings.append(Finding(rule: rule, file: file, line: line, message: message, fix: fix)) }

/// SPDX identifiers that are common in open source; anything else is a warning to check the spelling against spdx.org/licenses.
let spdx: Set<String> = ["MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "MPL-2.0", "GPL-2.0-only", "GPL-3.0-only", "GPL-3.0-or-later",
                         "LGPL-3.0-only", "AGPL-3.0-only", "Unlicense", "CC0-1.0", "0BSD", "Zlib", "BUSL-1.1",
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
        if let kit = str("kit"), !matches(kit, #"^\^?\d+\.\d+(\.\d+)?$"#) { report("manifest.kit", "riskell.json", nil, "kit \"\(kit)\" must be a SemVer range such as ^1.0", fix: "write ^MAJOR.MINOR") }
        if !fm.fileExists(atPath: dir + "/Package.swift") { report("package.missing", "Package.swift", nil, "a compiled extension is a Swift package", fix: "add a Package.swift with a library product named after \"module\"") }
    }
    if let k = str("kind"), ["pill", "theme", "preset"].contains(k) {
        let files = j["files"] as? [String] ?? []
        if files.isEmpty { report("manifest.required", "riskell.json", nil, "\"files\" is required for kind \(k)", fix: "list the files to install, e.g. [\"pill.json\"]") }
        for f in files where !fm.fileExists(atPath: dir + "/" + f) { report("manifest.files", "riskell.json", nil, "\"\(f)\" is listed but not in the repo", fix: "add the file or remove it from \"files\"") }
    }
    if let a = j["atoms"] as? [String] {
        var seen = Set<String>()
        for id in a where !matches(id, "^[A-Za-z0-9_-]+$") || !seen.insert(id).inserted { report("manifest.atoms", "riskell.json", nil, "atom id \"\(id)\" is not plain or is repeated", fix: "letters, digits, - and _, each once") }
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

struct Locked: Codable { var id: String; var module: String; var entry: String; var product: String; var package: String; var path: String?; var url: String?; var revision: String? }
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
    // the same list as a literal inside Package.swift (see the comment there)
    func lit(_ v: String?) -> String { v.map { "\"" + $0 + "\"" } ?? "nil" }
    let rows = l.map { "    Locked(module: \(lit($0.module)), product: \(lit($0.product)), package: \(lit($0.package)), path: \(lit($0.path)), url: \(lit($0.url)), revision: \(lit($0.revision)))" }
    let block = "// BEGIN generated\nlet locked: [Locked] = [" + (rows.isEmpty ? "]" : "\n" + rows.joined(separator: ",\n") + "\n]") + "\n// END generated"
    if var pk = read(r + "/Package.swift"), let b = pk.range(of: "// BEGIN generated"), let e = pk.range(of: "// END generated") {
        pk.replaceSubrange(b.lowerBound..<e.upperBound, with: block)
        write(pk, r + "/Package.swift")
    }
}

func sh(_ args: [String], in dir: String? = nil) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
    if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (127, "") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func add(_ source: String, rev: String?) {
    let r = root()
    var dir = source, url: String?, revision = rev
    if source.contains("://") || source.hasPrefix("git@") {      // a git URL (https, ssh, file); anything else is a folder
        dir = NSTemporaryDirectory() + "risk-ext-" + UUID().uuidString
        let (c, _) = sh(["git", "clone", "--quiet", source, dir])
        guard c == 0 else { fail("risk ext: could not clone \(source)") }
        if let rev { _ = sh(["git", "checkout", "--quiet", rev], in: dir) }
        revision = sh(["git", "rev-parse", "HEAD"], in: dir).1
        url = source
    } else { dir = URL(fileURLWithPath: source, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardized.path }
    guard validate(dir), let j = (read(dir + "/riskell.json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any],
          let id = j["id"] as? String, let module = j["module"] as? String, let entry = j["entry"] as? String
    else { fail("risk ext: not added: fix the findings above") }
    var l = loadLock(r).filter { $0.id != id }
    let pkg = ((url ?? dir) as NSString).lastPathComponent.replacingOccurrences(of: ".git", with: "")
    // a path is stored relative to the checkout when it is inside it, so the lock can be committed
    let rel = url == nil ? (dir.hasPrefix(r + "/") ? String(dir.dropFirst(r.count + 1)) : dir) : nil
    l.append(Locked(id: id, module: module, entry: entry, product: module, package: pkg, path: rel, url: url, revision: revision))
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
            dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "1.0.0")],
            targets: [.target(name: "\(module)", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")])]
        )

        """
    }
    let compiledExtra = ",\n  \"kit\": \"^1.0\",\n  \"module\": \"\(module)\",\n  \"entry\": \"\(type)Package\",\n  \"atoms\": [\"\(name)\"]"
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
case "validate": exit(a.count > 1 && validate(a[1]) ? 0 : 1)
case "new": if a.count == 3 { scaffold(a[1], a[2]) } else { usage() }
case "add": if a.count >= 2 { add(a[1], rev: a.count > 2 ? a[2] : nil) } else { usage() }
case "remove":
    guard a.count == 2 else { usage() }
    let r = root(); let before = loadLock(r)
    saveLock(before.filter { $0.id != a[1] }, r); sync(r)
    print(before.contains { $0.id == a[1] } ? "removed \(a[1]); `risk dev` rebuilds and restarts riskell (`risk ext remove` does that for you)" : "\(a[1]) is not installed")
case "list":
    let l = loadLock(root())
    print(l.isEmpty ? "no extensions installed" : l.map { "\($0.id)  \($0.module).\($0.entry)  \($0.url ?? $0.path ?? "")\($0.revision.map { " @ " + $0.prefix(8) } ?? "")" }.joined(separator: "\n"))
case "sync": sync(root()); print("synced")
default: usage()
}
