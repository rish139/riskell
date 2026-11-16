import Foundation
import RiskellKit

/// An optional part of riskell. It starts only when config.json asks for it (`Extensions.apply`) and is torn down when the config turns
/// it off. A stopped extension holds no event tap, no device registration, no timer and no observer: off means nothing runs.
protocol RiskellExtension: AnyObject {
    static var id: String { get }
    init()
    func start()
    func stop()
}

/// The extensions riskell has, and which of them the config turns on. `apply` is idempotent: the same config twice does nothing.
enum Extensions {
    /// Every extension riskell has. Adding one is adding it here and a case in `wanted`.
    static let available: [any RiskellExtension.Type] = [GesturesExtension.self]

    /// The extensions running now, by id.
    private static var running: [String: any RiskellExtension] = [:]
    private static var reported: String?

    /// Whether the config asks for the extension `id` to run. The config's values are read here and nowhere else.
    static func wanted(_ id: String, _ config: AppConfig) -> Bool {
        switch id {
        case GesturesExtension.id: return config.gestures == "riskell"
        default: return false
        }
    }

    /// Starts the extensions the config wants and stops the ones it no longer wants. Called at launch and on every config change.
    static func apply(_ config: AppConfig) {
        for t in available {
            let id = t.id
            if wanted(id, config) {
                if running[id] == nil { let e = t.init(); running[id] = e; e.start() }
            } else if let e = running.removeValue(forKey: id) {
                e.stop()
            }
        }
        if report() { Compat.shared.check() }      // the gesture pills follow what runs (no timer: a config change is the trigger)
    }

    /// Shutdown: every running extension is stopped.
    static func stopAll() {
        let all = Array(running.values)
        running = [:]
        for e in all { e.stop() }
    }

    /// One log line whenever the set of running extensions changes (also the first time, so a dump shows what is on). true when it changed.
    private static func report() -> Bool {
        let line = available.map { "\($0.id) \(running[$0.id] == nil ? "off" : "on")" }.joined(separator: ", ")
        guard line != reported else { return false }
        reported = line
        print("extensions: \(line)"); fflush(stdout)
        return true
    }
}
