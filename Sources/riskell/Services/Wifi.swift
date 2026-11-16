import CoreWLAN
import SystemConfiguration
import CoreLocation
import RiskellKit

/// What the network atom shows, event-driven: CoreWLAN events (power, link, link quality) and SystemConfiguration notifications
/// (the default route and its interface). No timers. The SSID is only readable once Location Services allows it for this binary;
/// signal strength, channel and on/off never need it.
final class Wifi: NSObject, CWEventDelegate, CLLocationManagerDelegate {
    private let store: Store
    private let client = CWWiFiClient.shared()
    private var dyn: SCDynamicStore?
    private var loc: CLLocationManager?
    private var askedAtStart = false

    init(store: Store) { self.store = store; super.init() }

    func start() {
        client.delegate = self
        for e in [CWEventType.powerDidChange, .ssidDidChange, .linkDidChange, .linkQualityDidChange] { try? client.startMonitoringEvent(with: e) }
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        dyn = SCDynamicStoreCreate(nil, "riskell" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<Wifi>.fromOpaque(info).takeUnretainedValue().read()
        }, &ctx)
        if let dyn {
            SCDynamicStoreSetNotificationKeys(dyn, ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray, nil)
            if let src = SCDynamicStoreCreateRunLoopSource(nil, dyn, 0) { CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode) }
        }
        // macOS shows Wi-Fi names only to an app that was allowed Location: ask once (the bundle's purpose string explains why)
        if Bundle.main.bundleIdentifier != nil {
            let m = CLLocationManager(); m.delegate = self; loc = m
            if m.authorizationStatus == .notDetermined { askedAtStart = true; m.requestAlwaysAuthorization() }
        }
        read()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        read()
        // macOS gives Wi-Fi names only to a process that STARTED after the grant: if it arrives while we run, start again (launchd relaunches us)
        if askedAtStart, locationState == "ok", client.interface()?.ssid() == nil {
            print("location granted: restarting to pick up Wi-Fi names"); fflush(stdout)
            shutdown(); exit(0)
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
        DispatchQueue.main.async { self.store.set(wifi: s) }
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { read() }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { read() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { read() }
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        // the event carries the signal: no SSID or route lookups, and a flicker of a dBm or two is not worth a redraw
        DispatchQueue.main.async { [store] in
            var w = store.wifi
            guard w.on, w.kind == "wifi", rssi != 0, abs(rssi - w.rssi) >= 3 else { return }
            w.rssi = rssi; store.set(wifi: w)
        }
    }
}
