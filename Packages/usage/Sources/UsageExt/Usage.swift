// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import Combine
import RiskellKit

/// Claude usage, computed in-process from the local session logs (see `ClaudeLogs`). Opt-in through config.json (`usage.claude`).
/// The last result is cached (only its numbers) and shown dimmed until the first fresh one of this launch.
final class UsageService {
    private let env: Env
    private let state = UsageState.shared
    private var providers: AnyCancellable?
    /// The log files parsed so far, by path. Touched only on `work`.
    private var files: [String: ClaudeLogs.Cached] = [:]
    private let work = DispatchQueue(label: "riskell.usage.logs", qos: .utility)
    private var cacheURL: URL { env.cache.appendingPathComponent("usage-claude-local-v1.json") }

    init(env: Env) { self.env = env }

    /// Loads the cached reading (marked stale), then computes now and every 5 minutes (the first firing is immediate). Returns the closure
    /// that stops it: the poll, and the watch on config.json.
    func start() -> () -> Void {
        if var c = (try? Data(contentsOf: cacheURL)).flatMap({ try? JSONDecoder().decode(ClaudeUse.self, from: $0) }) {
            c.stale = true
            state.set(claude: c)
        }
        let stopPoll = env.repeating(.seconds(300)) { [weak self] in self?.refresh() }
        providers = env.config.$json
            .map { ($0["usage"] as? [String: Any]) ?? [:] }
            .removeDuplicates { NSDictionary(dictionary: $0).isEqual(to: $1) }
            .dropFirst()
            .sink { [weak self] _ in self?.reconfigure() }
        return { [self] in stopPoll(); providers?.cancel(); providers = nil }
    }

    /// The `usage` section changed in config.json: drop the reading if it is now off, compute again if it is on.
    private func reconfigure() {
        if !UsageConfig.claudeOn(env.config) { state.set(claude: nil) }
        refresh()
    }

    /// Reads the logs on the background queue; the result is published on the main queue and saved beside the cache.
    func refresh() {
        guard UsageConfig.claudeOn(env.config) else { return }
        let fiveLimit = env.config.number("usage.fiveHourTokens"), sevenLimit = env.config.number("usage.sevenDayTokens")
        work.async { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            let items = ClaudeLogs.scan(roots: ClaudeLogs.roots(), now: now, cache: &self.files)
            let r = ClaudeLogs.summarize(events: ClaudeLogs.dedupe(items), now: now, fiveLimit: fiveLimit, sevenLimit: sevenLimit)
            try? JSONEncoder().encode(r).write(to: self.cacheURL)
            DispatchQueue.main.async { self.state.set(claude: r) }
        }
    }
}
