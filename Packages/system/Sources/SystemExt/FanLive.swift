// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation

struct HeatPoint: Equatable { let t: TimeInterval; let temps: [Double?]; let rpm: Double }

/// The thermal history and the fan card's live feed. The 30-minute history is recorded all the time (`ThermalService` takes one SMC pass every
/// 10 s, so the card opens on a chart that already has its past, and the atom has a speed trace); the 1 s live reading runs only while the card
/// is open. Read-only: the SMC is only ever read.
final class FanLive: ObservableObject {
    static let shared = FanLive()
    private(set) var snap = FanSnap()
    private(set) var hist: [HeatPoint] = []
    private var stopFast: (() -> Void)?
    private var users = 0

    /// One reading from `ThermalService`: the bar's and the card's current values, and one point of the history.
    func record(_ s: FanSnap) {
        snap = s
        hist.append(HeatPoint(t: Date().timeIntervalSince1970, temps: s.temps, rpm: s.rpm))
        if hist.count > 180 { hist.removeFirst(hist.count - 180) }
        objectWillChange.send()
    }
    func clearHistory() { hist.removeAll() }
    /// `--fake-heat`: sample history for snapshots, 30 minutes of plausible curves.
    func seedFakeHistory() {
        let now = Date().timeIntervalSince1970
        hist = (0..<180).map { i in
            let x = Double(i) / 180, w = sin(x * 9) * 0.5 + 0.5
            return HeatPoint(t: now - Double(179 - i) * 10, temps: [52 + 22 * w * x, 48 + 14 * w, 45 + 12 * x, 47 + 6 * w, 31 + 3 * x, 34 + 5 * w], rpm: 1200 + 4200 * x * w)
        }
    }

    /// The card's open: counted, so the 1 s reading runs once for however many cards ask. Its first firing is at once.
    func start() {
        users += 1
        guard stopFast == nil, let env = ThermalService.env else { return }
        stopFast = env.repeating(.seconds(1)) { [self] in
            snap = ThermalService.reader.snapshot(); objectWillChange.send()
        }
    }
    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        stopFast?(); stopFast = nil
    }
}
