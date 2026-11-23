import Foundation
import RiskellKit
import RiskellTTY

/// The settings that would act on the same 3-finger touches riskell's gestures read: macOS's own trackpad gestures, the Dock's Mission
/// Control and App Expose gestures, and the window manager's (`WindowManager.gestureConflicts`). This part only READS, with CFPreferences
/// (no `defaults` process). `current()` is what Compat shows as `FIX · gesture:` pills while gestures are "riskell". The consented writes
/// are `--gestures-fix` and `--gestures-restore`, and `risk gestures status|fix|restore` draw their screens with the terminal kit.
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

    // MARK: the screens: `risk gestures status|fix|restore`, drawn with the kit (Sources/RiskellTTY)

    /// One conflicting key as a screen shows it: the domain it lives in, its key, the pill label, and the value it has now.
    struct Conflict { let domain: String; let key: String; let label: String; let value: NSNumber? }

    /// One line of a screen: the tone (the kit's, not the atom kit's own `Tone`), the key column, the value, and an optional command.
    typealias Row = (RiskellTTY.Tone, String, String, (cmd: String, note: String?)?)

    /// The terminal the kit draws on: this is the app that owns the theme, so one helper (main.swift) answers for every screen.
    static func screen() -> Tty { terminal() }

    // MARK: the consented writes, from the command line only: `riskell --gestures-fix --yes` and `--gestures-restore --yes`.
    // Without --yes both print a dry run and write nothing. `--status` is the read-only form `risk gestures status` uses, and it never
    // writes whatever else is on the command line. The originals are saved before the first write.

    /// One preference to write: its domain (as read or written, suffix included), its key, the value now and the value it becomes (nil: removed).
    struct Change { let domain: String; let key: String; let now: NSNumber?; let to: NSNumber? }

    /// Where the originals are kept. RISKELL_GESTURE_BACKUP points a test at its own file.
    static var backupURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISKELL_GESTURE_BACKUP"] ?? NSHomeDirectory() + "/.config/riskell/gesture-backup.json")
    }

    /// A path as a screen reads it: `~/...` under the home folder, absolute everywhere else (the rule `risk config path` uses too).
    static func shownPath(_ path: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let normal = URL(fileURLWithPath: home).standardized.path
        if path == normal { return "~" }
        if path.hasPrefix(normal + "/") { return "~/" + String(path.dropFirst(normal.count + 1)) }
        return path
    }

    /// main.swift calls this first: true when `args` asked for one of these commands (then the app exits without starting anything).
    static func runCommand(_ args: [String]) -> Bool {
        let statusOnly = args.contains("--status")
        let yes = args.contains("--yes") && !statusOnly && !args.contains("--dry-run")
        let restartDock = args.contains("--restart-dock")
        if args.contains("--gestures-fix") {
            if statusOnly { status(json: args.contains("--json")) } else { fix(yes: yes, restartDock: restartDock) }
            return true
        }
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

    /// Every conflicting key now, with what it means: what `status` lists and what `status --json` reports.
    static func currentConflicts() -> [Conflict] {
        var out: [Conflict] = []
        for s in system {
            for d in s.domains {
                let dom = domain(d), v = read(dom, s.key)
                if s.conflicts(v) { out.append(Conflict(domain: dom, key: s.key, label: s.label, value: v as? NSNumber)) }
            }
        }
        return out
    }

    static func show(_ v: NSNumber?) -> String { v.map { "\($0)" } ?? "unset" }      // trackpad values print as 0 / 2, the Dock's as 0 / 1

    /// `risk gestures status`: one crit row per conflicting key, or one ok row when nothing conflicts. Read-only, always.
    static func status(json: Bool) {
        let conflicts = currentConflicts()
        if json {
            print(jsonLine(conflicts))
            return
        }
        let t = screen()
        var lines = statusScreen(t, conflicts)
        if !conflicts.isEmpty { lines.append(t.next(cmd: "risk gestures fix", why: "turn the keys above off (it shows them first)")) }
        print(lines.joined(separator: "\n"))
    }

    /// One row per conflicting key: the gesture it is, the value it has now, and the trackpad or the Dock it lives in. On a narrow screen
    /// the "macOS " the label already says goes, so the value keeps its room. The key itself is in the dry run and in `--json`.
    static func statusScreen(_ t: Tty, _ conflicts: [Conflict]) -> [String] {
        guard !conflicts.isEmpty else { return t.checks([(.ok, "gestures", "nothing conflicts", nil)]) }
        let narrow = t.contentWidth < 60
        let rows: [Row] = conflicts.map { c in
            let label = narrow ? c.label.replacingOccurrences(of: "macOS ", with: "") : c.label
            return (.crit, label, "\(show(c.value)) · \(shortDomain(c.domain))", nil)
        }
        return t.checks(rows)
    }

    /// A domain as a screen names it: which trackpad the key is in, or that it is the Dock's.
    static func shortDomain(_ d: String) -> String {
        if d.hasPrefix("com.apple.driver.") { return "bluetooth" }
        if d.hasPrefix("com.apple.AppleMultitouchTrackpad") { return "built-in" }
        if d.hasPrefix(dockDomain) { return "dock" }
        return d
    }

    /// The `--json` shape a script reads: the conflicts in order, then whether there are none. One line, no colour, whatever the terminal.
    static func jsonLine(_ conflicts: [Conflict]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let items = conflicts.map { "{\"domain\":\(q($0.domain)),\"key\":\(q($0.key)),\"value\":\($0.value.map { "\($0)" } ?? "null")}" }
        return "{\"conflicts\":[" + items.joined(separator: ",") + "],\"ok\":\(conflicts.isEmpty)}"
    }

    /// A dry run in the kit's shape: the verb `set`, the domain and key, the value now and the value it becomes, and what was not written.
    static func planScreen(_ t: Tty, _ changes: [Change], restore: Bool, backup: String = backupURL.path,
                           now: ((Change) -> NSNumber?)? = nil) -> [String] {
        let rows = changes.map { c -> (verb: String, text: String) in
            let value = now?(c) ?? (restore ? (read(c.domain, c.key) as? NSNumber) : c.now)
            return (verb: "set", text: "\(c.domain) \(c.key): \(show(value)) -> \(show(c.to))")
        }
        return t.plan(rows, note: "dry run, nothing written; add --yes to write (originals are saved to \(shownPath(backup)))")
    }

    static func fix(yes: Bool, restartDock: Bool) {
        let t = screen()
        let changes = fixPlan()
        guard !changes.isEmpty else {
            print(t.checks([(.ok, "gestures", "nothing conflicts", nil)]).joined(separator: "\n"))
            return
        }
        guard yes else {
            print(planScreen(t, changes, restore: false).joined(separator: "\n"))
            return
        }
        // a backup that is still there holds the real originals: writing again would lose them, so refuse
        if FileManager.default.fileExists(atPath: backupURL.path) {
            failScreen(t, "a backup already exists", "\(shownPath(backupURL.path)) holds the originals of an earlier fix; writing again would lose them",
                       [(cmd: "risk gestures restore --yes", note: "put the originals back first")])
        }
        guard saveBackup(changes) else { failScreen(t, "could not save the backup", "nothing was changed", [(cmd: "risk gestures fix", note: "try again")]) }
        apply(changes)
        let dock = changes.contains { $0.domain.hasPrefix(dockDomain) }
        let restarted = dock && restartDock && !isTestDomain
        if restarted { restartDockNow() }
        print(t.checks(wroteRows(t, changes, backup: shownPath(backupURL.path), dock: dock, restartDock: restartDock, restarted: restarted))
            .joined(separator: "\n"))
        if let advice = restartAdvice(t, dock: dock, restartDock: restartDock) {
            print(t.next(cmd: advice.cmd, why: advice.why))
        }
    }

    static func restore(yes: Bool, restartDock: Bool) {
        let t = screen()
        guard let changes = loadBackup() else {
            print(t.checks([(.note, "gestures", "no backup at \(shownPath(backupURL.path)), nothing to restore", nil)]).joined(separator: "\n"))
            return
        }
        guard yes else {
            print(planScreen(t, changes, restore: true).joined(separator: "\n"))
            return
        }
        let before = changes.map { read($0.domain, $0.key) as? NSNumber }
        apply(changes)
        try? FileManager.default.removeItem(at: backupURL)
        let dock = changes.contains { $0.domain.hasPrefix(dockDomain) }
        let restarted = dock && restartDock && !isTestDomain
        if restarted { restartDockNow() }
        var rows = restoredRows(t, changes, before: before)
        if dock, restarted { rows.append((.ok, "Dock", "restarted, so its gestures take effect now", nil)) }
        print(t.checks(rows).joined(separator: "\n"))
        if let advice = restartAdvice(t, dock: dock, restartDock: restartDock) {
            print(t.next(cmd: advice.cmd, why: advice.why))
        }
    }

    // MARK: after a write

    /// What a fix that wrote prints: the backup it saved, one row per key changed, the trackpad note, and the Dock restarted when
    /// `--restart-dock` asked for it. Drawn from the data, so the shapes can be recorded without writing anything.
    static func wroteRows(_ t: Tty, _ changes: [Change], backup: String, dock: Bool, restartDock: Bool, restarted: Bool) -> [Row] {
        let narrow = t.contentWidth < 60
        var rows: [Row] = narrow ? [] : [(.ok, "backup", backup, nil)]
        rows += changes.map { (.ok, keyColumn(t, $0), "\(show($0.now)) -> \(show($0.to))" + (narrow ? "" : " · \(shortDomain($0.domain))"), nil) }
        if !narrow, changes.contains(where: isTrackpad) {
            rows.append((.note, "logout", "the trackpad settings may need a logout before macOS acts on them", nil))
        }
        if dock, restartDock, restarted { rows.append((.ok, "Dock", "restarted, so its gestures take effect now", nil)) }
        return rows
    }

    static func restoredRows(_ t: Tty, _ changes: [Change], before: [NSNumber?]) -> [Row] {
        guard t.contentWidth >= 60 else {
            return changes.enumerated().map { (.ok, keyColumn(t, $0.element), "\(show(before[$0.offset])) -> \(show($0.element.to))", nil) }
        }
        var rows: [Row] = [(.ok, "backup", "restored and removed", nil)]
        rows += changes.enumerated().map { (.ok, keyColumn(t, $0.element), "\(show(before[$0.offset])) -> \(show($0.element.to)) · \(shortDomain($0.element.domain))", nil) }
        if changes.contains(where: isTrackpad) {
            rows.append((.note, "logout", "the trackpad settings may need a logout before macOS acts on them", nil))
        }
        return rows
    }

    /// The key column of a row about one preference: the label a person knows, not the key macOS stores (which the dry run prints). On a
    /// narrow screen the "macOS " the label already says goes, so the value keeps its room.
    static func keyColumn(_ t: Tty, _ c: Change) -> String {
        let label = label(for: c)
        return t.contentWidth < 60 ? label.replacingOccurrences(of: "macOS ", with: "") : label
    }

    /// The label of the preference a change touches, from the same table the checks read.
    static func label(for c: Change) -> String { label(forKey: c.key, in: c.domain) }

    static func label(forKey key: String, in domain: String) -> String {
        let setting = system.first { $0.key == key && $0.domains.contains { domain.hasPrefix($0) } } ?? system.first { $0.key == key }
        return setting?.label ?? key
    }

    static func isTrackpad(_ c: Change) -> Bool { trackpadDomains.contains { c.domain.hasPrefix($0) } }

    /// `killall Dock`, only after a write and only with --restart-dock, and never for a test domain (which has no Dock behind it).
    static func restartDockNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run(); p.waitUntilExit()
    }

    /// The one thing to do next when the Dock's keys changed and it was not restarted. The command is `killall Dock` rather than a second
    /// `--restart-dock` run: once the keys are off the second run finds nothing to change, so it would never reach the restart.
    static func restartAdvice(_ t: Tty, dock: Bool, restartDock: Bool) -> (cmd: String, why: String)? {
        guard dock, isTestDomain || !restartDock else { return nil }
        return ("killall Dock", t.contentWidth < 60 ? "restart the Dock" : "the Dock reads its gestures when it starts")
    }

    static var isTestDomain: Bool { !(ProcessInfo.processInfo.environment["RISKELL_PREFS_SUFFIX"] ?? "").isEmpty }

    /// A refusal in the kit's error shape, on stderr, with the exit code 1 these commands already used.
    static func failScreen(_ t: Tty, _ title: String, _ detail: String?, _ tries: [(cmd: String, note: String)]) -> Never {
        FileHandle.standardError.write(Data((t.errorBlock(title: title, detail: detail, tries: tries).joined(separator: "\n") + "\n").utf8))
        exit(1)
    }

    // MARK: the screens from fixed data, for the recordings

    /// `riskell --gestures-test`: the three gestures screens drawn from fixed data, so the shapes are recorded without reading or writing a
    /// preference. Nothing here touches CFPreferences or the Disk.
    static func testScreen() {
        let t = screen()
        let conflicts = [
            Conflict(domain: "com.apple.AppleMultitouchTrackpad", key: "TrackpadThreeFingerHorizSwipeGesture",
                     label: "macOS 3-finger horizontal swipe", value: NSNumber(value: 2)),
            Conflict(domain: "com.apple.dock", key: "showMissionControlGestureEnabled",
                     label: "macOS Mission Control gesture", value: NSNumber(value: true)),
        ]
        let changes = [
            Change(domain: "com.apple.AppleMultitouchTrackpad", key: "TrackpadThreeFingerHorizSwipeGesture",
                   now: NSNumber(value: 2), to: NSNumber(value: 0)),
            Change(domain: "com.apple.dock", key: "showMissionControlGestureEnabled",
                   now: NSNumber(value: true), to: NSNumber(value: false)),
        ]
        // What restore would put back: the same keys, the other way round, with the value each has now.
        let restoring = [
            Change(domain: "com.apple.AppleMultitouchTrackpad", key: "TrackpadThreeFingerHorizSwipeGesture",
                   now: NSNumber(value: 0), to: NSNumber(value: 2)),
            Change(domain: "com.apple.dock", key: "showMissionControlGestureEnabled",
                   now: NSNumber(value: false), to: NSNumber(value: true)),
        ]
        let backup = "~/.config/riskell/gesture-backup.json"
        // The screen a writing fix prints, drawn from the same data: nothing here writes or restarts anything.
        let wrote = t.checks(wroteRows(t, changes, backup: backup, dock: true, restartDock: false, restarted: false))
            + [t.next(cmd: "killall Dock", why: t.contentWidth < 60 ? "restart the Dock" : "the Dock reads its gestures when it starts")]
        var out: [String] = []
        for (name, body) in [("status", statusScreen(t, conflicts)), ("status, nothing conflicting", statusScreen(t, [])),
                             ("fix --dry-run", planScreen(t, changes, restore: false, backup: backup)),
                             ("fix --yes", wrote),
                             ("restore --dry-run", planScreen(t, restoring, restore: true, backup: backup, now: { $0.now }))] {
            if !out.isEmpty { out.append("") }
            out.append("  " + t.dim("-- \(name) --"))
            out += body
        }
        out.append("")
        out.append("  " + t.dim("-- status --json --"))
        out.append("  " + jsonLine(conflicts))
        print(out.joined(separator: "\n"))
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
            let tty = screen()
            let lines = tty.errorBlock(title: "the gesture backup could not be written", detail: error.localizedDescription,
                                       tries: [(cmd: "risk gestures fix --dry-run", "see what it would write, and where")])
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            return false
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

}
