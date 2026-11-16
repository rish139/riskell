import Foundation

/// One rate-limit window: percent used, when it resets, and (OpenCode) what was used out of what limit, in dollars.
struct UsageWin: Equatable, Codable {
    var pct: Int
    var resets: Double? = nil          // epoch seconds
    var used: Double? = nil
    var limit: Double? = nil
    func frac(len: Double, now: Double = Date().timeIntervalSince1970) -> Double? {      // how far through the window we are, 0...1
        resets.map { max(0, min(1, 1 - ($0 - now) / len)) }
    }
}
struct ClaudeUse: Equatable, Codable {
    var five: UsageWin? = nil, seven: UsageWin? = nil, sonnet: UsageWin? = nil, opus: UsageWin? = nil
    var fetched = 0.0
    var stale = false
    var rep: Int { max(five?.pct ?? 0, seven?.pct ?? 0) }
}
struct OCUse: Equatable, Codable {
    var roll: UsageWin? = nil, week: UsageWin? = nil, month: UsageWin? = nil
    var plan = "go"
    var ending = false
    var endsAt: Double? = nil
    var fetched = 0.0
    var stale = false
    var rep: Int { month?.pct ?? 0 }
}
