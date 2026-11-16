import Foundation
import RiskellKit

/// The settings that would act on the same 3-finger touches riskell's gestures read: macOS's own trackpad gestures, the Dock's Mission
/// Control and App Expose gestures, and the window manager's (`WindowManager.gestureConflicts`). This part only READS, with CFPreferences
/// (no `defaults` process). `current()` is what Compat shows as `FIX · gesture:` pills while gestures are "riskell". The consented writes
/// are `--gestures-fix` and `--gestures-restore` (below).
/// RISKELL_PREFS_SUFFIX is appended to every domain name, so a test reads and writes throwaway domains and never the real ones.
enum GestureConflicts {
    static let trackpadDomains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    static let dockDomain = "com.apple.dock"

    /// One setting that can conflict: where it lives, its key, the pill label, whether a value conflicts, and the value a fix writes.
    struct Setting {
        let domains: [String]
        let key: String
        let label: String
        let conflicts: (Any?) -> Bool
        let off: NSNumber
    }

    /// The trackpad keys: any non-zero value turns a gesture on. The Dock keys: true turns the gesture on.
    /// A key that is absent is not a conflict (macOS then uses its own default, which this check does not know).
    static let system: [Setting] = [
        Setting(domains: trackpadDomains, key: "TrackpadThreeFingerHorizSwipeGesture", label: "macOS 3-finger horizontal swipe", conflicts: nonZero, off: NSNumber(value: 0)),
        Setting(domains: trackpadDomains, key: "TrackpadThreeFingerVertSwipeGesture", label: "macOS 3-finger vertical swipe", conflicts: nonZero, off: NSNumber(value: 0)),
        Setting(domains: trackpadDomains, key: "TrackpadFourFingerHorizSwipeGesture", label: "macOS 4-finger horizontal swipe", conflicts: nonZero, off: NSNumber(value: 0)),
        Setting(domains: trackpadDomains, key: "TrackpadFourFingerVertSwipeGesture", label: "macOS 4-finger vertical swipe", conflicts: nonZero, off: NSNumber(value: 0)),
        Setting(domains: [dockDomain], key: "showMissionControlGestureEnabled", label: "macOS Mission Control gesture", conflicts: isTrue, off: NSNumber(value: false)),
        Setting(domains: [dockDomain], key: "showAppExposeGestureEnabled", label: "macOS App Expose gesture", conflicts: isTrue, off: NSNumber(value: false)),
    ]

    static func nonZero(_ v: Any?) -> Bool { ((v as? NSNumber)?.intValue ?? 0) != 0 }
    static func isTrue(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? false }

    /// The domain a name refers to: the real one, or the test one with RISKELL_PREFS_SUFFIX appended.
    static func domain(_ name: String) -> String { name + (ProcessInfo.processInfo.environment["RISKELL_PREFS_SUFFIX"] ?? "") }

    /// The value for `key` in `domain` (any host, the user's), nil when unset.
    static func read(_ domain: String, _ key: String) -> Any? {
        CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as Any?
    }

    /// The conflicts found now, as pill labels: macOS's settings first, then the window manager's own.
    static func current() -> [String] {
        var out: [String] = []
        for s in system where s.domains.contains(where: { s.conflicts(read(domain($0), s.key)) }) { out.append(s.label) }
        return out + (WM.shared?.gestureConflicts ?? [])
    }

    // MARK: the consented writes, from the command line only: `riskell --gestures-fix --yes` and `riskell --gestures-restore --yes`.
    // Without --yes both print what they would do and write nothing. The originals are saved before the first write.

    /// One preference to write: its domain (as read or written, suffix included), its key, the value now and the value it becomes (nil: removed).
    struct Change { let domain: String; let key: String; let now: NSNumber?; let to: NSNumber? }

    /// Where the originals are kept. RISKELL_GESTURE_BACKUP points a test at its own file.
    static var backupURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISKELL_GESTURE_BACKUP"] ?? NSHomeDirectory() + "/.config/riskell/gesture-backup.json")
    }

    /// main.swift calls this first: true when `args` asked for one of these commands (then the app exits without starting anything).
    static func runCommand(_ args: [String]) -> Bool {
        let yes = args.contains("--yes"), restartDock = args.contains("--restart-dock")
        if args.contains("--gestures-fix") { fix(yes: yes, restartDock: restartDock); return true }
        if args.contains("--gestures-restore") { restore(yes: yes, restartDock: restartDock); return true }
        return false
    }

    /// Every conflicting setting, in every domain it is found in, with the value the fix writes (`off`).
    static func fixPlan() -> [Change] {
        var plan: [Change] = []
        for s in system {
            for d in s.domains {
                let dom = domain(d), v = read(dom, s.key)
                if s.conflicts(v) { plan.append(Change(domain: dom, key: s.key, now: v as? NSNumber, to: s.off)) }
            }
        }
        return plan
    }

    static func show(_ v: NSNumber?) -> String { v.map { "\($0)" } ?? "unset" }      // trackpad values print as 0 / 2, the Dock's as 0 / 1

    static func fix(yes: Bool, restartDock: Bool) {
        let changes = fixPlan()
        guard !changes.isEmpty else { print("gestures: nothing conflicts, nothing to change"); return }
        for c in changes { print("\(yes ? "set" : "would set") \(c.domain) \(c.key): \(show(c.now)) -> \(show(c.to))") }
        guard yes else { print("gestures: dry run, nothing written (add --yes to write; the originals are saved to \(backupURL.path))"); return }
        // a backup that is still there holds the real originals: writing again would lose them, so refuse
        if FileManager.default.fileExists(atPath: backupURL.path) { print("gestures: a backup already exists at \(backupURL.path); run --gestures-restore --yes first"); exit(1) }
        guard saveBackup(changes) else { print("gestures: could not save the backup, nothing changed"); exit(1) }
        apply(changes)
        print("gestures: originals saved to \(backupURL.path)")
        finish(dock: changes.contains { $0.domain.hasPrefix(dockDomain) }, restartDock: restartDock)
    }

    static func restore(yes: Bool, restartDock: Bool) {
        guard let changes = loadBackup() else { print("gestures: no backup at \(backupURL.path), nothing to restore"); return }
        for c in changes { print("\(yes ? "restore" : "would restore") \(c.domain) \(c.key) -> \(show(c.to))") }
        guard yes else { print("gestures: dry run, nothing written (add --yes to restore the values above)"); return }
        apply(changes)
        try? FileManager.default.removeItem(at: backupURL)
        print("gestures: restored, backup removed")
        finish(dock: changes.contains { $0.domain.hasPrefix(dockDomain) }, restartDock: restartDock)
    }

    /// Writes the values (CFPreferences, the user's domains, any host) and makes them readable at once.
    static func apply(_ changes: [Change]) {
        for c in changes { CFPreferencesSetValue(c.key as CFString, c.to, c.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
        for d in Set(changes.map(\.domain)) { CFPreferencesSynchronize(d as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
    }

    /// The originals as JSON: [{"domain", "key", "original"}], original null when the key was unset.
    static func saveBackup(_ changes: [Change]) -> Bool {
        let entries: [[String: Any]] = changes.map { ["domain": $0.domain, "key": $0.key, "original": $0.now ?? NSNull()] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["entries": entries], options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: backupURL, options: .atomic)
            return true
        } catch {
            print("gestures: \(error.localizedDescription)"); return false
        }
    }

    /// The backup as changes that put the originals back (`to` = the original, nil when it was unset).
    static func loadBackup() -> [Change]? {
        guard let d = try? Data(contentsOf: backupURL), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let entries = obj["entries"] as? [[String: Any]] else { return nil }
        return entries.compactMap { e in
            guard let dom = e["domain"] as? String, let key = e["key"] as? String else { return nil }
            return Change(domain: dom, key: key, now: nil, to: e["original"] as? NSNumber)
        }
    }

    /// After a write: the Dock reads its gestures when it starts, the trackpad may need a logout. `killall Dock` only with --restart-dock,
    /// and never for a test domain (RISKELL_PREFS_SUFFIX), which has no Dock behind it.
    static func finish(dock: Bool, restartDock: Bool) {
        let test = !(ProcessInfo.processInfo.environment["RISKELL_PREFS_SUFFIX"] ?? "").isEmpty
        if dock && restartDock && !test {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["Dock"]
            try? p.run(); p.waitUntilExit()
            print("gestures: Dock restarted")
        } else if dock {
            print("gestures: the Dock reads its gestures when it starts: restart it (killall Dock, or --restart-dock)")
        }
        print("gestures: the trackpad settings may need a logout before macOS acts on them")
    }
}
