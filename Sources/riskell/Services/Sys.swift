import Foundation
import IOKit
import IOKit.ps
import CoreAudio
import RiskellKit

/// In-process readers: no forks. CPU and memory are sampled on one 2 s timer (the only steady wake); battery and volume are event-driven.
final class Sys {
    private let store: Store
    var onTick: (() -> Void)?            // other in-process samplers that share the 2 s tick
    private var timer: Timer?
    private var lastHist = Date.distantPast
    private var batSource: CFRunLoopSource?
    private var smoothW: Double?

    init(store: Store) { self.store = store }

    func start() {
        sampleCPU(); readBattery(); readPower(); readVolume(); readMic()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sampleCPU(); self?.readPower(); self?.onTick?() }
        timer?.tolerance = 0.5
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        batSource = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<Sys>.fromOpaque(ctx).takeUnretainedValue()
            me.readBattery(); me.readPower()
        }, ctx).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), batSource, .defaultMode)
        listenVolume()
    }

    func stop() { timer?.invalidate(); if let s = batSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) } }

    // MARK: CPU + memory

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
        var cpu = store.cpu, cores = store.cores
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
        store.set(cores: cores)

        var vm = vm_statistics64()
        var vcount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vcount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vcount) }
        }
        var mem = store.mem
        if vr == KERN_SUCCESS {
            // Activity Monitor's "Memory Used": app memory + wired + compressed
            let pages = UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            let bytes = Double(pages) * Double(vm_kernel_page_size), total = Double(ProcessInfo.processInfo.physicalMemory)
            mem = Int((bytes / total * 100).rounded())
            store.set(memUsedG: (bytes / 1_073_741_824 * 10).rounded() / 10, totalG: (total / 1_073_741_824 * 10).rounded() / 10)
        }
        store.set(cpu: cpu, mem: mem)
    }

    // MARK: battery

    private func readBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let pct = d[kIOPSCurrentCapacityKey] as? Int
            let ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            store.set(battery: pct, onAC: ac, charging: (d[kIOPSIsChargingKey] as? Bool) ?? false)
            return
        }
        store.set(battery: nil, onAC: true, charging: false)
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
        store.set(powerW: mV * mA / 1_000_000)
        if Date().timeIntervalSince(lastHist) >= 5 { lastHist = Date(); store.push(power: mV * mA / 1_000_000) }
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
        store.set(batDetail: det)
    }

    // MARK: volume

    private func addr(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func outputDevice() -> AudioObjectID {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
        return dev
    }
    private func readVolume() {
        let dev = outputDevice()
        guard dev != kAudioObjectUnknown else { return }
        var vol = Float32(0), muted = UInt32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var va = addr(0x766D7663 /* 'vmvc' VirtualMainVolume */, scope: kAudioDevicePropertyScopeOutput)
        AudioObjectGetPropertyData(dev, &va, 0, nil, &size, &vol)
        var msize = UInt32(MemoryLayout<UInt32>.size)
        var ma = addr(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(dev, &ma) { AudioObjectGetPropertyData(dev, &ma, 0, nil, &msize, &muted) }
        store.set(volume: Int((vol * 100).rounded()), muted: muted != 0)
    }
    /// The default microphone's level and mute (the volume atom's caption).
    private func readMic() {
        let dev = AudioHW.defaultDevice(input: true)
        guard dev != kAudioObjectUnknown else { store.set(mic: -1, muted: false); return }
        store.set(mic: AudioHW.volume(dev, input: true).map { Int(($0 * 100).rounded()) } ?? -1, muted: AudioHW.muted(dev, input: true) ?? false)
    }
    private func listenVolume() {
        let q = DispatchQueue.main
        func hook(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ then: @escaping () -> Void) {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectHasProperty(obj, &a) { AudioObjectAddPropertyListenerBlock(obj, &a, q) { _, _ in then() } }
        }
        func hookDevice() {
            let dev = outputDevice()
            hook(dev, 0x766D7663, kAudioDevicePropertyScopeOutput) { [weak self] in self?.readVolume() }
            hook(dev, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput) { [weak self] in self?.readVolume() }
        }
        func hookMic() {
            let dev = AudioHW.defaultDevice(input: true)
            for el in [kAudioObjectPropertyElementMain, 1] as [UInt32] {
                for sel in [AudioHW.vmvc, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeInput, mElement: el)
                    if AudioObjectHasProperty(dev, &a) { AudioObjectAddPropertyListenerBlock(dev, &a, q) { [weak self] _, _ in self?.readMic() } }
                }
            }
        }
        hookDevice(); hookMic()
        hook(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal) { [weak self] in
            self?.readVolume(); hookDevice()
        }
        hook(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal) { [weak self] in
            self?.readMic(); hookMic()
        }
    }
}
