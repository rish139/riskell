import Foundation
import IOKit
import IOKit.ps
import CoreAudio
import RiskellKit

/// In-process readers: no forks, no timer. The battery and the volume are event-driven (a power-source notification, audio property listeners).
/// CPU, memory, power and temperatures are read by the system package (Packages/system); this service is what the `.battery` and `.volume` feeds and
/// the volume atom read.
final class Sys {
    private let store: Store
    private var batSource: CFRunLoopSource?
    private var running = false          // the audio listeners are installed once and stay (they only fire on a change); while stopped they read nothing
    private var listening = false

    init(store: Store) { self.store = store }

    func start() {
        guard !running else { return }
        running = true
        readBattery(); readVolume(); readMic()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        batSource = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<Sys>.fromOpaque(ctx).takeUnretainedValue()
            me.readBattery()
        }, ctx).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), batSource, .defaultMode)
        if !listening { listening = true; listenVolume() }
    }

    func stop() {
        running = false
        if let s = batSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) }
        batSource = nil
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
        guard running else { return }
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
        guard running else { return }
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
