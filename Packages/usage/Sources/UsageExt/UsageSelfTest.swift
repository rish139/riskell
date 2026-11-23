// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Foundation

/// `riskell --usage-selftest`: the Claude window arithmetic, the log parsing, and the parsing and validation of the two providers, on
/// synthetic input only (no file, keychain or network). Returns one case per check; the app draws them.
public enum UsageSelfTest {
    public static func cases() -> [(name: String, ok: Bool, detail: String?)] {
        let now = 1_800_000_000.0
        let h = 3600.0
        var results: [(name: String, ok: Bool, detail: String?)] = []
        func check(_ name: String, _ ok: Bool) { results.append((name, ok, nil)) }

        // 1. no events: nothing used, limits fall back to 1 (no peak)
        let none = ClaudeLogs.summarize(events: [], now: now, fiveLimit: nil, sevenLimit: nil)
        check("no events", none.five?.pct == 0 && none.five?.used == 0 && none.five?.resets == nil
              && none.seven?.pct == 0 && none.seven?.resets == nil && none.five?.limit == 1)

        // 2. one session active: two events 1 h and 30 min ago, both in the one 5-hour session
        let one = ClaudeLogs.summarize(events: [(t: now - h, tokens: 1000), (t: now - 0.5 * h, tokens: 500)], now: now,
                                       fiveLimit: 3000, sevenLimit: nil)
        check("one session active", one.five?.used == 1500 && one.five?.pct == 50 && one.five?.resets == now - h + 5 * h)

        // 3. two sessions 6 h apart: the first has ended, so only the second counts in the 5-hour window
        let two = ClaudeLogs.summarize(events: [(t: now - 9 * h, tokens: 1000), (t: now - 3 * h, tokens: 500)], now: now,
                                       fiveLimit: 1000, sevenLimit: nil)
        check("two sessions, first ended", two.five?.used == 500 && two.five?.pct == 50 && two.five?.resets == now - 3 * h + 5 * h)

        // 4. limits given: 5 h window 300 of 600, 7-day window 1500 of 3000 (a day-old event counts only there)
        let given = ClaudeLogs.summarize(events: [(t: now - h, tokens: 300), (t: now - 2 * 86400, tokens: 1200)], now: now,
                                         fiveLimit: 600, sevenLimit: 3000)
        check("limits given", given.five?.limit == 600 && given.five?.pct == 50 && given.seven?.used == 1500
              && given.seven?.limit == 3000 && given.seven?.pct == 50)

        // 5. limits absent: the peak is the largest 5-hour session (400) and the largest 7-day total (500)
        let peak = ClaudeLogs.summarize(events: [(t: now - 10 * h, tokens: 400), (t: now - 2 * h, tokens: 100)], now: now,
                                        fiveLimit: nil, sevenLimit: nil)
        check("limits absent uses peak", peak.five?.limit == 400 && peak.five?.used == 100 && peak.five?.pct == 25
              && peak.seven?.limit == 500 && peak.seven?.pct == 100)

        // 6. a duplicate id counted once; cache reads are not counted; a line without usage is skipped
        let lines: [Substring] = [
            Substring(line(now - 1000, id: "msg_1", req: "req_1", input: 40, output: 10, creation: 50, read: 9999)),
            Substring(line(now - 990, id: "msg_1", req: "req_1", input: 40, output: 10, creation: 50, read: 9999)),
            Substring(#"{"timestamp":"2027-01-01T00:00:00Z","message":{"role":"user"}}"#),
        ]
        let parsed = ClaudeLogs.dedupe(ClaudeLogs.parse(lines: lines))
        let dup = ClaudeLogs.summarize(events: parsed, now: now, fiveLimit: 1000, sevenLimit: nil)
        check("duplicate id counted once", parsed.count == 1 && dup.five?.used == 100)

        // 7. the Claude limits endpoint: a normal response, every window a real percentage, the resets read
        let limitsJSON: [String: Any] = [
            "five_hour": ["utilization": 62.4, "resets_at": "2027-01-01T00:00:00Z"],
            "seven_day": ["utilization": 41.0, "resets_at": "2027-01-01T00:00:00.500Z"],
            "seven_day_sonnet": ["utilization": 11.6, "resets_at": "2027-01-02T00:00:00Z"],
        ]
        let lim = ClaudeLimits.parse(limitsJSON, now: now)
        check("claude limits normal response",
              lim?.five?.pct == 62 && lim?.five?.limitSet == true && lim?.five?.counted == true && lim?.five?.resets == 1_798_761_600
              && lim?.seven?.pct == 41 && lim?.seven?.counted == true && lim?.sonnet?.pct == 12 && lim?.opus == nil
              && lim?.fetched == now && lim?.stale == false && lim?.rep == 62)

        // 8. a response missing a window (no seven_day) gives no reading
        let missing = ClaudeLimits.parse(["five_hour": ["utilization": 10.0]], now: now)
        check("claude limits missing window", missing == nil)

        // 9. a keychain item with no token gives none; one with a token gives it
        let noToken = Data(#"{"claudeAiOauth":{"accessToken":"","refreshToken":"r"}}"#.utf8)
        let noObject = Data(#"{"other":{"accessToken":"x"}}"#.utf8)
        let withToken = Data(#"{"claudeAiOauth":{"accessToken":"synthetic-token-1234"}}"#.utf8)
        check("keychain json without a token",
              ClaudeCredential.token(fromKeychainJSON: noToken) == nil && ClaudeCredential.token(fromKeychainJSON: noObject) == nil
              && ClaudeCredential.token(fromKeychainJSON: Data("not json".utf8)) == nil)
        check("keychain json with a token", ClaudeCredential.token(fromKeychainJSON: withToken) == "synthetic-token-1234")

        // 10. an OpenCode Go response: the three meters, dollars, the console's rounding (23 %, 71 %, 88 %), the plan end
        let ocJSON: [String: Any] = [
            "product": "go-plus",
            "cancelAtPeriodEnd": true,
            "access": [
                "endsAt": "2027-01-20T00:00:00Z",
                "meters": [
                    "fiveHour": ["limitMicroCents": 1_200_000_000, "usedMicroCents": 276_000_000, "resetsAt": "2027-01-01T03:00:00Z"],
                    "week": ["limitMicroCents": "2400000000", "usedMicroCents": "1704000000", "resetsAt": "2027-01-04T00:00:00Z"],
                    "month": ["limitMicroCents": 4_000_000_000, "usedMicroCents": 3_520_000_000, "resetsAt": "2027-01-20T00:00:00Z"],
                ],
            ],
        ]
        let oc = OpenCodeStatus.parse(ocJSON, now: now)
        check("opencode normal response",
              oc?.roll?.pct == 23 && oc?.week?.pct == 71 && oc?.month?.pct == 88 && oc?.rep == 88
              && oc?.roll?.used == 2.76 && oc?.roll?.limit == 12 && oc?.roll?.limitSet == true
              && oc?.plan == "go-plus" && oc?.ending == true && oc?.endsAt == 1_800_403_200)

        // 11. the percent rounds half up, as the console does: 12.5 % is 13
        var half = ocJSON
        half["access"] = ["meters": ["fiveHour": ["limitMicroCents": 1_000_000_000, "usedMicroCents": 125_000_000],
                                     "week": ["limitMicroCents": 1_000_000_000, "usedMicroCents": 0],
                                     "month": ["limitMicroCents": 1_000_000_000, "usedMicroCents": 0]]]
        check("opencode percent rounds half up", OpenCodeStatus.parse(half, now: now)?.roll?.pct == 13)

        // 12. a product that is not a Go plan gives none
        var other = ocJSON
        other["product"] = "zen"
        check("opencode non-go product is nil", OpenCodeStatus.parse(other, now: now) == nil)

        // 13. workspace ids: accepted only as wrk_ and 6 to 64 letters or digits
        let longOK = "wrk_" + String(repeating: "a", count: 64), longBad = "wrk_" + String(repeating: "a", count: 65)
        check("workspace id table",
              UsageConfig.validWorkspace("wrk_abc123") && UsageConfig.validWorkspace(longOK)
              && !UsageConfig.validWorkspace("wrk_") && !UsageConfig.validWorkspace("x; rm")
              && !UsageConfig.validWorkspace("wrk_a b") && !UsageConfig.validWorkspace(longBad)
              && !UsageConfig.validWorkspace("wrk_abcde") && !UsageConfig.validWorkspace("wrk_ab-cdef"))

        // 14. a path is inside the home folder or it is not used
        check("path inside home accepted", UsageConfig.inside("/hm/ab/Library/Application Support/zen", home: "/hm/ab"))
        check("path outside home rejected",
              !UsageConfig.inside("/etc", home: "/hm/ab") && !UsageConfig.inside("/hm/ab2/x", home: "/hm/ab"))

        return results
    }

    private static func line(_ t: Double, id: String, req: String, input: Int, output: Int, creation: Int, read: Int) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"timestamp":"\#(f.string(from: Date(timeIntervalSince1970: t)))","requestId":"\#(req)","message":{"id":"\#(id)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(creation),"cache_read_input_tokens":\#(read)}}}"#
    }
}
