// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

/// riskell's `usage` section of config.json, read live from the host config: `claude` (a bool), `opencode.workspace` (empty is off) and
/// `opencode.profiles` (the browser profiles folder; a leading `~` is the home folder).
enum UsageConfig {
    static func claudeOn(_ c: HostConfig = .shared) -> Bool { c.bool("usage.claude") ?? false }
    static func opencodeWorkspace(_ c: HostConfig = .shared) -> String? { c.string("usage.opencode.workspace").flatMap { $0.isEmpty ? nil : $0 } }
    static func opencodeProfiles(_ c: HostConfig = .shared) -> String {
        (c.string("usage.opencode.profiles") ?? "~/Library/Application Support/zen/Profiles").replacingOccurrences(of: "~", with: NSHomeDirectory(), options: .anchored)
    }
}

/// USAGE: Claude and OpenCode Go meters, opt-in in config.json. The service runs only while the atom is on a showing bar.
public struct UsageAtom: CustomAtom {
    public static let meta = AtomMeta(id: "usage", name: "AI usage", priority: 5, maxWidth: 260)
    public init() {}
    public func horizontal(_ env: Env) -> some View { UsageFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { UsageFace(vertical: true) }
    public var card: Card? { Card(id: "usage", size: { _ in UsageCard.size }) { UsageCard() } }
    public func isBlank(_ env: Env) -> Bool { !UsageConfig.claudeOn(env.config) && UsageConfig.opencodeWorkspace(env.config) == nil }
    public func activate(_ env: Env) -> (() -> Void)? {
        let args = CommandLine.arguments
        // sample readings for snapshots: set once, never touches the keychain or the network. Checked before --no-usage, as before.
        if args.contains("--fake-usage") {
            let now = Date().timeIntervalSince1970
            UsageState.shared.set(claude: ClaudeUse(five: UsageWin(pct: 62, resets: now + 2 * 3600 + 1100), seven: UsageWin(pct: 41, resets: now + 4 * 86400 + 9 * 3600), sonnet: UsageWin(pct: 12, resets: now + 4 * 86400), fetched: now - 120))
            UsageState.shared.set(opencode: OCUse(roll: UsageWin(pct: 23, resets: now + 3600 * 3.4, used: 2.76, limit: 12), week: UsageWin(pct: 71, resets: now + 3 * 86400, used: 17.04, limit: 24), month: UsageWin(pct: 88, resets: now + 19 * 86400, used: 35.2, limit: 40), plan: "go", ending: true, endsAt: now + 19 * 86400, fetched: now - 300))
            return nil
        }
        if args.contains("--no-usage") { return nil }
        return UsageService(env: env).start()
    }
}
