// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation

// What stands between a listing in the registry (or a URL someone pasted) and your machine. An extension is code that runs with your user's rights
// (docs/STOREFRONT.md, Trust), so every step before it runs is strict: only https repositories, nothing the listing says is trusted as it is, git is
// not allowed to run commands or ask questions, a compiled or script extension is installed only after you have been shown what it is and said yes,
// and a pill or theme file can only be an ordinary small file of the right kind.

/// git with its dangerous features off: no `ext::` transport (it runs commands), no prompts, no hooks. `userTyped`: a URL you typed yourself may also
/// be ssh or a local path; a registry listing may only be https (file:// only while RISKELL_ALLOW_FILE is set, for tests).
func git(_ args: [String], in dir: String? = nil, userTyped: Bool = false) -> (Int32, String) {
    let allowFile = userTyped || ProcessInfo.processInfo.environment["RISKELL_ALLOW_FILE"] != nil
    let protocols = ["https"] + (userTyped ? ["ssh"] : []) + (allowFile ? ["file"] : [])
    return sh(["git", "-c", "protocol.ext.allow=never", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + args, in: dir,
              env: ["GIT_ALLOW_PROTOCOL": protocols.joined(separator: ":"), "GIT_TERMINAL_PROMPT": "0"])
}

func safeRepoURL(_ s: String, userTyped: Bool) -> Bool {
    if s.contains(" ") || s.contains("\n") || s.hasPrefix("-") || s.hasPrefix("ext::") { return false }
    if s.hasPrefix("https://") { return s.count > 12 }
    if s.hasPrefix("file://") { return userTyped || ProcessInfo.processInfo.environment["RISKELL_ALLOW_FILE"] != nil }
    if userTyped, s.hasPrefix("ssh://") || (s.contains("@") && s.contains(":") && !s.contains("://")) { return true }      // ssh://host/x and the scp form
    return false
}

/// Everything a listing says is checked before it is used (the registry's own CI checks it too, but the client does not rely on that).
func listingProblems(_ l: Listing) -> [String] {
    var p: [String] = []
    if !matches(l.id, "^[a-z0-9][a-z0-9-]{0,38}$") { p.append("the id is not plain") }
    if !["atom", "reading", "pill", "theme", "preset"].contains(l.kind) { p.append("unknown kind") }
    if !matches(l.rev, "^[0-9a-f]{40}$") { p.append("the pinned commit is not a full hash") }
    if !matches(l.version, #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#) { p.append("the version is not SemVer") }
    if !safeRepoURL(l.repo, userTyped: false) { p.append("the repository is not an https address") }
    if let path = l.path, path.hasPrefix("/") || path.split(separator: "/").contains("..") { p.append("the path leaves the repository") }
    return p
}

func requireValid(_ l: Listing) {
    let p = listingProblems(l)
    if !p.isEmpty { fail("risk ext: the listing for \"\(l.id)\" is not usable: \(p.joined(separator: "; "))") }
}

/// Shows what is about to be installed and waits for a yes (`--yes` answers it, for scripts). No terminal and no `--yes`: nothing is installed.
func consent(_ title: String, _ lines: [String], yes: Bool) {
    print("\n\(title)")
    lines.forEach { print("  " + $0) }
    if yes { print("  (--yes: continuing)"); return }
    guard isatty(0) != 0 else { fail("risk ext: not installed: this needs your confirmation and there is no terminal. Read the above, then run it again with --yes.") }
    print("\nInstall it? [y/N] ", terminator: "")
    let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    guard answer == "y" || answer == "yes" else { fail("risk ext: not installed.") }
}

func codeWarning(_ l: Listing) -> [String] {
    ["\(l.name) \(l.version) by \(l.d["authors"].flatMap { $0 as? [String] }?.joined(separator: ", ") ?? "its author"), license \(l.d["license"] as? String ?? "?")",
     "source: \(l.repo) at \(l.rev)",
     "It is Swift code that is compiled into riskell and runs with your user's rights. There is no sandbox and no permission system.",
     "Read it before you say yes (every listing is pinned to this commit, so what you read is what you get)."]
}

/// A file named by a manifest must be a plain relative path to a small regular file of the expected kind inside the cloned repository.
func safeFile(_ f: String, in dir: String, extensions: [String]) -> String? {
    if f.isEmpty || f.hasPrefix("/") || f.contains("\0") || f.split(separator: "/").contains("..") { return nil }
    guard extensions.contains((f as NSString).pathExtension.lowercased()) else { return nil }
    let path = ((dir + "/" + f) as NSString).standardizingPath
    guard path.hasPrefix(((dir as NSString).standardizingPath) + "/"),
          let a = try? fm.attributesOfItem(atPath: path), a[.type] as? FileAttributeType == .typeRegular, (a[.size] as? Int ?? .max) <= 256_000 else { return nil }
    return path
}

/// The commands a pill would run, for the consent screen.
func pillCommands(_ paths: [String]) -> [String] {
    var out: [String] = []
    for p in paths {
        guard let t = read(p), let j = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any] else { out.append("(\((p as NSString).lastPathComponent) is not a readable pill)"); continue }
        for k in ["run", "stream", "click", "watch"] { if let v = j[k] as? String { out.append("\(k): \(v)") } }
    }
    return out
}
