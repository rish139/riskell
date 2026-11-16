import Foundation
import RiskellKit

struct HeatPoint: Equatable { let t: TimeInterval; let temps: [Double?]; let rpm: Double }

/// The thermal history and the fan card's live feed. The 30-minute history is recorded all the time (one SMC pass every 10 s, so the card
/// opens on a chart that already has its past, and the atom has a speed trace); the 1 s live reading runs only while the card is open.
/// Read-only: the SMC is only ever read.
final class FanLive: ObservableObject {
    static let shared = FanLive()
    private(set) var snap = FanSnap()
    private(set) var hist: [HeatPoint] = []
    private var slow: Timer?, fast: Timer?
    private var users = 0

    func startHistory() {
        if CommandLine.arguments.contains("--fake-heat") {      // sample history for snapshots: 30 minutes of plausible curves
            let now = Date().timeIntervalSince1970
            hist = (0..<180).map { i in
                let x = Double(i) / 180, w = sin(x * 9) * 0.5 + 0.5
                return HeatPoint(t: now - Double(179 - i) * 10, temps: [52 + 22 * w * x, 48 + 14 * w, 45 + 12 * x, 47 + 6 * w, 31 + 3 * x, 34 + 5 * w], rpm: 1200 + 4200 * x * w)
            }
        }
        record()
        slow = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.record() }
        slow?.tolerance = 2
    }
    private func record() {
        let s = thermal.snapshot(light: true)
        snap = s
        thermal.publish(s)          // the bar's reading comes from the same read: fans and temperatures move slowly, 10 s is plenty
        hist.append(HeatPoint(t: Date().timeIntervalSince1970, temps: s.temps, rpm: s.rpm))
        if hist.count > 180 { hist.removeFirst(hist.count - 180) }
        objectWillChange.send()
    }

    func start() {
        users += 1
        guard fast == nil else { return }
        snap = thermal.snapshot(); objectWillChange.send()
        fast = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.snap = thermal.snapshot(); self?.objectWillChange.send() }
        fast?.tolerance = 0.1
    }
    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        fast?.invalidate(); fast = nil
    }
}
