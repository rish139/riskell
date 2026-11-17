// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation

/// One rate-limit window: percent used, when it resets (nil when no window is running), and what was used out of what limit, in tokens.
struct UsageWin: Equatable, Codable {
    var pct: Int
    var resets: Double? = nil          // epoch seconds
    var used: Double? = nil
    var limit: Double? = nil
    func frac(len: Double, now: Double = Date().timeIntervalSince1970) -> Double? {      // how far through the window we are, 0...1
        resets.map { max(0, min(1, 1 - ($0 - now) / len)) }
    }
}

/// The Claude readings: the 5-hour and 7-day windows (computed from the local logs, see `ClaudeLogs`).
struct ClaudeUse: Equatable, Codable {
    var five: UsageWin? = nil, seven: UsageWin? = nil, sonnet: UsageWin? = nil, opus: UsageWin? = nil
    var fetched = 0.0
    var stale = false
    var rep: Int { max(five?.pct ?? 0, seven?.pct ?? 0) }
}
