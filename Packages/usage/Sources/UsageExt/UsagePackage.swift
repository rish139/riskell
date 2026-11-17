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
    func set(claude u: ClaudeUse?) { if u != claude { claude = u } }
}

/// riskell's `usage` section of config.json, read live from the host config: `claude` (a bool), and the optional limits
/// `fiveHourTokens` and `sevenDayTokens` (tokens; absent means the user's own 30-day peak).
enum UsageConfig {
    static func claudeOn(_ c: HostConfig = .shared) -> Bool { c.bool("usage.claude") ?? false }
}

/// USAGE: the Claude meters, computed from the local Claude Code session logs, opt-in in config.json. The service runs only while the atom
/// is on a showing bar.
public struct UsageAtom: CustomAtom {
    public static let meta = AtomMeta(id: "usage", name: "AI usage", priority: 5, maxWidth: 260)
    public init() {}
    public func horizontal(_ env: Env) -> some View { UsageFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { UsageFace(vertical: true) }
    public var card: Card? { Card(id: "usage", size: { _ in UsageCard.size }) { UsageCard() } }
    public func isBlank(_ env: Env) -> Bool { !UsageConfig.claudeOn(env.config) }
    public func activate(_ env: Env) -> (() -> Void)? {
        let args = CommandLine.arguments
        // sample readings for snapshots: set once, never reads the logs. Checked before --no-usage, as before.
        if args.contains("--fake-usage") {
            let now = Date().timeIntervalSince1970
            UsageState.shared.set(claude: ClaudeUse(five: UsageWin(pct: 62, resets: now + 2 * 3600 + 1100), seven: UsageWin(pct: 41, resets: now + 4 * 86400 + 9 * 3600), sonnet: UsageWin(pct: 12, resets: now + 4 * 86400), fetched: now - 120))
            return nil
        }
        if args.contains("--no-usage") { return nil }
        return UsageService(env: env).start()
    }
}
