// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import Combine
import RiskellKit

/// The usage providers, each switched on in config.json (see `UsageConfig`). Each reading is cached (only its numbers) and shown dimmed
/// until the first fresh one of this launch.
/// Claude: the local logs (`ClaudeLogs`), or the account's real limits (`ClaudeLimits`) when `claudeLimits` is on; a failed limits
/// request falls back to the local reading, marked stale. OpenCode Go: its status with the browser session (`OpenCodeClient`).
final class UsageService {
    private let env: Env
    private let state = UsageState.shared
    private var providers: AnyCancellable?
    /// The log files parsed so far, by path. Touched only on `work`.
    private var files: [String: ClaudeLogs.Cached] = [:]
    private let work = DispatchQueue(label: "riskell.usage.logs", qos: .utility)
    private let limits = ClaudeLimitsClient()
    private var localURL: URL { env.cache.appendingPathComponent("usage-claude-local-v1.json") }
    private var limitsURL: URL { env.cache.appendingPathComponent("usage-claude-limits-v1.json") }
    private var opencodeURL: URL { env.cache.appendingPathComponent("usage-opencode-v1.json") }

    init(env: Env) { self.env = env }

    /// Loads the cached readings of the providers that are on (marked stale), then computes now and every 5 minutes (the first firing
    /// is immediate). Returns the closure that stops it: the poll, and the watch on config.json.
    func start() -> () -> Void {
        if UsageConfig.claudeOn(env.config) {
            let url = UsageConfig.claudeLimitsOn(env.config) ? limitsURL : localURL
            if var c = load(ClaudeUse.self, url) { c.stale = true; state.set(claude: c) }
        }
        if UsageConfig.opencode(env.config) != nil, var o = load(OCUse.self, opencodeURL) { o.stale = true; state.set(opencode: o) }
        let stopPoll = env.repeating(.seconds(300)) { [weak self] in self?.refresh() }
        providers = env.config.$json
            .map { ($0["usage"] as? [String: Any]) ?? [:] }
            .removeDuplicates { NSDictionary(dictionary: $0).isEqual(to: $1) }
            .dropFirst()
            .sink { [weak self] _ in self?.reconfigure() }
        return { [self] in stopPoll(); providers?.cancel(); providers = nil }
    }

    /// The `usage` section changed in config.json: drop the readings that are now off, compute again what is on.
    private func reconfigure() {
        if !UsageConfig.claudeOn(env.config) { state.set(claude: nil) }
        if UsageConfig.opencode(env.config) == nil { state.set(opencode: nil) }
        refresh()
    }

    /// Computes each provider that is on. Nothing runs for a provider that is off.
    func refresh() {
        if UsageConfig.claudeOn(env.config) { refreshClaude() }
        if let oc = UsageConfig.opencode(env.config) { refreshOpenCode(oc) }
    }

    /// The local logs on the background queue. With `claudeLimits` on, the real limits are requested next; their failure shows the local reading, stale.
    private func refreshClaude() {
        let limitsOn = UsageConfig.claudeLimitsOn(env.config)
        let fiveLimit = env.config.number("usage.fiveHourTokens"), sevenLimit = env.config.number("usage.sevenDayTokens")
        work.async { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            let items = ClaudeLogs.scan(roots: ClaudeLogs.roots(), now: now, cache: &self.files)
            let local = ClaudeLogs.summarize(events: ClaudeLogs.dedupe(items), now: now, fiveLimit: fiveLimit, sevenLimit: sevenLimit)
            guard limitsOn else {
                DispatchQueue.main.async {
                    guard UsageConfig.claudeOn(self.env.config), !UsageConfig.claudeLimitsOn(self.env.config) else { return }
                    self.state.set(claude: local)
                    self.save(local, to: self.localURL)
                }
                return
            }
            self.limits.fetch { r in
                DispatchQueue.main.async {
                    guard UsageConfig.claudeLimitsOn(self.env.config) else { return }
                    if let r {
                        self.state.set(claude: r)
                        self.save(r, to: self.limitsURL)
                    } else {
                        var s = local
                        s.stale = true
                        self.state.set(claude: s)
                    }
                }
            }
        }
    }

    private func refreshOpenCode(_ s: OpenCodeSettings) {
        OpenCodeClient.fetch(s) { [weak self] r in
            DispatchQueue.main.async {
                guard let self, UsageConfig.opencode(self.env.config) != nil else { return }
                if let r {
                    self.state.set(opencode: r)
                    self.save(r, to: self.opencodeURL)
                } else if var c = self.state.opencode {
                    c.stale = true
                    self.state.set(opencode: c)
                }
            }
        }
    }

    private func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func save<T: Encodable>(_ v: T, to url: URL) {
        if let d = try? JSONEncoder().encode(v) { try? d.write(to: url, options: .atomic) }
    }
}
