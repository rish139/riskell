// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Foundation

/// One rate-limit window: percent used, when it resets (nil when no window is running), and what was used out of what limit.
/// Tokens for the Claude local logs, dollars for OpenCode (see `money` on the card's rows).
struct UsageWin: Equatable, Codable {
    var pct: Int
    var resets: Double? = nil          // epoch seconds
    var used: Double? = nil
    var limit: Double? = nil
    var limitSet: Bool? = nil          // true when `pct` is a real percentage: a limit you configured, or the provider's own figure
    var counted: Bool { limitSet == true }
    static func short(_ n: Double) -> String {
        n >= 1_000_000 ? String(format: n >= 10_000_000 ? "%.0fM" : "%.1fM", n / 1_000_000) : n >= 1000 ? String(format: "%.0fK", n / 1000) : String(Int(n))
    }
    func frac(len: Double, now: Double = Date().timeIntervalSince1970) -> Double? {      // how far through the window we are, 0...1
        resets.map { max(0, min(1, 1 - ($0 - now) / len)) }
    }
}

/// The Claude readings: the 5-hour and 7-day windows, from the local logs (`ClaudeLogs`) or from the account's limits (`ClaudeLimits`).
struct ClaudeUse: Equatable, Codable {
    var five: UsageWin? = nil, seven: UsageWin? = nil, sonnet: UsageWin? = nil, opus: UsageWin? = nil
    var fetched = 0.0
    var stale = false
    /// The figure on the bar: the worse percentage when a real one is known, otherwise -1 (the bar shows tokens instead).
    var rep: Int { (five?.counted == true || seven?.counted == true) ? max(five?.counted == true ? five!.pct : 0, seven?.counted == true ? seven!.pct : 0) : -1 }
    /// Tokens of the running 5-hour session, shortened ("838K", "2.1M"), for when there is no limit to measure against.
    var tokenText: String? { rep >= 0 ? nil : five?.used.map { UsageWin.short($0) } }
    /// True when the windows hold real percentages.
    var limited: Bool { five?.counted == true || seven?.counted == true }
}

/// The OpenCode Go readings: the rolling 5-hour, weekly and monthly meters, in dollars and percent.
struct OCUse: Equatable, Codable {
    var roll: UsageWin? = nil, week: UsageWin? = nil, month: UsageWin? = nil
    var plan = "go"
    var ending = false
    var endsAt: Double? = nil
    var fetched = 0.0
    var stale = false
    var rep: Int { month?.pct ?? 0 }
}

/// Dates in the providers' JSON: ISO 8601, with or without fractional seconds.
enum UsageDate {
    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let isoPlain = ISO8601DateFormatter()
    /// Epoch seconds of an ISO 8601 string; nil for anything else.
    static func epoch(_ s: Any?) -> Double? { (s as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }?.timeIntervalSince1970 }
}
