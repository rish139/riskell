// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Combine
import Foundation
import RiskellKit

/// The Wi-Fi and route state the network atom and its card show. Copied from the app's Store (the struct only).
struct WifiState: Equatable {
    var on = false; var rssi = 0; var ssid: String? = nil
    var kind = "down"            // wifi | eth | linked (associated or tunnelled, no route) | down
    var primary: String? = nil   // the interface the default route uses
    var location = "none"       // Location permission for Wi-Fi names: ok | asking | denied | none
    var pct: Int { kind != "wifi" || rssi == 0 ? 0 : max(0, min(100, 2 * (rssi + 100))) }   // -50 dBm and better = 100 %, -100 dBm = 0 %
}

/// The shared holder of the network state: `Wifi` writes it while the atom is on a showing bar, the atom and its card read it.
final class NetState: ObservableObject {
    static let shared = NetState()
    @Published private(set) var wifi = WifiState()
    private init() {}
    /// Publishes only a real change, so an unchanged reading does not redraw the bar.
    func set(wifi w: WifiState) { if w != wifi { wifi = w } }
}

/// The kit environment of the network atom, set in `activate`. The card's one-second readings use it: the kit owns every timer.
enum NetEnv {
    static var env: Env?
}
