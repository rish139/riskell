import Foundation
import Security
import SQLite3
import RiskellKit

/// Claude and OpenCode Go usage, in-process. Both are opt-in through config.json (see AppConfig).
/// A reading is cached only when it validates; any failure keeps the last good one, marked stale.
final class UsageService {
    private let store: Store
    private var timer: Timer?
    static var skipClaude = false       // --no-claude: do not touch the keychain (it prompts the first time)
    private let dir = NSHomeDirectory() + "/.cache/riskell"
    static var opencodeOrg: String? { AppConfig.shared.opencodeWorkspace }      // the Go workspace id, from config.json; nil = OpenCode usage is off

    init(store: Store) { self.store = store }

    func start() {
        let c = (try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/usage-claude-v2.json"))).flatMap { try? JSONDecoder().decode(ClaudeUse.self, from: $0) }
        let o = (try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/usage-opencode-v2.json"))).flatMap { try? JSONDecoder().decode(OCUse.self, from: $0) }
        if var c { c.stale = true; store.set(claude: c) }
        if var o { o.stale = true; store.set(opencode: o) }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 30
    }

    /// The providers changed in config.json: drop what is now off, fetch what is on.
    func reconfigure() {
        if !AppConfig.shared.claudeEnabled { store.set(claude: nil) }
        if Self.opencodeOrg == nil { store.set(opencode: nil) }
        if Needs.isRunning("usage") { refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func save<T: Encodable>(_ name: String, _ v: T) { try? JSONEncoder().encode(v).write(to: URL(fileURLWithPath: "\(dir)/usage-\(name)-v2.json")) }

    func refresh() {
        if !Self.skipClaude && AppConfig.shared.claudeEnabled { fetchClaude { [weak self] r in
            guard let self else { return }
            DispatchQueue.main.async {
                if let r { self.store.set(claude: r); self.save("claude", r) }
                else if var c = self.store.claude { c.stale = true; self.store.set(claude: c) }
            }
        } }
        if Self.opencodeOrg != nil { fetchOpenCode { [weak self] r in
            guard let self else { return }
            DispatchQueue.main.async {
                if let r { self.store.set(opencode: r); self.save("opencode", r) }
                else if var c = self.store.opencode { c.stale = true; self.store.set(opencode: c) }
            }
        } }
    }

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let isoPlain = ISO8601DateFormatter()
    static func date(_ s: Any?) -> Double? { (s as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }?.timeIntervalSince1970 }

    // MARK: Claude — the OAuth token Claude Code keeps in the login keychain

    /// Read through /usr/bin/security, not SecItemCopyMatching: Claude Code's item has the partition list "apple-tool:" (Claude Code writes it
    /// with that tool, and resets it on every token refresh), so Apple's tool opens it silently while any app of ours, "Always Allow" or
    /// not, gets the password prompt again after each refresh.
    private func claudeToken() -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let o = j["claudeAiOauth"] as? [String: Any], let t = o["accessToken"] as? String, !t.isEmpty else { return nil }
        return t
    }

    /// The token is kept in memory; only a rejected one (401, Claude Code refreshed it) sends us back to the keychain.
    private let tokenLock = NSLock()
    private var cachedToken: String?
    private func token(fresh: Bool) -> String? {
        tokenLock.lock(); defer { tokenLock.unlock() }
        if fresh || cachedToken == nil { cachedToken = claudeToken() }
        return cachedToken
    }

    private func fetchClaude(retry: Bool = true, _ done: @escaping (ClaudeUse?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let token = self.token(fresh: !retry) else { done(nil); return }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!); req.timeoutInterval = 8
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                if (resp as? HTTPURLResponse)?.statusCode == 401, retry { self.fetchClaude(retry: false, done); return }
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { done(nil); return }
                func win(_ k: String) -> UsageWin? {
                    guard let o = j[k] as? [String: Any], let util = (o["utilization"] as? NSNumber)?.doubleValue else { return nil }
                    return UsageWin(pct: Int(util.rounded()), resets: Self.date(o["resets_at"]))
                }
                guard let five = win("five_hour"), let seven = win("seven_day") else { done(nil); return }
                done(ClaudeUse(five: five, seven: seven, sonnet: win("seven_day_sonnet"), opus: win("seven_day_opus"), fetched: Date().timeIntervalSince1970, stale: false))
            }.resume()
        }
    }

    // MARK: OpenCode Go — the console session cookie from the newest browser profile (config: usage.opencode.profiles)

    private func zenCookie(_ name: String) -> String? {
        let root = AppConfig.shared.opencodeProfiles
        let fm = FileManager.default
        let dbs = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).map { "\(root)/\($0)/cookies.sqlite" }
            .filter { fm.fileExists(atPath: $0) }
            .sorted { ((try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) > ((try? fm.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast) }
        for db in dbs {
            let tmp = NSTemporaryDirectory() + "riskell-cookies-\(getpid()).sqlite"
            try? fm.removeItem(atPath: tmp); try? fm.removeItem(atPath: tmp + "-wal")
            guard (try? fm.copyItem(atPath: db, toPath: tmp)) != nil else { continue }
            try? fm.copyItem(atPath: db + "-wal", toPath: tmp + "-wal")
            defer { try? fm.removeItem(atPath: tmp); try? fm.removeItem(atPath: tmp + "-wal") }
            var h: OpaquePointer?
            guard sqlite3_open_v2(tmp, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(h); continue }
            defer { sqlite3_close(h) }
            var st: OpaquePointer?
            let sql = "SELECT value FROM moz_cookies WHERE name=? AND host IN ('opencode.ai','.opencode.ai') AND value<>'' ORDER BY expiry DESC LIMIT 1"
            guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_text(st, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) { return String(cString: c) }
        }
        return nil
    }

    private func fetchOpenCode(_ done: @escaping (OCUse?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let org = Self.opencodeOrg, let session = self.zenCookie("__Host-console_session") else { done(nil); return }
            var req = URLRequest(url: URL(string: "https://opencode.ai/console/api/go/status")!); req.timeoutInterval = 15
            req.setValue("__Host-console_session=\(session)", forHTTPHeaderField: "Cookie")
            req.setValue(org, forHTTPHeaderField: "x-org-id")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (j["product"] as? String)?.hasPrefix("go") == true,
                      let m = (j["access"] as? [String: Any])?["meters"] as? [String: Any] else { done(nil); return }
                // the console's own rounding: integer half-up of 100 * used / limit; dollars = micro-cents / 1e8
                func win(_ key: String) -> UsageWin? {
                    guard let o = m[key] as? [String: Any], let l = Double("\(o["limitMicroCents"] ?? "")"), let us = Double("\(o["usedMicroCents"] ?? "")") else { return nil }
                    return UsageWin(pct: l > 0 ? Int(((us * 200 + l) / (l * 2)).rounded(.down)) : 0, resets: Self.date(o["resetsAt"]), used: us / 1e8, limit: l / 1e8)
                }
                guard let r = win("fiveHour"), let w = win("week"), let mo = win("month") else { done(nil); return }
                let access = j["access"] as? [String: Any]
                done(OCUse(roll: r, week: w, month: mo, plan: (j["product"] as? String) ?? "go", ending: (j["cancelAtPeriodEnd"] as? Bool) ?? false,
                           endsAt: Self.date(access?["endsAt"]), fetched: Date().timeIntervalSince1970, stale: false))
            }.resume()
        }
    }
}
