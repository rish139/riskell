// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation

/// `riskell --usage-selftest`: the Claude window arithmetic and the log parsing on synthetic events. Prints PASS or FAIL per case.
public enum UsageSelfTest {
    public static func run() -> Never {
        let now = 1_800_000_000.0
        let h = 3600.0
        var failed = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "PASS " : "FAIL ") + name)
            if !ok { failed += 1 }
        }

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

        if failed > 0 { print("\(failed) FAIL") } else { print("all passed") }
        exit(failed > 0 ? 1 : 0)
    }

    private static func line(_ t: Double, id: String, req: String, input: Int, output: Int, creation: Int, read: Int) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"timestamp":"\#(f.string(from: Date(timeIntervalSince1970: t)))","requestId":"\#(req)","message":{"id":"\#(id)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(creation),"cache_read_input_tokens":\#(read)}}}"#
    }
}
