// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import CoreWLAN
import SystemConfiguration
import CoreLocation
import RiskellKit

/// What the network atom shows, event-driven: CoreWLAN events (power, link, link quality) and SystemConfiguration notifications
/// (the default route and its interface). No timers. The SSID is only readable once Location Services allows it for this binary;
/// signal strength, channel and on/off never need it. It runs while the atom is on a showing bar (`start` and `stop` count the users).
final class Wifi: NSObject, CWEventDelegate, CLLocationManagerDelegate {
    static let shared = Wifi()
    private let client = CWWiFiClient.shared()
    private var dyn: SCDynamicStore?
    private var loc: CLLocationManager?
    private var askedAtStart = false
    private var src: CFRunLoopSource?
    private var users = 0       // the atom instances that want it: it starts with the first and stops with the last

    private override init() { super.init() }

    func start() {
        users += 1
        guard users == 1 else { return }
        client.delegate = self
        for e in [CWEventType.powerDidChange, .ssidDidChange, .linkDidChange, .linkQualityDidChange] { try? client.startMonitoringEvent(with: e) }
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        dyn = SCDynamicStoreCreate(nil, "riskell" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<Wifi>.fromOpaque(info).takeUnretainedValue().read()
        }, &ctx)
        if let dyn {
            SCDynamicStoreSetNotificationKeys(dyn, ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray, nil)
            src = SCDynamicStoreCreateRunLoopSource(nil, dyn, 0)
            if let src { CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode) }
        }
        // macOS shows Wi-Fi names only to an app that was allowed Location: ask once (the bundle's purpose string explains why)
        if Bundle.main.bundleIdentifier != nil {
            let m = CLLocationManager(); m.delegate = self; loc = m
            if m.authorizationStatus == .notDetermined { askedAtStart = true; m.requestAlwaysAuthorization() }
        }
        read()
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
        if let src { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode) }
        src = nil; dyn = nil; loc = nil; askedAtStart = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        read()
        // macOS gives Wi-Fi names only to a process that STARTED after the grant: if it arrives while we run, start again (launchd relaunches us)
        if askedAtStart, locationState == "ok", client.interface()?.ssid() == nil {
            askedAtStart = false
            print("location granted: restarting to pick up Wi-Fi names"); fflush(stdout)
            KitHost.app?.restart()
        }
    }
    /// "ok" (names readable), "asking" (the prompt is up or not answered), "denied", or "none" (running outside the app bundle)
    private var locationState: String {
        guard let m = loc else { return "none" }
        switch m.authorizationStatus {
        case .authorizedAlways, .authorized: return "ok"
        case .notDetermined: return "asking"
        default: return "denied"
        }
    }

    /// The interface the default route uses, straight from the dynamic store.
    static func primaryInterface() -> String? {
        guard let d = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any] ?? SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv6" as CFString) as? [String: Any] else { return nil }
        return d["PrimaryInterface"] as? String
    }

    func read() {
        let i = client.interface()
        let on = i?.powerOn() ?? false, rssi = on ? (i?.rssiValue() ?? 0) : 0
        let primary = Self.primaryInterface()
        var kind = "down"
        if let p = primary {
            if p == i?.interfaceName { kind = "wifi" } else if p.hasPrefix("en") { kind = "eth" } else { kind = "linked" }
        } else if on && rssi != 0 { kind = "linked" }
        let s = WifiState(on: on, rssi: rssi, ssid: i?.ssid(), kind: kind, primary: primary, location: locationState)
        DispatchQueue.main.async { NetState.shared.set(wifi: s) }
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { read() }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { read() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { read() }
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        // the event carries the signal: no SSID or route lookups, and a flicker of a dBm or two is not worth a redraw
        DispatchQueue.main.async {
            let net = NetState.shared
            var w = net.wifi
            guard w.on, w.kind == "wifi", rssi != 0, abs(rssi - w.rssi) >= 3 else { return }
            w.rssi = rssi; net.set(wifi: w)
        }
    }
}
