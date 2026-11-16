import Foundation

/// Test hooks for screenshots (scripts/make-screenshots). Both are off unless their environment variable is set.
///  - RISKELL_DEMO: names that belong to the user (devices, volumes, processes, network addresses) are shown as placeholders.
///  - RISKELL_CACHE_DIR: where riskell keeps its caches, so a test instance never reads or overwrites the real ones.
enum Demo {
    static let on = ProcessInfo.processInfo.environment["RISKELL_DEMO"] != nil

    /// `~/.cache/riskell`, or the folder RISKELL_CACHE_DIR names.
    static var cacheDirectory: String { ProcessInfo.processInfo.environment["RISKELL_CACHE_DIR"] ?? NSHomeDirectory() + "/.cache/riskell" }

    private static let apps = ["Terminal", "Browser", "Editor", "Notes", "Music", "Mail", "Calendar", "Chat", "Preview", "Photos", "Maps", "Podcasts"]

    /// A process or app name: itself, or (in demo mode) a stable stand-in. riskell keeps its own name.
    static func process(_ name: String) -> String {
        guard on, name != "riskell" else { return name }
        return apps[name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % apps.count]
    }

    /// An audio or Bluetooth device name: possessives ("Sam's iPhone") lose the owner.
    static func device(_ name: String) -> String {
        guard on else { return name }
        return name.replacingOccurrences(of: #"^.+?[’']s "#, with: "My ", options: .regularExpression)
    }

    static func volume(_ name: String) -> String { on ? "DATA" : name }

    // A minute of plausible history for the graphs that otherwise fill only while their card is open (screenshots).
    static func cpuAt(_ i: Int) -> Double { let w: Double = sin(Double(i) / 5); let burst: Double = i % 13 == 0 ? 14 : 0; return 16 + 11 * w + burst }
    static func memAt(_ i: Int) -> Double { let w: Double = sin(Double(i) / 17); return 56 + 1.5 * w }
    static func rxAt(_ i: Int) -> Double { let s: Double = abs(sin(Double(i) / 4)); let scale: Double = i % 20 < 12 ? 900_000 : 150_000; return 60_000 + s * scale }
    static func txAt(_ i: Int) -> Double { let s: Double = abs(sin(Double(i) / 7)); return 9_000 + s * 120_000 }
    static func dbAt(_ i: Int) -> Double { let w: Double = sin(Double(i) / 9); let burst: Double = i % 37 == 0 ? 8 : 0; return -33 + 11 * w + burst }
    static func address(_ ip: String, _ placeholder: String) -> String { on && !ip.isEmpty ? placeholder : ip }
}
