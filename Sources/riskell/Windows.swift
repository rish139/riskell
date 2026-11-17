import AppKit
import SwiftUI
import RiskellKit

/// What the system knows about a window's app (the overview's icons; the workspaces package keeps its own copy), read in-process (no `ps`): its icon and when its process started.
enum Apps {
    struct Info { let icon: NSImage?; let launched: Date?; let name: String }
    private static var cache: [Int: Info] = [:]
    static func info(pid: Int, fallback: String) -> Info {
        if let c = cache[pid] { return c }
        let app = NSRunningApplication(processIdentifier: pid_t(pid))
        let i = Info(icon: app?.icon, launched: app?.launchDate, name: app?.localizedName ?? fallback)
        cache[pid] = i
        return i
    }
    /// "now", "42m", "3h 12m", "2d 4h": the unit that matters, never seconds
    static func age(_ since: Date?, now: Date = Date()) -> String {
        guard let since else { return "" }
        let m = Int(now.timeIntervalSince(since) / 60)
        if m < 1 { return "now" }
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h \(String(format: "%02d", m % 60))m" }
        return "\(h / 24)d \(h % 24)h"
    }
}
