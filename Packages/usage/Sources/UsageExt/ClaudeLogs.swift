// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation

/// Claude usage from the session logs Claude Code writes on this Mac (`*.jsonl` under its `projects` folders). Nothing else is read:
/// no credential, no network. The parsing and the window arithmetic are pure functions, so they can be checked without the files.
///
/// A session is a 5-hour block: it starts at its first event, and the next one starts at the first event at least 5 hours after that.
/// The 5-hour window is the latest session while it is still running; the 7-day window is every event of the last 7 days.
/// A limit is the one in config.json when it is given, otherwise the user's own peak over the last 30 days.
enum ClaudeLogs {
    static let day: Double = 86400
    static let window: Double = 30 * day            // only files changed in this span are read, and only events in it count
    static let sessionLength: Double = 5 * 3600

    /// One usage event as read from a line: its time (epoch seconds), its tokens, and its de-duplication key (nil when it has none).
    struct Item {
        let t: Double
        let tokens: Int
        let key: String?
    }

    /// What was parsed from one file, kept while the file's (mtime, size) do not change.
    struct Cached {
        let mtime: Double
        let size: Int
        let offset: Int          // how far the file was parsed: the end of its last complete line (logs only ever grow at the end)
        let items: [Item]
    }

    // MARK: where the logs are

    /// `~/.claude/projects`, `~/.config/claude/projects`, and the `projects` folder of CLAUDE_CONFIG_DIR when that is set.
    static func roots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var r = [NSHomeDirectory() + "/.claude/projects", NSHomeDirectory() + "/.config/claude/projects"]
        if let d = environment["CLAUDE_CONFIG_DIR"], !d.isEmpty { r.append((d as NSString).expandingTildeInPath + "/projects") }
        var seen = Set<String>()
        return r.filter { seen.insert($0).inserted }
    }

    /// Every `*.jsonl` file under the roots changed in the last 30 days. A file whose (mtime, size) match `cache` is not parsed again;
    /// the cache is replaced by what was seen now, so a deleted file drops out of it.
    static func scan(roots: [String], now: Double, cache: inout [String: Cached]) -> [Item] {
        let fm = FileManager.default
        let cutoff = now - window
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var seen = Set<String>()
        var live: [String: Cached] = [:]
        var items: [Item] = []
        for root in roots {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let mtime = v.contentModificationDate?.timeIntervalSince1970, mtime >= cutoff, let size = v.fileSize else { continue }
                let path = url.path
                guard seen.insert(path).inserted else { continue }
                let c: Cached
                if let hit = cache[path], hit.mtime == mtime, hit.size == size { c = hit }
                else if let hit = cache[path], size > hit.offset, mtime >= hit.mtime {      // it grew: only the new lines are read
                    let (more, end) = parseFile(url, from: hit.offset)
                    c = Cached(mtime: mtime, size: size, offset: end, items: hit.items + more)
                } else { let (all, end) = parseFile(url, from: 0); c = Cached(mtime: mtime, size: size, offset: end, items: all) }
                live[path] = c
                items += c.items
            }
        }
        cache = live
        return items
    }

    /// Read from `from` in 4 MB pieces, so a huge log never sits in memory whole: each piece is cut at its last newline and the rest is carried over.
    /// Returns the events and the offset after the last complete line.
    static func parseFile(_ url: URL, from: Int) -> ([Item], Int) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ([], from) }
        defer { try? h.close() }
        if from > 0 { try? h.seek(toOffset: UInt64(from)) }
        var items: [Item] = [], carry = Data(), end = from
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty {
            carry.append(chunk)
            guard let cut = carry.lastIndex(of: 10) else { continue }
            let head = carry[carry.startIndex...cut]
            items += head.withUnsafeBytes { parse(bytes: $0) }
            end += head.count
            carry = Data(carry[carry.index(after: cut)...])
        }
        return (items, end)
    }

    // MARK: parsing (pure)

    /// The events of the lines that carry usage. Works on the raw bytes: a line is several kilobytes of conversation, so it is searched with
    /// `memmem` for the few quoted names that matter and never decoded or parsed as a whole.
    static func parse(bytes raw: UnsafeRawBufferPointer) -> [Item] {
        guard let base = raw.baseAddress else { return [] }
        var items: [Item] = [], start = 0
        while start < raw.count {
            let p = base + start
            let nl = memchr(p, 10, raw.count - start)
            let len = nl.map { $0 - UnsafeMutableRawPointer(mutating: p) } ?? raw.count - start
            if len > 0, let it = event(UnsafeRawBufferPointer(start: p, count: len)) { items.append(it) }
            start += len + 1
        }
        return items
    }

    static func parse(lines: [Substring]) -> [Item] { lines.compactMap(item) }
    static func item(_ line: Substring) -> Item? { Array(line.utf8).withUnsafeBytes { event($0) } }

    private static func find(_ hay: UnsafeRawBufferPointer, _ needle: StaticString, from: Int = 0, within: Int? = nil) -> Int? {
        let end = min(hay.count, within.map { from + $0 } ?? hay.count)
        guard from < end, let base = hay.baseAddress else { return nil }
        guard let r = memmem(base + from, end - from, needle.utf8Start, needle.utf8CodeUnitCount) else { return nil }
        return r - UnsafeMutableRawPointer(mutating: base) + needle.utf8CodeUnitCount      // the index just after the needle
    }
    private static func number(_ hay: UnsafeRawBufferPointer, after at: Int) -> Int {
        var n = 0, i = at
        while i < hay.count, hay[i] >= 48, hay[i] <= 57 { n = n &* 10 &+ Int(hay[i] - 48); i += 1 }
        return n
    }
    private static func text(_ hay: UnsafeRawBufferPointer, after at: Int, max: Int = 120) -> String? {
        var i = at
        while i < hay.count, i - at < max, hay[i] != 34 { i += 1 }
        guard i < hay.count, hay[i] == 34 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: hay[at..<i]), as: UTF8.self)
    }

    /// One line: its time, its tokens (input + output + cache creation) and its de-duplication key. nil when it carries no usage.
    static func event(_ l: UnsafeRawBufferPointer) -> Item? {
        guard let u = find(l, "\"usage\":{"), let ts = find(l, "\"timestamp\":\""), let t = text(l, after: ts, max: 40).flatMap({ date($0) }) else { return nil }
        func tokens(_ key: StaticString) -> Int { find(l, key, from: u, within: 700).map { number(l, after: $0) } ?? 0 }
        var key: String? = nil
        if let m = find(l, "\"id\":\"msg_"), let id = text(l, after: m), let r = find(l, "\"requestId\":\""), let req = text(l, after: r) { key = "msg_" + id + "|" + req }
        return Item(t: t, tokens: tokens("\"input_tokens\":") + tokens("\"output_tokens\":") + tokens("\"cache_creation_input_tokens\":"), key: key)
    }

    /// A streamed answer repeats its usage on each line: the first event with a key is kept, the rest are dropped.
    static func dedupe(_ items: [Item]) -> [(t: Double, tokens: Int)] {
        var seen = Set<String>()
        var out: [(t: Double, tokens: Int)] = []
        out.reserveCapacity(items.count)
        for i in items {
            if let k = i.key, !seen.insert(k).inserted { continue }
            out.append((t: i.t, tokens: i.tokens))
        }
        return out
    }

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let isoPlain = ISO8601DateFormatter()
    static func date(_ s: Any?) -> Double? { (s as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }?.timeIntervalSince1970 }
    private static func count(_ x: Any?) -> Int { (x as? NSNumber)?.intValue ?? 0 }

    // MARK: the windows (pure)

    /// The two windows from the events (any order, any age). `fiveLimit` and `sevenLimit` are the configured limits, nil when absent.
    static func summarize(events: [(t: Double, tokens: Int)], now: Double, fiveLimit: Double?, sevenLimit: Double?) -> ClaudeUse {
        let ev = events.filter { $0.t >= now - window && $0.t <= now }.sorted { $0.t < $1.t }

        // sessions: a new one at the first event at least 5 h after the current session's start
        var sessions: [(start: Double, tokens: Int)] = []
        for e in ev {
            if let last = sessions.last, e.t < last.start + sessionLength { sessions[sessions.count - 1].tokens += e.tokens }
            else { sessions.append((start: e.t, tokens: e.tokens)) }
        }
        let peak5 = sessions.map(\.tokens).max() ?? 0

        // rolling 7-day sums: prefix sums over the sorted events, so a window is two binary searches
        let ts = ev.map(\.t)
        var cum = [0]
        for e in ev { cum.append(cum[cum.count - 1] + e.tokens) }
        func countUpTo(_ x: Double) -> Int {          // events with t <= x
            var lo = 0, hi = ts.count
            while lo < hi { let m = (lo + hi) / 2; if ts[m] <= x { lo = m + 1 } else { hi = m } }
            return lo
        }
        func tokens(after lo: Double, upTo hi: Double) -> Int { cum[countUpTo(hi)] - cum[countUpTo(lo)] }
        let used7 = tokens(after: now - 7 * day, upTo: now)
        var peak7 = 0
        var s = now
        while s >= now - window {                     // sampled once per hour across the 30 days
            peak7 = max(peak7, tokens(after: s - 7 * day, upTo: s))
            s -= 3600
        }

        func limit(_ given: Double?, _ peak: Int) -> Double {
            if let g = given, g > 0 { return g }
            return Double(max(1, peak))
        }
        let l5 = limit(fiveLimit, peak5), l7 = limit(sevenLimit, peak7)
        func pct(_ used: Double, _ l: Double) -> Int { min(100, Int((used / l * 100).rounded())) }

        var used5 = 0.0, resets5: Double? = nil
        if let last = sessions.last, now < last.start + sessionLength {
            used5 = Double(last.tokens)
            resets5 = last.start + sessionLength
        }
        let five = UsageWin(pct: pct(used5, l5), resets: resets5, used: used5, limit: l5)
        let seven = UsageWin(pct: pct(Double(used7), l7), resets: nil, used: Double(used7), limit: l7)
        return ClaudeUse(five: five, seven: seven, sonnet: nil, opus: nil, fetched: now, stale: false)
    }
}
