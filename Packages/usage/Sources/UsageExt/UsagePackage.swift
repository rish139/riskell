// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// What riskell links in: one atom, the AI usage meters.
public enum UsagePackage: RiskellPackage {
    public static var atoms: [any CustomAtom.Type] { [UsageAtom.self] }
}

/// The readings, in one object for both forms of the atom and the card. The service writes them (see UsageService); the views read them.
/// A value equal to the one held is not written again, so an unchanged poll redraws nothing.
final class UsageState: ObservableObject {
    static let shared = UsageState()
    @Published private(set) var claude: ClaudeUse? = nil
    @Published private(set) var opencode: OCUse? = nil
    func set(claude u: ClaudeUse?) { if u != claude { claude = u } }
    func set(opencode u: OCUse?) { if u != opencode { opencode = u } }
}

/// The OpenCode Go provider, once its settings are valid: the workspace id and the existing profiles folder (inside the home folder).
struct OpenCodeSettings: Equatable {
    let workspace: String
    let profiles: String
}

/// riskell's `usage` section of config.json, read live from the host config. Three providers, each switched on by its own key:
/// `claude` (the local logs), `claudeLimits` (the account's real limits; needs `claude`), and `opencode` (an object with `workspace`
/// and `profiles`). A provider that is off does nothing: no process, no file read, no request.
enum UsageConfig {
    static let defaultProfiles = "~/Library/Application Support/zen/Profiles"

    static func claudeOn(_ c: HostConfig = .shared) -> Bool { c.bool("usage.claude") ?? false }
    static func claudeLimitsOn(_ c: HostConfig = .shared) -> Bool { claudeOn(c) && (c.bool("usage.claudeLimits") ?? false) }

    /// The OpenCode settings when the provider is on, otherwise nil. The workspace is checked first, so with no valid workspace the
    /// profiles folder is not touched at all.
    static func opencode(_ c: HostConfig = .shared) -> OpenCodeSettings? {
        guard let ws = c.string("usage.opencode.workspace"), validWorkspace(ws) else { return nil }
        guard let dir = profilesDirectory(c.string("usage.opencode.profiles") ?? defaultProfiles) else { return nil }
        return OpenCodeSettings(workspace: ws, profiles: dir)
    }

    /// `wrk_` and 6 to 64 letters or digits (ASCII), nothing else.
    static func validWorkspace(_ s: String) -> Bool {
        guard s.hasPrefix("wrk_") else { return false }
        let id = s.dropFirst(4)
        return (6...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The folder for `raw` with a leading `~` expanded, symlinks resolved, when it is an existing directory inside `home`; otherwise nil.
    static func profilesDirectory(_ raw: String, home: String = NSHomeDirectory()) -> String? {
        var p = raw
        if p == "~" || p.hasPrefix("~/") { p = home + String(p.dropFirst()) }
        let real = resolved(p), realHome = resolved(home)
        guard inside(real, home: realHome) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { return nil }
        return real
    }

    /// Whether `path` is `home` or below it. Both are absolute and already resolved.
    static func inside(_ path: String, home: String) -> Bool {
        path == home || path.hasPrefix(home.hasSuffix("/") ? home : home + "/")
    }

    static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
}

/// USAGE: the Claude and OpenCode Go meters, opt-in in config.json. The service runs only while the atom is on a showing bar.
public struct UsageAtom: CustomAtom {
    public static let meta = AtomMeta(id: "usage", name: "AI usage", priority: 5, maxWidth: 260)
    public init() {}
    public func horizontal(_ env: Env) -> some View { UsageFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { UsageFace(vertical: true) }
    public var card: Card? { Card(id: "usage", size: { _ in UsageCard.size }) { UsageCard() } }
    public func isBlank(_ env: Env) -> Bool { !UsageConfig.claudeOn(env.config) && UsageConfig.opencode(env.config) == nil }
    public func activate(_ env: Env) -> (() -> Void)? {
        let args = CommandLine.arguments
        // sample readings for snapshots: set once, never reads a file or the network. Checked before --no-usage, as before.
        if args.contains("--fake-usage") {
            let now = Date().timeIntervalSince1970
            UsageState.shared.set(claude: ClaudeUse(five: UsageWin(pct: 62, resets: now + 2 * 3600 + 1100, limitSet: true),
                                                    seven: UsageWin(pct: 41, resets: now + 4 * 86400 + 9 * 3600, limitSet: true),
                                                    sonnet: UsageWin(pct: 12, resets: now + 4 * 86400, limitSet: true), fetched: now - 120))
            UsageState.shared.set(opencode: OCUse(roll: UsageWin(pct: 23, resets: now + 3600 * 3.4, used: 2.76, limit: 12, limitSet: true),
                                                  week: UsageWin(pct: 71, resets: now + 3 * 86400, used: 17.04, limit: 24, limitSet: true),
                                                  month: UsageWin(pct: 88, resets: now + 19 * 86400, used: 35.2, limit: 40, limitSet: true),
                                                  plan: "go", ending: true, endsAt: now + 19 * 86400, fetched: now - 300))
            return nil
        }
        if args.contains("--no-usage") { return nil }
        return UsageService(env: env).start()
    }
}
