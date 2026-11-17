import Foundation

/// Which built-in services run. One rule: a service runs only while an atom that needs it is placed on a bar that is on. Nothing else
/// starts it, so an atom that is not placed costs nothing (no timer, no listener, no permission prompt). Placing or removing an atom,
/// or switching a bar, calls `apply()`, which starts what is newly needed and stops what is not.
///
/// The table below is the whole list; a service that is not in it (the window manager, the notch wings' media feed, the cards' own
/// live feeds, which already start and stop with their card) is not gated by an atom.
enum Needs {
    private struct Rule { let atoms: Set<String>; let start: () -> Void; let stop: () -> Void }
    private static var rules: [String: Rule] = [:]
    private static var running: Set<String> = []
    private static var armed = false      // off until main has registered the rules

    static func register(_ name: String, atoms: Set<String>, start: @escaping () -> Void, stop: @escaping () -> Void) {
        rules[name] = Rule(atoms: atoms, start: start, stop: stop)
    }

    static func isRunning(_ name: String) -> Bool { running.contains(name) }

    /// Main calls this once, after registering every rule.
    static func begin() { armed = true; apply() }

    /// Compare what is placed with what runs. Cheap (a few set tests), so every layout change may call it.
    static func apply() {
        guard armed else { return }
        let placed = Config.shared.placedAtoms
        for (name, rule) in rules {
            let want = !rule.atoms.isDisjoint(with: placed)
            if want, !running.contains(name) { running.insert(name); rule.start() }
            else if !want, running.contains(name) { running.remove(name); rule.stop() }
        }
    }

    /// For --dump and tests: the services that run right now.
    static var active: [String] { running.sorted() }
}
