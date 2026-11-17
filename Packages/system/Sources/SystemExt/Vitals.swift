// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import IOKit
import Darwin
import RiskellKit

struct ProcGroup: Identifiable, Equatable {
    var id: String { name }
    let name: String
    var cpu: Double        // cores' worth of CPU time over the last second
    var rss: UInt64
    var n: Int
    var pids: [Int32]
    var mine: Bool
}
struct DiskInfo: Identifiable, Equatable { var id: String { name }; let name: String; let total: Int64; let free: Int64
    var used: Int64 { total - free } }
struct HistSample: Equatable { let t: TimeInterval; let cpu: Double; let mem: Double }   // NaN cpu = a gap (the card was closed)

/// What the vitals card shows beyond what the bar already has: processes grouped by app, disks and their IO, memory detail, load, and
/// the last minute of CPU and memory. All of it is read in-process (libproc, host statistics, IOKit) and ONLY while the card is open:
/// closed, there is no timer and no work. The history survives between opens and bridges the closed gap with a marker.
final class Vitals: ObservableObject {
    static let shared = Vitals()

    private(set) var procs: [ProcGroup] = []
    private(set) var disks: [DiskInfo] = []
    private(set) var ioR = 0.0                              // bytes/s over all block devices
    private(set) var ioW = 0.0
    private(set) var load: [Double] = [0, 0, 0]
    private(set) var uptime: TimeInterval = 0
    private(set) var hist: [HistSample] = []
    private(set) var available = 0.0                       // bytes
    private(set) var cached = 0.0
    private(set) var swapUsed = 0.0
    private(set) var swapTotal = 0.0
    private(set) var pressure = 1                          // kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical
    private(set) var freePct = 100                         // kern.memorystatus_level

    /// Stops the 1 s reading while a card is open (the kit's `env.repeating`, from the environment of the atom that retained last).
    private var stopTick: (() -> Void)?
    private let queue = DispatchQueue(label: "riskell.vitals", qos: .utility)
    private var prevCPU: (UInt32, UInt32, UInt32, UInt32)?
    private var prevProc: [Int32: UInt64] = [:]                       // pid -> cpu time (ns) at the last sample
    private var prevAt = DispatchTime.now().uptimeNanoseconds
    private var prevIO: (r: UInt64, w: UInt64, at: TimeInterval)?
    private var tb = mach_timebase_info_data_t()
    private var users = 0
    private var ticks = 0

    init() { mach_timebase_info(&tb) }

    /// A card that needs the data calls start() when it appears and stop() when it goes.
    func start() {
        users += 1
        guard stopTick == nil, let env = SystemEngine.shared.env else { return }
        ticks = 0
        if let last = hist.last, Date().timeIntervalSince1970 - last.t > 3 { hist.append(HistSample(t: Date().timeIntervalSince1970, cpu: .nan, mem: .nan)) }
        prevCPU = nil; prevProc = [:]; prevIO = nil
        // the first firing is immediate, so the first reading comes now
        if Demo.on && hist.isEmpty {      // screenshots: a minute of plausible history, so the graph is not empty
            let now = Date().timeIntervalSince1970
            hist = (0..<60).map { i in HistSample(t: now - Double(60 - i), cpu: Demo.cpuAt(i), mem: Demo.memAt(i)) }
        }
        stopTick = env.repeating(.seconds(1)) { [weak self] in self?.tick() }
    }
    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        stopTick?(); stopTick = nil
    }

    private func pub() { objectWillChange.send() }

    private func tick() {
        ticks += 1
        let now = Date().timeIntervalSince1970
        // cheap readings on the main thread
        var la = [Double](repeating: 0, count: 3); getloadavg(&la, 3); load = la
        var bt = timeval(); var sz = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &bt, &sz, nil, 0) == 0 { uptime = now - Double(bt.tv_sec) }
        let cpu = sampleCPU()
        readMemory()
        if let cpu {
            hist.append(HistSample(t: now, cpu: cpu, mem: Double(SystemGauges.shared.mem)))
            hist.removeAll { $0.t < now - 75 }
        }
        pressure = Int(Self.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
        freePct = Int(Self.sysctlInt("kern.memorystatus_level") ?? 100)
        if ticks % 10 == 1 { readDisks() }      // volumes change rarely, and listing them is the dearest call here
        readIO(now)
        pub()
        // processes: a few ms of libproc work, off the main thread, every other second (the list changes slowly enough)
        guard ticks % 2 == 1 else { return }
        let prev = prevProc, prevT = prevAt, tbn = UInt64(tb.numer), tbd = UInt64(max(1, tb.denom))
        queue.async { [weak self] in
            let r = Vitals.scanProcesses(prev: prev, prevAt: prevT, numer: tbn, denom: tbd)
            DispatchQueue.main.async {
                guard let self, self.stopTick != nil else { return }
                self.prevProc = r.times; self.prevAt = r.at
                if r.groups != self.procs { self.procs = r.groups; self.pub() }
            }
        }
    }

    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks, now = (t.0, t.1, t.2, t.3)
        defer { prevCPU = now }
        guard let p = prevCPU else { return nil }
        let busy = Double(now.0 &- p.0) + Double(now.1 &- p.1) + Double(now.3 &- p.3), total = busy + Double(now.2 &- p.2)
        return total > 0 ? busy / total * 100 : nil
    }

    private func readMemory() {
        var vm = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) } }
        if r == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            available = (Double(vm.free_count) + Double(vm.inactive_count) + Double(vm.purgeable_count)) * page
            cached = Double(vm.external_page_count) * page
        }
        var sw = xsw_usage(); var sz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 { swapUsed = Double(sw.xsu_used); swapTotal = Double(sw.xsu_total) }
    }

    private func readDisks() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeIsLocalKey, .volumeIsReadOnlyKey]
        var out: [DiskInfo] = []
        for u in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == true, v.volumeIsReadOnly != true, let total = v.volumeTotalCapacity, total >= 2_000_000_000,
                  let free = [v.volumeAvailableCapacityForImportantUsage, v.volumeAvailableCapacity.map(Int64.init)].compactMap({ $0 }).first(where: { $0 > 0 }) else { continue }   // exFAT and friends report 0 for the "important usage" figure
            out.append(DiskInfo(name: u.path == "/" ? "ROOT" : Demo.volume(v.volumeName ?? u.lastPathComponent), total: Int64(total), free: free))
        }
        if Array(out.prefix(3)) != disks { disks = Array(out.prefix(3)) }
    }

    private func readIO(_ now: TimeInterval) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var r: UInt64 = 0, w: UInt64 = 0
        while case let s = IOIteratorNext(it), s != 0 {
            if let st = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                r &+= (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0; w &+= (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(s)
        }
        if let p = prevIO, now > p.at { ioR = Double(r &- p.r) / (now - p.at); ioW = Double(w &- p.w) / (now - p.at) }
        prevIO = (r, w, now)
    }

    static func sysctlInt(_ name: String) -> Int32? { var v: Int32 = 0; var s = MemoryLayout<Int32>.size; return sysctlbyname(name, &v, &s, nil, 0) == 0 ? v : nil }

    /// Every readable process, grouped by the app bundle it lives in (a browser's helpers are one row).
    private static func scanProcesses(prev: [Int32: UInt64], prevAt: UInt64, numer: UInt64, denom: UInt64) -> (groups: [ProcGroup], times: [Int32: UInt64], at: UInt64) {
        let at = DispatchTime.now().uptimeNanoseconds
        let wall = Double(max(1, at &- prevAt))
        var pids = [Int32](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))); if n <= 0 { return ([], prev, at) }
        var times: [Int32: UInt64] = [:]
        var groups: [String: ProcGroup] = [:]
        let me = getuid()
        var pathBuf = [CChar](repeating: 0, count: 4096), nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(n) where pid > 0 {
            var ti = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }
            var bsd = proc_bsdinfo()
            let mine = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 && bsd.pbi_uid == me
            let ticks = ti.pti_total_user &+ ti.pti_total_system
            let ns = ticks &* numer / denom
            times[pid] = ns
            let cores = prev[pid].map { Double(ns &- $0) / wall } ?? 0
            let key: String
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0, let r = String(cString: pathBuf).range(of: ".app/") {
                key = ((String(cString: pathBuf)[..<r.lowerBound]) as Substring).split(separator: "/").last.map(String.init) ?? "?"
            } else if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 { key = String(cString: nameBuf) } else { continue }
            var g = groups[key] ?? ProcGroup(name: Demo.process(key), cpu: 0, rss: 0, n: 0, pids: [], mine: true)
            g.cpu += max(0, cores); g.rss += ti.pti_resident_size; g.n += 1; g.pids.append(pid); g.mine = g.mine && mine
            groups[key] = g
        }
        let list = groups.values.map { var g = $0; g.cpu = (g.cpu * 100).rounded() / 100; return g }
        return (list, times, at)
    }
}
