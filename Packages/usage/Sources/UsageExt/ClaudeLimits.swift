// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation

/// The Claude Code login token, kept in the login keychain by Claude Code. Read only for `usage.claudeLimits`.
enum ClaudeCredential {
    /// The `accessToken` inside the `claudeAiOauth` object of the keychain item's JSON. nil when absent or empty.
    static func token(fromKeychainJSON data: Data) -> String? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let o = j["claudeAiOauth"] as? [String: Any], let t = o["accessToken"] as? String, !t.isEmpty else { return nil }
        return t
    }

    /// Read through /usr/bin/security, not SecItemCopyMatching: Claude Code's item has the partition list "apple-tool:" (Claude Code writes it
    /// with that tool, and resets it on every token refresh), so Apple's tool opens it silently while any other app gets the password
    /// prompt again after each refresh.
    static func readFromKeychain() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return token(fromKeychainJSON: d)
    }
}

/// The account's real Claude limits: one GET to the usage endpoint with the login token.
enum ClaudeLimits {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The reading from the endpoint's JSON: the 5-hour and 7-day windows (both required), and the Sonnet and Opus windows when present.
    /// Every window is a real percentage (`limitSet`). nil when a required window is missing or a number is not usable.
    static func parse(_ json: [String: Any], now: Double) -> ClaudeUse? {
        func win(_ key: String) -> UsageWin? {
            guard let o = json[key] as? [String: Any], let u = (o["utilization"] as? NSNumber)?.doubleValue, u.isFinite else { return nil }
            let pct = Int(min(max(u.rounded(), 0), 1000))
            return UsageWin(pct: pct, resets: UsageDate.epoch(o["resets_at"]), limitSet: true)
        }
        guard let five = win("five_hour"), let seven = win("seven_day") else { return nil }
        return ClaudeUse(five: five, seven: seven, sonnet: win("seven_day_sonnet"), opus: win("seven_day_opus"), fetched: now, stale: false)
    }
}

/// Holds the login token in memory only and makes the request. A rejected token (401: Claude Code refreshed it) is read again once.
/// Every failure gives nil; nothing about the token, the response or the reason is kept or shown.
final class ClaudeLimitsClient {
    private let lock = NSLock()
    private var token: String?

    /// Calls `done` on a background thread with the reading, or nil when the token or the request fails.
    func fetch(_ done: @escaping (ClaudeUse?) -> Void) { attempt(retry: true, done) }

    private func attempt(retry: Bool, _ done: @escaping (ClaudeUse?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let t = self.currentToken(fresh: !retry) else { done(nil); return }
            var req = URLRequest(url: ClaudeLimits.url)
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            UsageHTTP.get(req, timeout: 8) { status, data in
                if status == 401, retry { self.attempt(retry: false, done); return }
                guard status == 200, let data, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let r = ClaudeLimits.parse(j, now: Date().timeIntervalSince1970) else { done(nil); return }
                done(r)
            }
        }
    }

    private func currentToken(fresh: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        if fresh || token == nil { token = ClaudeCredential.readFromKeychain() }
        return token
    }
}
