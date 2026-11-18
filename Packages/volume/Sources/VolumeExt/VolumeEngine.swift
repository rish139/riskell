// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Foundation
import CoreAudio

/// The volume and the default microphone, read from CoreAudio and kept current by its property listeners, so nothing polls. The atom starts
/// it when it appears on a showing bar and calls `stop` when the last one leaves. The listeners are installed once and stay (CoreAudio
/// listener blocks cannot easily be removed), so while stopped they fire and read nothing.
final class VolumeEngine {
    static let shared = VolumeEngine()
    private var running = false
    private var listening = false

    func start() {
        guard !running else { return }
        running = true
        readVolume(); readMic()
        if !listening { listening = true; listenVolume() }
    }

    func stop() { running = false }

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
        VolumeState.shared.set(volume: Int((vol * 100).rounded()), muted: muted != 0)
    }
    /// The default microphone's level and mute (the volume atom's caption).
    private func readMic() {
        guard running else { return }
        let dev = AudioHW.defaultDevice(input: true)
        guard dev != kAudioObjectUnknown else { VolumeState.shared.set(mic: -1, muted: false); return }
        VolumeState.shared.set(mic: AudioHW.volume(dev, input: true).map { Int(($0 * 100).rounded()) } ?? -1, muted: AudioHW.muted(dev, input: true) ?? false)
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
