import Foundation

/// Which built-in services run. One rule: a service runs only while an atom that needs it is placed on a bar that is on. Nothing else
/// starts it, so an atom that is not placed costs nothing (no timer, no listener, no permission prompt). Placing or removing an atom,
/// or switching a bar, calls `apply()`, which starts what is newly needed and stops what is not.
///
/// The table below is the whole list; a service that is not in it (the window manager, the notch wings' media feed, the cards' own
/// live feeds, which already start and stop with their card) is not gated by an atom.
enum Needs {
    /// Which atoms need which service. The whole list in one place; main.swift gives each service its start and stop.
    static let table: [String: Set<String>] = [
        "sys": ["vol"],      // the battery, the volume and the microphone (a feed subscriber also keeps it running)
        "wifi": ["net"],                          // also the Location prompt for Wi-Fi names
    ]
    private struct Rule { let start: () -> Void; let stop: () -> Void }
    private static var rules: [String: Rule] = [:]
    private static var running: Set<String> = []
    private static var holds: [String: Int] = [:]      // feed subscribers: an extension subscribed to a feed keeps its service running
    private static var armed = false      // off until main has registered the rules

    static func register(_ name: String, start: @escaping () -> Void, stop: @escaping () -> Void) {
        precondition(table[name] != nil, "Needs.table has no service \(name)")
        rules[name] = Rule(start: start, stop: stop)
    }

    static func isRunning(_ name: String) -> Bool { running.contains(name) }

    /// A feed subscriber needs `name` for as long as it is subscribed; call the returned closure when it leaves. Main thread.
    static func hold(_ name: String) -> () -> Void {
        holds[name, default: 0] += 1
        apply()
        var done = false
        return { if !done { done = true; holds[name, default: 1] -= 1; apply() } }
    }

    /// Main calls this once, after registering every rule.
    static func begin() { armed = true; apply() }

    /// Compare what is placed with what runs. Cheap (a few set tests), so every layout change may call it.
    static func apply() {
        guard armed else { return }
        let placed = Config.shared.placedAtoms
        for (name, rule) in rules {
            let want = !(table[name] ?? []).isDisjoint(with: placed) || (holds[name] ?? 0) > 0
            if want, !running.contains(name) { running.insert(name); rule.start() }
            else if !want, running.contains(name) { running.remove(name); rule.stop() }
        }
    }

    /// The services that run for an atom (for the listings: which service starts when it is placed).
    static func services(for atom: String) -> [String] { table.filter { $0.value.contains(atom) }.map(\.key).sorted() }

    /// For --dump and tests: the services that run right now.
    static var active: [String] { running.sorted() }
}
