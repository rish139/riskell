// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Foundation
import SQLite3

/// OpenCode Go usage from the console's own status page, read with the browser session cookie. Opt-in: `usage.opencode`.
enum OpenCodeStatus {
    /// The reading from the status JSON: the three meters, in the console's own rounding (integer, half up, of 100 * used / limit;
    /// dollars are micro-cents / 1e8). nil for a product that is not a Go plan, or when a meter is missing or not a number.
    static func parse(_ json: [String: Any], now: Double) -> OCUse? {
        guard (json["product"] as? String)?.hasPrefix("go") == true,
              let m = (json["access"] as? [String: Any])?["meters"] as? [String: Any] else { return nil }
        func win(_ key: String) -> UsageWin? {
            guard let o = m[key] as? [String: Any],
                  let l = Double("\(o["limitMicroCents"] ?? "")"), let us = Double("\(o["usedMicroCents"] ?? "")"),
                  l.isFinite, us.isFinite else { return nil }
            let pct = l > 0 ? Int(min(max(((us * 200 + l) / (l * 2)).rounded(.down), 0), 100_000)) : 0
            return UsageWin(pct: pct, resets: UsageDate.epoch(o["resetsAt"]), used: us / 1e8, limit: l / 1e8, limitSet: true)
        }
        guard let r = win("fiveHour"), let w = win("week"), let mo = win("month") else { return nil }
        let access = json["access"] as? [String: Any]
        return OCUse(roll: r, week: w, month: mo, plan: (json["product"] as? String) ?? "go",
                     ending: (json["cancelAtPeriodEnd"] as? Bool) ?? false, endsAt: UsageDate.epoch(access?["endsAt"]),
                     fetched: now, stale: false)
    }
}

/// The console session cookie, from the newest browser profile (a Firefox-style `cookies.sqlite`) under the profiles folder.
/// The database is copied (with its WAL) into a private folder, read there, and the folder is removed on every exit.
enum BrowserCookie {
    static func value(named name: String, profiles: String) -> String? {
        let fm = FileManager.default
        let newest = ((try? fm.contentsOfDirectory(atPath: profiles)) ?? [])
            .map { profiles + "/" + $0 + "/cookies.sqlite" }
            .filter { fm.fileExists(atPath: $0) && UsageConfig.inside(UsageConfig.resolved($0), home: UsageConfig.resolved(NSHomeDirectory())) }
            .max { modified($0) < modified($1) }
        guard let db = newest else { return nil }
        return value(named: name, inDatabase: db)
    }

    private static func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    private static func value(named name: String, inDatabase db: String) -> String? {
        let fm = FileManager.default
        // a new folder made by mkdtemp (mode 0700), inside the system temporary folder; removed when this function returns, however it returns
        var template = Array((NSTemporaryDirectory() + "riskell-usage-XXXXXX").utf8CString)
        guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) != nil else { return nil }
        let dir = String(cString: template)
        defer { try? fm.removeItem(atPath: dir) }
        let copy = dir + "/cookies.sqlite"
        guard (try? fm.copyItem(atPath: db, toPath: copy)) != nil else { return nil }
        if fm.fileExists(atPath: db + "-wal") { try? fm.copyItem(atPath: db + "-wal", toPath: copy + "-wal") }
        for p in [copy, copy + "-wal"] where fm.fileExists(atPath: p) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
        }

        var h: OpaquePointer?
        guard sqlite3_open_v2(copy, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(h); return nil }
        defer { sqlite3_close(h) }
        var st: OpaquePointer?
        let sql = "SELECT value FROM moz_cookies WHERE name=? AND host IN ('opencode.ai','.opencode.ai') AND value<>'' ORDER BY expiry DESC LIMIT 1"
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: c)
    }
}

/// Fetches the Go status with the session cookie. Every failure gives nil, with nothing about the cookie or the response kept or shown.
enum OpenCodeClient {
    static let url = URL(string: "https://opencode.ai/console/api/go/status")!

    /// Calls `done` on a background thread with the reading, or nil.
    static func fetch(_ s: OpenCodeSettings, done: @escaping (OCUse?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let session = BrowserCookie.value(named: "__Host-console_session", profiles: s.profiles) else { done(nil); return }
            var req = URLRequest(url: url)
            req.setValue("__Host-console_session=\(session)", forHTTPHeaderField: "Cookie")
            req.setValue(s.workspace, forHTTPHeaderField: "x-org-id")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("Mozilla/5.0 (Macintosh) riskell", forHTTPHeaderField: "User-Agent")
            UsageHTTP.get(req, timeout: 15) { status, data in
                guard status == 200, let data, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let r = OpenCodeStatus.parse(j, now: Date().timeIntervalSince1970) else { done(nil); return }
                done(r)
            }
        }
    }
}
