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

    /// A behaviour an installed package exports (`RiskellPackage.behaviours`), with the window manager it works with.
    private struct Installed {
        let id: String
        let manager: String?
        let type: any Behaviour.Type
    }

    /// A behaviour that is running, and what undoes its start.
    private struct Running {
        let behaviour: any Behaviour
        let undo: (() -> Void)?
    }

    /// The extensions running now, by id.
    private static var running: [String: any RiskellExtension] = [:]
    /// The behaviours of installed packages running now, by id.
    private static var behaviours: [String: Running] = [:]
    /// The behaviours the installed packages export, in package order: what the log line names, running or not.
    private static var known: [String] = []
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
        applyBehaviours()
        if report() { Compat.shared.check() }      // the gesture pills follow what runs (no timer: a config change is the trigger)
    }

    /// Shutdown: every extension is stopped.
    static func stopAll() {
        let all = Array(running.values)
        running = [:]
        for e in all { e.stop() }
        stopBehaviours()
    }

    /// A setting changed. A behaviour reads its settings in `start`, the one place it may, so it starts again to see them.
    static func settingsChanged() {
        stopBehaviours()
        applyBehaviours()
        _ = report()
    }

    // MARK: the behaviours of installed packages

    /// Starts the behaviours whose window manager is the one running, stops the others, and hands the manager hooks to the backend. A
    /// behaviour runs only while its package is installed and not disabled in config.json, and while riskell runs the manager it names.
    private static func applyBehaviours() {
        let installed = installedBehaviours()
        known = installed.map(\.id)
        // no window manager yet (the extension self-test runs before one is made): nothing may start
        let backend = WM.shared?.name.lowercased()
        let wanted = backend.map { name in installed.filter { $0.manager == nil || $0.manager?.lowercased() == name } } ?? []
        let ids = Set(wanted.map(\.id))
        let dropped = behaviours.filter { !ids.contains($0.key) }
        if !dropped.isEmpty {
            for id in dropped.keys { behaviours.removeValue(forKey: id) }
            publishHooks()          // before the undos: the backend must not call a behaviour that is about to stop
            for r in dropped.values { r.undo?() }
        }
        for b in wanted where behaviours[b.id] == nil {
            let behaviour = b.type.init()
            behaviours[b.id] = Running(behaviour: behaviour, undo: behaviour.start(ExtPrefs.env(b.id)))
        }
        publishHooks()
    }

    /// Stops every behaviour: the backend loses them first, so nothing it is about to send can reach one that is stopping.
    private static func stopBehaviours() {
        WM.shared?.setHooks([])
        let all = Array(behaviours.values)
        behaviours = [:]
        for r in all { r.undo?() }
    }

    /// The running behaviours that add to the manager's requests, in id order so the backend's list is stable.
    private static func publishHooks() {
        WM.shared?.setHooks(behaviours.keys.sorted().compactMap { behaviours[$0]?.behaviour as? ManagerHook })
    }

    /// What the installed packages export, skipping the ones config.json disables and any behaviour whose id is not plain or is taken.
    private static func installedBehaviours() -> [Installed] {
        let off = Set(AppConfig.shared.disabledExtensions ?? [])
        var seen = Set(available.map { $0.id }), out: [Installed] = []
        for p in InstalledPackages.all where !off.contains(p.id) {
            for t in p.package.behaviours {
                guard plainExtensionID(t.id), seen.insert(t.id).inserted else {
                    print("extensions: ignoring behaviour \"\(t.id)\" (needs a unique plain id)"); fflush(stdout)
                    continue
                }
                out.append(Installed(id: t.id, manager: t.manager, type: t))
            }
        }
        return out
    }

    /// One log line whenever the set of running extensions changes (also the first time, so a dump shows what is on). true when it changed.
    private static func report() -> Bool {
        let line = (available.map { "\($0.id) \(running[$0.id] == nil ? "off" : "on")" }
                    + known.map { "\($0) \(behaviours[$0] == nil ? "off" : "on")" }).joined(separator: ", ")
        guard line != reported else { return false }
        reported = line
        print("extensions: \(line)"); fflush(stdout)
        return true
    }
}
