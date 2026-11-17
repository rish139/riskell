// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellKit

/// The thermal service the engine runs while a fan atom is on a showing bar: one SMC pass every 10 s (the kit's repeating timer, the first pass
/// at once), published to the bar's numbers and to the history the fan card draws. `stop` ends the passes and clears the history.
enum ThermalService {
    /// The kit environment of the last start: the fan card's live reading uses it for its own timer.
    static var env: Env?
    /// The SMC reader. It is loaded once, on the first start, and kept after a stop.
    static let reader = Thermal()
    private static var stopRecording: (() -> Void)?

    static func start(_ env: Env) {
        guard stopRecording == nil else { return }          // already running: a second start does nothing
        self.env = env
        reader.start()
        if CommandLine.arguments.contains("--fake-heat") { FanLive.shared.seedFakeHistory() }   // sample history for snapshots
        stopRecording = env.repeating(.seconds(10)) { record() }
    }

    static func stop() {
        stopRecording?(); stopRecording = nil
        FanLive.shared.clearHistory()
    }

    /// The bar's reading comes from the same read as the history: fans and temperatures move slowly, 10 s is plenty.
    private static func record() {
        let s = reader.snapshot(light: true)
        SystemGauges.shared.set(thermal: ThermalReading(tempC: s.temps.first.flatMap { $0 }, fanRPM: s.fans.isEmpty ? nil : Int(s.rpm.rounded()),
                                                       hottest: s.hottest))
        FanLive.shared.record(s)
    }
}

/// Reads the fan speeds and the sensor groups from the SMC (read-only, no root). `start` enumerates the keys once.
final class Thermal {
    static let groups: [(name: String, short: String)] = [("CPU P-CORES", "CPU"), ("CPU E-CORES", "E-CORES"), ("GPU", "GPU"), ("MEMORY", "MEM"), ("BATTERY", "BAT"), ("SSD", "SSD")]
    private var smc: SMC?
    private var loaded = false
    private var temps: [SMC.Key] = [], fanKeys: [[String: SMC.Key]] = []
    private var groupKeys: [[SMC.Key]] = []
    private var power: [String: SMC.Key] = [:]

    func start() {
        guard !loaded else { return }
        loaded = true
        guard let s = SMC() else { print("thermal: AppleSMC unavailable"); return }
        s.enumerate()
        smc = s
        let flt = s.keys.filter { Self.name($0.type) == "flt " }
        temps = flt.filter { $0.name.hasPrefix("Tp") }
        func match(_ re: String) -> [SMC.Key] { flt.filter { $0.name.range(of: re, options: .regularExpression) != nil } }
        groupKeys = [temps, match(#"^Te[0-9A-Za-z]{2}$"#), match(#"^Tg[0-9A-Za-z]{2}$"#), match(#"^Tm[0-9A-Za-z]{2}$"#), match(#"^TB[0-9]T$"#), match(#"^TH0[xab]$"#).prefix(1).map { $0 }]
        let ac = s.keys.filter { $0.name.range(of: #"^F\dAc$"#, options: .regularExpression) != nil }.sorted { $0.name < $1.name }
        fanKeys = ac.map { a in
            let n = String(a.name.dropFirst().prefix(1))
            return ["ac": a, "tg": s.keys.first { $0.name == "F\(n)Tg" }, "mn": s.keys.first { $0.name == "F\(n)Mn" }, "mx": s.keys.first { $0.name == "F\(n)Mx" }].compactMapValues { $0 }
        }
        for k in ["PSTR", "PDTR", "PPBR"] { if let key = s.keys.first(where: { $0.name == k }) { power[k] = key } }
    }
    private static func name(_ c: UInt32) -> String { String(decoding: (0..<4).map { UInt8(truncatingIfNeeded: c >> UInt32(24 - 8 * $0)) }, as: UTF8.self) }

    /// For `--smc`: every sensor the average is made of, and the fan keys with their limits.
    func describe() -> String {
        guard let smc else { return "no SMC" }
        let t = temps.map { "\($0.name)=\(smc.value($0).map { String(format: "%.1f", $0) } ?? "?")" }.joined(separator: " ")
        let snap = snapshot()
        return "\(smc.keys.count) keys\nCPU temps: \(t)\nfans: \(snap.fans)\ngroups: \(snap.temps)\nhottest \(snap.hottest.map { String($0) } ?? "-") power \(snap.sysW ?? -1) \(snap.dcW ?? -1) \(snap.battW ?? -1)"
    }

    /// Every key is read once (an SMC call is ~0.2 ms). `light` is the bar's reading: fan speed and the sensor groups,
    /// without the fan limits or the power rails that only the fan card shows.
    func snapshot(light: Bool = false) -> FanSnap {
        guard let smc else { return FanSnap() }
        var s = FanSnap()
        s.fans = fanKeys.compactMap { k in
            guard let rpm = k["ac"].flatMap({ smc.value($0) }), rpm >= 0, rpm < 20_000 else { return nil }
            if light { return FanInfo(rpm: rpm, target: 0, min: 0, max: 0) }
            return FanInfo(rpm: rpm, target: k["tg"].flatMap { smc.value($0) } ?? 0, min: k["mn"].flatMap { smc.value($0) } ?? 0, max: k["mx"].flatMap { smc.value($0) } ?? 0)
        }
        var hot: Double?
        s.temps = groupKeys.enumerated().map { i, keys in
            let v = keys.compactMap { smc.value($0) }.filter { $0 > 10 && $0 < 125 }
            // the hottest single sensor of the CPU, GPU and memory groups (an average hides a hot core)
            if i < 4, let m = v.max() { hot = Swift.max(hot ?? m, m) }
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        s.hottest = hot
        if !light {
            s.sysW = power["PSTR"].flatMap { smc.value($0) }; s.dcW = power["PDTR"].flatMap { smc.value($0) }; s.battW = power["PPBR"].flatMap { smc.value($0) }
        }
        return s
    }
}

/// Diagnostics for the app's `--dump --smc`: the SMC as this package reads it.
public enum SystemDiagnostics {
    public static func smc() -> String {
        let r = Thermal()
        r.start()
        return r.describe()
    }
}
