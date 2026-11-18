import AppKit
import CoreLocation
import QuartzCore
import RiskellKit

/// What only the running bars know, for the health check: whether the window manager's subscription is live on which protocol version,
/// the versions riskell was last verified against and the settings it depends on, gap drift, the permissions this process was granted,
/// the atoms on the bars, and the trackpad and scroll guard's health. `riskell-setup --doctor` asks for it over the event socket
/// (the `doctor` word, EventSocket.replies) and prints it; nothing here is probed twice.
///
/// It prints nothing: an answer written with `print` would go to the log, not to the caller.
enum AppStatus {
    /// The payload's own number: the setup binary reads it, so an older app and a newer check still understand each other.
    static let schema = 1

    static func json() -> String {
        let omni = WM.shared?.name == "omniwm"
        var o: [String: Any] = [
            "schema": schema,
            "pid": Int(getpid()),
            "version": Build.version,
            "bundled": Bundle.main.bundleIdentifier != nil,
            "macOS": Compat.macOSNow(),
            "verifiedMacOS": Compat.Verified.macOS,
            "wm": WM.shared?.name ?? "none",
            "wmSubscribed": omni ? ((WM.shared as? Omni)?.subscribed ?? false) : false,
            "gestures": AppConfig.shared.gestures ?? "system",
            "accessibility": AXIsProcessTrusted(),
            "location": locationState,
            "services": Needs.active,
            "atoms": Config.shared.placedAtoms.count,
            "bars": BarKey.allCases.filter { Config.shared.on($0) }.map(\.rawValue),
            "notes": Compat.shared.notes,
            "verifiedOmniwm": Compat.Verified.omniwm,
            "omniwm": Compat.shared.running.omniwm,
            "gestureConflicts": GestureConflicts.current(),
        ]
        if omni { o["wmProtocol"] = Omni.protocolVersion }
        // the settings riskell needs, and the outer gaps it writes itself (Services/Gaps.swift): what they are now, what they must be
        if let s = Compat.omniwmSettings() {
            o["settings"] = Compat.Verified.omniwmSettings.map { ["key": $0.key, "want": $0.want, "actual": s[$0.key] ?? ""] }
            o["gaps"] = Compat.Verified.gaps.map { ["key": $0.key, "want": $0.want, "actual": s[$0.key] ?? ""] }
        }
        // the trackpad: a MultitouchSupport attachment older than the last wake delivers no frames, so the swipes are silently dead
        if let t = Touch.shared {
            let age = CACurrentMediaTime() - t.attachedAt
            o["touch"] = ["attachedAgo": age, "attachedAt": Date().timeIntervalSince1970 - age,
                          "frames": Touch.frames, "threeFingers": Touch.threeFrames,
                          "lastFrameAgo": Touch.lastFrame > 0 ? CACurrentMediaTime() - Touch.lastFrame : -1]
        }
        let guardHealth = ScrollGuard.health
        o["scrollGuard"] = ["tap": guardHealth.tap, "trusted": AXIsProcessTrusted(), "blocking": ScrollGuard.blocking, "dropped": guardHealth.dropped]
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// "ok" (names readable), "asking" (the prompt is up), "denied", or "none" outside the app bundle — the question Wifi asks, so the
    /// check reports the grant Wi-Fi names have.
    private static var locationState: String {
        guard Bundle.main.bundleIdentifier != nil else { return "none" }
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorized: return "ok"
        case .notDetermined: return "asking"
        default: return "denied"
        }
    }
}
