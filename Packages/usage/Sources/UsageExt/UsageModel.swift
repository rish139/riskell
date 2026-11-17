// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation

/// One rate-limit window: percent used, when it resets (nil when no window is running), and what was used out of what limit, in tokens.
struct UsageWin: Equatable, Codable {
    var pct: Int
    var resets: Double? = nil          // epoch seconds
    var used: Double? = nil
    var limit: Double? = nil
    var limitSet: Bool? = nil          // true when `limit` is one you configured, so `pct` is a real percentage; otherwise only the token counts mean anything
    var counted: Bool { limitSet == true }
    static func short(_ n: Double) -> String {
        n >= 1_000_000 ? String(format: n >= 10_000_000 ? "%.0fM" : "%.1fM", n / 1_000_000) : n >= 1000 ? String(format: "%.0fK", n / 1000) : String(Int(n))
    }
    func frac(len: Double, now: Double = Date().timeIntervalSince1970) -> Double? {      // how far through the window we are, 0...1
        resets.map { max(0, min(1, 1 - ($0 - now) / len)) }
    }
}

/// The Claude readings: the 5-hour and 7-day windows (computed from the local logs, see `ClaudeLogs`).
struct ClaudeUse: Equatable, Codable {
    var five: UsageWin? = nil, seven: UsageWin? = nil, sonnet: UsageWin? = nil, opus: UsageWin? = nil
    var fetched = 0.0
    var stale = false
    /// The figure on the bar: the worse percentage when a limit is configured, otherwise -1 (the bar shows tokens instead).
    var rep: Int { (five?.counted == true || seven?.counted == true) ? max(five?.counted == true ? five!.pct : 0, seven?.counted == true ? seven!.pct : 0) : -1 }
    /// Tokens of the running 5-hour session, shortened ("838K", "2.1M"), for when there is no limit to measure against.
    var tokenText: String? { rep >= 0 ? nil : five?.used.map { UsageWin.short($0) } }
}
