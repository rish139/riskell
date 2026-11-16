import AppKit
import SwiftUI
import RiskellKit

/// The version tracker. riskell leans on things it does not own: private macOS APIs (SkyLight, MultitouchSupport, MediaRemote), OmniWM's
/// IPC and the OmniWM settings it was tuned against. Any of them can change under an update and break riskell quietly. This compares what
/// is running now with what riskell was last VERIFIED against (`Verified`, below) and shows a pill in the top bar's left zone while
/// anything differs. The pill is the reminder to re-run the checklist in docs/COMPATIBILITY.md and then bump `Verified`.
///
/// Checked at launch, whenever OmniWM (re)connects (an OmniWM update restarts it) and whenever its settings file changes. No timer.
final class Compat: ObservableObject {
    static let shared = Compat()

    /// WHAT RISKELL WAS LAST VERIFIED AGAINST. Bump these (and only these) after walking docs/COMPATIBILITY.md on the new version.
    enum Verified {
        static let macOS = "27.2 (26B123)"        // ProductVersion (BuildVersion)
        static let omniwm = "0.8.0"               // CFBundleShortVersionString of OmniWM.app
        /// OmniWM settings riskell depends on: "section.key" -> the value riskell needs. A mismatch is a FIX, not an update.
        static let omniwmSettings: [(key: String, want: String, why: String)] = [
            ("gestures.workspaceSwipeEnabled", "false", "riskell's Touch owns the 3-finger swipe; OmniWM's own would fight it"),
            ("general.ipcEnabled", "true", "riskell talks to OmniWM over its IPC socket"),
            ("gestures.scrollEnabled", "false", "OmniWM's scroll gestures would act on the same 3-finger touches"),
        ]
        /// gaps.outer.* are written by riskell itself (`Gaps`) from which bars are on; a mismatch means something else changed the file.
        static var gaps: [(key: String, want: String)] {
            let c = Config.shared
            return [("gaps.outer.top", Config.gapTop), ("gaps.outer.left", c.gapLeft), ("gaps.outer.right", c.gapRight), ("gaps.outer.bottom", c.gapBottom)]
                .map { ($0.0, String(format: "%.1f", Double($0.1))) }
        }
    }

    /// What needs attention, most important first. Empty = the pill is hidden.
    @Published private(set) var notes: [String] = []
    private(set) var running = (macOS: "", omniwm: "")

    static let settingsPath = NSHomeDirectory() + "/.config/omniwm/settings.toml"
    static var fake = false                      // --fake-compat: show the pill without a real mismatch (snapshots)

    private var watch: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    // MARK: what is running

    static func macOSNow() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var build = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &build, &size, nil, 0)
        let ver = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        return "\(ver) (\(String(cString: build)))"
    }

    static func omniwmNow() -> String? {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.barut.OmniWM") ?? URL(fileURLWithPath: "/Applications/OmniWM.app")
        return Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// OmniWM's settings as "section.key" -> raw value text (a tiny reader: this file is flat `key = value` under `[section]` headers).
    static func omniwmSettings() -> [String: String]? {
        guard let text = try? String(contentsOfFile: settingsPath, encoding: .utf8) else { return nil }
        var out: [String: String] = [:], section = ""
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[["), line.hasSuffix("]]") { section = "[[" + line.dropFirst(2).dropLast(2) + "]]"; continue }   // appRules etc.: never matched
            if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces), v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            out[(section.isEmpty ? "" : section + ".") + k] = v
        }
        return out
    }

    // MARK: checking

    func check() {
        var n: [String] = []
        let mac = Self.macOSNow(); running.macOS = mac
        if mac != Verified.macOS { n.append("UPDATE DUE · macOS \(mac.components(separatedBy: " ").first ?? mac)") }
        let omni = WM.shared?.name == "omniwm"          // the OmniWM checks apply only when OmniWM is the manager in use
        if omni, let om = Self.omniwmNow() {
            running.omniwm = om
            if om != Verified.omniwm { n.append("UPDATE DUE · OmniWM \(om)") }
        }
        // while gestures are riskell's, the two gesture keys are shown as gesture conflicts below, not as OmniWM FIX pills (no duplicate)
        let riskellGestures = AppConfig.shared.gestures == "riskell"
        if omni, let s = Self.omniwmSettings() {
            for e in Verified.omniwmSettings where s[e.key] != e.want && !(riskellGestures && e.key.hasPrefix("gestures.")) {
                n.append("FIX · OmniWM \(e.key.split(separator: ".").last ?? "") = \(s[e.key] ?? "missing")")
            }
            for e in Verified.gaps where s[e.key] != e.want {
                n.append("FIX · OmniWM \(e.key.split(separator: ".").last ?? "") gap = \(s[e.key] ?? "missing")")
            }
        }
        // gesture conflicts (Extensions/GestureConflicts.swift): what would fight riskell's own 3-finger gestures; read, never written here
        if riskellGestures { for c in GestureConflicts.current() { n.append("FIX · gesture: \(c)") } }
        if Self.fake { n.insert("UPDATE DUE · OmniWM 0.9.0", at: 0) }
        if n != notes { notes = n }
        for line in n { print("compat: \(line)") }
        fflush(stdout)
    }

    /// Launch: check now and watch the settings file (it is replaced, not rewritten, by most editors and by OmniWM, so the watch is re-armed each time).
    func start() {
        check()
        if WM.shared?.name == "omniwm" { arm() }
    }

    private func arm() {
        watch?.cancel(); watch = nil
        let fd = open(Self.settingsPath, O_EVTONLY)
        guard fd >= 0 else { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.arm() }; return }   // not there yet: look again shortly
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.debounce?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.check(); self?.arm() }
            self.debounce = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watch = src
    }

    var report: String {
        "compat: macOS \(running.macOS) (verified \(Verified.macOS)) | OmniWM \(running.omniwm) (verified \(Verified.omniwm)) | " + (notes.isEmpty ? "all as verified" : notes.joined(separator: "; "))
    }
}

/// The pill: the first thing that needs attention, and how many more there are. Not drawn at all while everything is as verified.
struct CompatAtom: View {
    @ObservedObject private var c = Compat.shared
    var body: some View {
        if let first = c.notes.first {
            HStack(spacing: 6) {
                Circle().fill(Pal.accent).frame(width: 6, height: 6)
                Text(first).font(Pal.font(11, .bold)).tracking(0.6).foregroundStyle(Pal.accent)
                if c.notes.count > 1 { Text("+\(c.notes.count - 1)").font(Pal.font(10)).foregroundStyle(Pal.text3) }
            }
        }
    }
}
