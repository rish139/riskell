import Foundation
import IOKit
import RiskellKit

/// Read-only AppleSMC access (no root). The user-client struct is 80 bytes in C layout; it is built by hand here because Swift's
/// nested-struct padding differs from C's. Offsets: key 0, keyInfo.size 28, keyInfo.type 32, result 40, command 42, index 44, bytes 48.
final class SMC {
    struct Key { let name: String; let code: UInt32; let size: UInt32; let type: UInt32 }

    private var conn: io_connect_t = 0
    private(set) var keys: [Key] = []

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private static func code(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
    private static func name(_ c: UInt32) -> String { String(decoding: (0..<4).map { UInt8(truncatingIfNeeded: c >> UInt32(24 - 8 * $0)) }, as: UTF8.self) }

    private func call(_ command: UInt8, key: UInt32 = 0, size: UInt32 = 0, index: UInt32 = 0) -> [UInt8]? {
        var inp = [UInt8](repeating: 0, count: 80), out = [UInt8](repeating: 0, count: 80)
        func put(_ v: UInt32, at o: Int) { withUnsafeBytes(of: v) { for i in 0..<4 { inp[o + i] = $0[i] } } }
        put(key, at: 0); put(size, at: 28); inp[42] = command; put(index, at: 44)
        var outSize = 80
        let r = IOConnectCallStructMethod(conn, 2, inp, 80, &out, &outSize)
        return r == KERN_SUCCESS && out[40] == 0 ? out : nil
    }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << UInt32(8 * $1) } }

    private func info(_ code: UInt32) -> (size: UInt32, type: UInt32)? {
        guard let o = call(9, key: code) else { return nil }
        return (Self.u32(o, 28), Self.u32(o, 32))
    }

    /// Lists every key once (about a thousand), keeping its size and type so a later read is a single call.
    func enumerate() {
        guard let ci = info(Self.code("#KEY")), let co = call(5, key: Self.code("#KEY"), size: ci.size) else { return }
        let n = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(co[48 + $1]) }          // #KEY is big-endian ui32
        var list: [Key] = []
        for i in 0..<n {
            guard let o = call(8, index: i) else { continue }
            let c = Self.u32(o, 0)
            if let inf = info(c) { list.append(Key(name: Self.name(c), code: c, size: inf.size, type: inf.type)) }
        }
        keys = list
    }

    func value(_ k: Key) -> Double? {
        guard let o = call(5, key: k.code, size: k.size) else { return nil }
        let b = Array(o[48..<(48 + Int(min(k.size, 32)))])
        switch Self.name(k.type) {
        case "flt ": return b.count >= 4 ? Double(Float(bitPattern: Self.u32(b, 0))) : nil      // Apple Silicon: little-endian float
        case "ui8 ": return b.first.map(Double.init)
        case "ui16": return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case "sp78": return b.count >= 2 ? Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256 : nil
        case "fpe2": return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4 : nil
        default: return nil
        }
    }
}

struct FanInfo: Equatable { var rpm: Double; var target: Double; var min: Double; var max: Double }
/// One reading of everything the fan atom and card show: the fans, the temperature of each sensor group (averaged), the hottest of them,
/// and three power rails.
struct FanSnap: Equatable {
    var fans: [FanInfo] = []
    var temps: [Double?] = []            // indexed by Thermal.groups
    var hottest: Double? = nil
    var sysW: Double? = nil, dcW: Double? = nil, battW: Double? = nil
    var rpm: Double { fans.isEmpty ? 0 : fans.map(\.rpm).reduce(0, +) / Double(fans.count) }
    var maxRPM: Double { fans.map(\.max).max() ?? 0 }
}

/// Fan speed and temperatures for the bar and the fan card, read-only from the SMC: the fans (F<n>Ac, with target, minimum and maximum),
/// the sensor groups (P cores, E cores, GPU, memory, battery, SSD), and three power keys. The bar's numbers are read on Sys's 2 s tick.
final class Thermal {
    static let groups: [(name: String, short: String)] = [("CPU P-CORES", "CPU"), ("CPU E-CORES", "E-CORES"), ("GPU", "GPU"), ("MEMORY", "MEM"), ("BATTERY", "BAT"), ("SSD", "SSD")]
    private let store: Store
    private var smc: SMC?
    private var temps: [SMC.Key] = [], fanKeys: [[String: SMC.Key]] = []
    private var groupKeys: [[SMC.Key]] = []
    private var power: [String: SMC.Key] = [:]

    init(store: Store) { self.store = store }

    func start() {
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
        publish(snapshot(light: true))
    }
    private static func name(_ c: UInt32) -> String { String(decoding: (0..<4).map { UInt8(truncatingIfNeeded: c >> UInt32(24 - 8 * $0)) }, as: UTF8.self) }

    /// For --smc: every sensor the average is made of, and the fan keys with their limits.
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

    func publish(_ s: FanSnap) {
        store.set(thermal: ThermalReading(tempC: s.temps.first.flatMap { $0 }, fanRPM: s.fans.isEmpty ? nil : Int(s.rpm.rounded()), hottest: s.hottest))
    }
}
