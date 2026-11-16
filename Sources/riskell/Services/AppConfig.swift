import Foundation
import RiskellKit

/// Everything personal lives in ~/.config/riskell/config.json (riskell's own file, `RISKELL_CONFIG` points a second instance at another one);
/// nothing about a person or an account is in the source. A missing file or a missing key means "off": no weather location means no
/// weather requests, no workspace id means no OpenCode requests, `claude` defaults to false (reading a keychain item is opt-in).
/// The file is watched and applied live (see ConfigWatcher). Layout (bars and atoms) is a separate file, see Layout.swift.
///
///     { "wm": "auto",
///       "location": { "name": "Hamburg", "lat": 53.55, "lon": 10.00 },
///       "usage": { "claude": true,
///                  "opencode": { "workspace": "wrk_…", "profiles": "~/Library/Application Support/zen/Profiles" } } }
struct AppConfig: Codable, Equatable {
    /// The "command" window manager's commands: `state` prints one line of JSON; the actions run with {space} / {window} replaced by numbers.
    struct WMCommand: Codable, Equatable {
        var state: String?
        var focusSpace: String?
        var focusWindow: String?
        var closeWindow: String?
        var moveWindow: String?
        var every: Double?
    }
    struct Location: Codable, Equatable { var name: String?; var lat: Double; var lon: Double }
    struct OpenCode: Codable, Equatable {
        /// The Go workspace id (the `wrk_…` in the console URL). Empty or absent: OpenCode usage is off.
        var workspace: String?
        /// The Firefox-family profiles directory whose newest cookies.sqlite holds the console session.
        var profiles: String?
    }
    struct Usage: Codable, Equatable { var claude: Bool?; var opencode: OpenCode? }

    /// The window manager backend: "auto" (default), "omniwm", "yabai", "none" or "command" (CommandWM.swift, docs/WM-COMMAND.md).
    var wm: String?
    /// The commands of the "command" backend. Only `state` is needed; a change applies live.
    var wmCommand: WMCommand?
    /// The colour scheme id (a bundled Base16 scheme or a file in ~/.config/riskell/themes/); the layout editor's picker writes it.
    var theme: String?
    var location: Location?
    /// Script pills, see Pills.swift.
    var pills: [PillSpec]?
    var usage: Usage?
    /// The screen the bars go on: "auto" (default: the notched screen, else the main one), "main" or "primary" (Display.swift).
    var display: String?
    /// The layout scale (Scale.swift): absent = automatic from the bar's height. RISKELL_SCALE overrides it.
    var scale: Double?
    /// The 3-finger gestures (Extensions/GesturesExtension.swift): "riskell" runs riskell's own swipe and scroll guard; "system" (the default,
    /// also when absent) runs nothing and leaves the trackpad to macOS.
    var gestures: String?
    /// Ids of installed extensions that must not load (as `risk ext list` prints them; their atoms are not registered, none of their code runs). Read at launch: restart after
    /// changing it. This is the way back from an extension that misbehaves.
    var disabledExtensions: [String]?
    /// Edge gap, window gap and corner roundness (Spacing.swift); absent = the defaults. A change applies live.
    var spacing: Spacing?

    /// The settings in force. Replaced by `ConfigWatcher` when the file changes (a config-only change never needs a restart; the one exception
    /// is `wm`). Read on the main thread.
    static var shared: AppConfig = read() ?? AppConfig()

    static var url: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISKELL_CONFIG"] ?? NSHomeDirectory() + "/.config/riskell/config.json")
    }
    static var directory: URL { url.deletingLastPathComponent() }
    static var pillsDirectory: URL { directory.appendingPathComponent("pills") }

    /// The file plus the drop-in pill files. A missing file is the defaults; a file that is not valid JSON is nil (the caller keeps what it had,
    /// so a half-typed edit never wipes the settings).
    static func read() -> AppConfig? {
        var c = AppConfig()
        if let d = try? Data(contentsOf: url) {
            guard let parsed = try? JSONDecoder().decode(AppConfig.self, from: d) else { print("config: \(url.path) is not valid"); fflush(stdout); return nil }
            c = parsed
        }
        let extra = dropIns()
        if !extra.isEmpty { c.pills = (c.pills ?? []) + extra }
        return c
    }

    /// `pills/*.json` next to the config: one pill object, or an array of them, per file, in file-name order.
    private static func dropIns() -> [PillSpec] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: pillsDirectory.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        var out: [PillSpec] = []
        for f in files {
            guard let d = try? Data(contentsOf: pillsDirectory.appendingPathComponent(f)) else { continue }
            if let one = try? JSONDecoder().decode(PillSpec.self, from: d) { out.append(one) }
            else if let many = try? JSONDecoder().decode([PillSpec].self, from: d) { out += many }
            else { print("pills: \(f) is not a valid pill file"); fflush(stdout) }
        }
        return out
    }

    var claudeEnabled: Bool { usage?.claude ?? false }
    var opencodeWorkspace: String? { usage?.opencode?.workspace.flatMap { $0.isEmpty ? nil : $0 } }
    var opencodeProfiles: String {
        (usage?.opencode?.profiles ?? "~/Library/Application Support/zen/Profiles").replacingOccurrences(of: "~", with: NSHomeDirectory(), options: .anchored)
    }
}
