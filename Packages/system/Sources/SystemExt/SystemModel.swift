// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellKit

/// The fan and temperature figures the bar shows (the card has its own, richer snapshot).
struct ThermalReading: Equatable { var tempC: Double?; var fanRPM: Int?; var hottest: Double? = nil }

/// The smart battery's own readings, for the battery atom's runtime and its card.
struct BatteryDetail: Equatable {
    var tempC: Double? = nil
    var health: Double? = nil        // full-charge capacity over design capacity, %
    var cycles: Int? = nil
    var minutes: Int? = nil          // to empty while discharging, to full while charging; nil = the system has no estimate
    var adapterW: Int? = nil         // the connected charger's rating
    var wh: Double? = nil            // energy in the pack now
}

/// The numbers that change on a timer (CPU, memory, power, temperatures), on their own so a tick redraws only the views that show them.
/// (The app's old `Gauges`.) Setters ignore an unchanged value.
final class SystemGauges: ObservableObject {
    static let shared = SystemGauges()
    @Published private(set) var cpu = 0                  // %
    @Published private(set) var cores: [Int] = []        // per-core %, efficiency cores first
    @Published private(set) var memUsedG = 0.0
    @Published private(set) var memTotalG = 0.0
    @Published private(set) var powerHist: [Double] = [] // signed W, one per 5 s, the last 3 minutes
    @Published private(set) var mem = 0                  // %
    @Published private(set) var powerW: Double? = nil    // signed: negative while discharging
    @Published private(set) var thermal = ThermalReading()
    func set(cores c: [Int]) { if c != cores { cores = c } }
    func set(memUsedG u: Double, totalG t: Double) { if u != memUsedG { memUsedG = u }; if t != memTotalG { memTotalG = t } }
    func push(power w: Double) { powerHist.append(w); if powerHist.count > 36 { powerHist.removeFirst(powerHist.count - 36) } }
    func set(cpu c: Int, mem m: Int) { if c != cpu { cpu = c }; if m != mem { mem = m } }
    func set(thermal t: ThermalReading) { if t != thermal { thermal = t } }
    func set(powerW w: Double?) { if w != powerW { powerW = w } }
}

/// The battery (the app's old `Store` fields for it).
final class SystemState: ObservableObject {
    static let shared = SystemState()
    @Published private(set) var batPct: Int? = nil       // nil: no battery
    @Published private(set) var onAC = false
    @Published private(set) var charging = false
    @Published private(set) var batDetail = BatteryDetail()
    func set(battery pct: Int?, onAC ac: Bool, charging ch: Bool) {
        if pct != batPct { batPct = pct }; if ac != onAC { onAC = ac }; if ch != charging { charging = ch }
    }
    func set(batDetail d: BatteryDetail) { if d != batDetail { batDetail = d } }
}
