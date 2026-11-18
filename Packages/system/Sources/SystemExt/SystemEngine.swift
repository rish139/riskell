// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Foundation
import IOKit
import IOKit.ps
import Darwin
import RiskellKit

/// The samplers the app's `Sys` used for the bar's CPU, memory, battery and power numbers, now owned by the package and run only while an
/// atom that shows them is on a showing bar. An atom `retain`s what it needs and calls the closure it gets back when it leaves; the one
/// 2 s timer (the kit's `env.repeating`) and the power-source notification run only while something is retained.
final class SystemEngine {
    static let shared = SystemEngine()
    enum Feature: CaseIterable { case load, power, battery, thermal }
    private var counts: [Feature: Int] = [:]
    /// The kit environment of whichever atom retained last: a card (which has no `Env` of its own) uses it for its own timers.
    private(set) var env: Env?
    private var stopTick: (() -> Void)?
    private var batSource: CFRunLoopSource?
    private let g = SystemGauges.shared, state = SystemState.shared
    private var lastHist = Date.distantPast
    private var smoothW: Double?

    func retain(_ f: Feature, _ env: Env) -> () -> Void {
        self.env = env
        counts[f, default: 0] += 1
        reconcile()
        var released = false
        return { [self] in
            guard !released else { return }
            released = true
            counts[f, default: 1] -= 1
            reconcile()
        }
    }
    /// Every feature, as the app's old services ran them whenever one of these atoms was placed: the three atoms' cards read each other's numbers
    /// (the CPU card shows the battery and temperatures, the fan card the CPU load and the battery).
    func retainAll(_ env: Env) -> () -> Void {
        let rs = Feature.allCases.map { retain($0, env) }
        return { rs.forEach { $0() } }
    }
    private func on(_ f: Feature) -> Bool { (counts[f] ?? 0) > 0 }

    private func reconcile() {
        guard let env else { return }
        let tick = on(.load) || on(.power)
        if tick, stopTick == nil {
            if on(.load) { sampleCPU() }
            if on(.power) { readPower() }
            stopTick = env.repeating(.seconds(2)) { [self] in
                if on(.load) { sampleCPU() }
                if on(.power) { readPower() }
            }
        } else if !tick, let s = stopTick { s(); stopTick = nil; prevCores = []; smoothW = nil }
        if on(.battery), batSource == nil {
            readBattery()
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            batSource = IOPSNotificationCreateRunLoopSource({ ctx in
                guard let ctx else { return }
                let me = Unmanaged<SystemEngine>.fromOpaque(ctx).takeUnretainedValue()
                me.readBattery(); if me.on(.power) { me.readPower() }
            }, ctx).takeRetainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), batSource, .defaultMode)
        } else if !on(.battery), let s = batSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode); batSource = nil }
        if on(.thermal) { ThermalService.start(env) } else { ThermalService.stop() }
    }

    private var prevCores: [[UInt32]] = []
    private func sampleCPU() {
        // per-core ticks in one call; the total is their sum
        var ncpu: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &ncpu, &info, &infoCount) == KERN_SUCCESS, let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var now: [[UInt32]] = []
        for i in 0..<Int(ncpu) {
            let o = i * Int(CPU_STATE_MAX)
            now.append([UInt32(bitPattern: info[o + Int(CPU_STATE_USER)]), UInt32(bitPattern: info[o + Int(CPU_STATE_SYSTEM)]),
                        UInt32(bitPattern: info[o + Int(CPU_STATE_IDLE)]), UInt32(bitPattern: info[o + Int(CPU_STATE_NICE)])])
        }
        var cpu = g.cpu, cores = g.cores
        if prevCores.count == now.count {
            var busySum = 0.0, totalSum = 0.0
            cores = zip(now, prevCores).map { n, p in
                let busy = Double(n[0] &- p[0]) + Double(n[1] &- p[1]) + Double(n[3] &- p[3])
                let total = busy + Double(n[2] &- p[2])
                busySum += busy; totalSum += total
                return total > 0 ? Int((busy / total * 100).rounded()) : 0
            }
            if totalSum > 0 { cpu = Int((busySum / totalSum * 100).rounded()) }
        }
        prevCores = now
        g.set(cores: cores)

        var vm = vm_statistics64()
        var vcount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vcount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vcount) }
        }
        var mem = g.mem
        if vr == KERN_SUCCESS {
            // Activity Monitor's "Memory Used": app memory + wired + compressed
            let pages = UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            let bytes = Double(pages) * Double(vm_kernel_page_size), total = Double(ProcessInfo.processInfo.physicalMemory)
            mem = Int((bytes / total * 100).rounded())
            g.set(memUsedG: (bytes / 1_073_741_824 * 10).rounded() / 10, totalG: (total / 1_073_741_824 * 10).rounded() / 10)
        }
        g.set(cpu: cpu, mem: mem)
    }

    private func readBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let pct = d[kIOPSCurrentCapacityKey] as? Int
            let ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            state.set(battery: pct, onAC: ac, charging: (d[kIOPSIsChargingKey] as? Bool) ?? false)
            return
        }
        state.set(battery: nil, onAC: true, charging: false)
    }

    /// Signed battery power in W (negative = discharging) from the smart battery's own registry entry; no root needed.
    private func readPower() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return }
        guard let mV = (d["Voltage"] as? NSNumber)?.doubleValue, let raw = (d["InstantAmperage"] ?? d["Amperage"]) as? NSNumber else { return }
        let mA = Double(Int64(bitPattern: raw.uint64Value))
        g.set(powerW: mV * mA / 1_000_000)
        if Date().timeIntervalSince(lastHist) >= 5 { lastHist = Date(); g.push(power: mV * mA / 1_000_000) }
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        var det = BatteryDetail()
        if let t = num("Temperature") { det.tempC = t / 100 }
        if let full = num("AppleRawMaxCapacity"), let design = num("DesignCapacity"), design > 0 { det.health = full / design * 100 }
        if let c = num("CycleCount") { det.cycles = Int(c) }
        let charging = (d["IsCharging"] as? Bool) ?? false
        // the system's own estimate comes and goes ("no estimate" while it recomputes): fall back to energy over smoothed power
        smoothW = smoothW.map { $0 + (mV * mA / 1_000_000 - $0) * 0.2 } ?? mV * mA / 1_000_000
        if let m = [num("TimeRemaining"), num(charging ? "AvgTimeToFull" : "AvgTimeToEmpty")].compactMap({ $0 }).first(where: { $0 > 0 && $0 < 65535 }) { det.minutes = Int(m) }
        else if let cur = num("AppleRawCurrentCapacity"), let full = num("AppleRawMaxCapacity"), let w = smoothW, abs(w) > 1 {
            let wh = cur * mV / 1_000_000, fullWh = full * mV / 1_000_000
            let m = charging ? (w > 0 ? (fullWh - wh) / w * 60 : 0) : (w < 0 ? wh / -w * 60 : 0)
            if m >= 1, m < 1500 { det.minutes = Int(m.rounded()) }
        }
        if (d["ExternalConnected"] as? Bool) == true, let w = (d["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber { det.adapterW = w.intValue }
        if let cur = num("AppleRawCurrentCapacity") { det.wh = cur * mV / 1_000_000 }
        state.set(batDetail: det)
    }

}
