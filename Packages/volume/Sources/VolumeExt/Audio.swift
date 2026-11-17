// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import CoreAudio
import AppKit
import RiskellKit

/// Plain CoreAudio helpers: the default devices, their volume and mute, the device lists. Everything the bar needs at rest is event-driven
/// (VolumeEngine listens for changes); this file is what the volume atom's wheel / right-click and the mixer card use to change things.
enum AudioHW {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ el: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
    }
    static let vmvc: AudioObjectPropertySelector = 0x766D7663    // 'vmvc' VirtualMainVolume

    static func defaultDevice(input: Bool) -> AudioObjectID {
        var dev = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = addr(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(system, &a, 0, nil, &size, &dev)
        return dev
    }
    static func setDefault(_ id: AudioObjectID, input: Bool) {
        var d = id; var a = addr(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &d)
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel); var s: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr else { return nil }
        return s?.takeRetainedValue() as String?
    }
    static func uint32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = addr(sel, scope); var v: UInt32 = 0; var size = UInt32(4)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func channels(_ dev: AudioObjectID, input: Bool) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    struct Device: Identifiable, Equatable { let id: AudioObjectID; let name: String; let uid: String; let transport: UInt32 }
    static func devices(input: Bool) -> [Device] {
        var a = addr(kAudioHardwarePropertyDevices); var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard channels(id, input: input) > 0, uint32(id, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeAggregate else { return nil }
            return Device(id: id, name: Demo.device(string(id, kAudioObjectPropertyName) ?? "Device \(id)"), uid: string(id, kAudioDevicePropertyDeviceUID) ?? "", transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0)
        }
    }

    // MARK: volume and mute

    static func volume(_ dev: AudioObjectID, input: Bool) -> Float? {
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        for el in [kAudioObjectPropertyElementMain, 1] as [UInt32] {
            for sel in [vmvc, kAudioDevicePropertyVolumeScalar] {
                var a = addr(sel, scope, el), v = Float32(0), size = UInt32(4)
                if AudioObjectHasProperty(dev, &a), AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr { return v }
            }
        }
        return nil
    }
    @discardableResult
    static func setVolume(_ v: Float, _ dev: AudioObjectID, input: Bool) -> Bool {
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, val = max(0, min(1, v))
        var done = false
        for sel in [vmvc, kAudioDevicePropertyVolumeScalar] {
            for el in (sel == vmvc ? [kAudioObjectPropertyElementMain] : Array(0...2)) as [UInt32] {
                var a = addr(sel, scope, el), x = val
                var settable = DarwinBoolean(false)
                if AudioObjectHasProperty(dev, &a), AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue,
                   AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &x) == noErr { done = true }
            }
            if done { break }
        }
        return done
    }
    static func muted(_ dev: AudioObjectID, input: Bool) -> Bool? {
        var a = addr(kAudioDevicePropertyMute, input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput), v: UInt32 = 0, size = UInt32(4)
        for el in [kAudioObjectPropertyElementMain, 1] as [UInt32] {
            a.mElement = el
            if AudioObjectHasProperty(dev, &a), AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr { return v != 0 }
        }
        return nil
    }
    static func setMuted(_ m: Bool, _ dev: AudioObjectID, input: Bool) {
        var x: UInt32 = m ? 1 : 0
        for el in [kAudioObjectPropertyElementMain, 0, 1, 2] as [UInt32] {
            var a = addr(kAudioDevicePropertyMute, input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, el)
            var settable = DarwinBoolean(false)
            if AudioObjectHasProperty(dev, &a), AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue { AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &x) }
        }
    }
}

/// What the volume atom does to the master volume: the wheel steps it, right-click mutes. The store is updated at once; CoreAudio's own
/// listeners (Sys) then confirm it.
enum Volume {
    static func step(_ d: Int) {
        let dev = AudioHW.defaultDevice(input: false)
        let v = max(0, min(100, VolumeState.shared.volume + d))
        if AudioHW.setVolume(Float(v) / 100, dev, input: false) { VolumeState.shared.set(volume: v, muted: VolumeState.shared.muted && v == 0) }
        if v > 0, VolumeState.shared.muted { AudioHW.setMuted(false, dev, input: false) }
    }
    static func set(_ pct: Int) {
        let dev = AudioHW.defaultDevice(input: false), v = max(0, min(100, pct))
        if AudioHW.setVolume(Float(v) / 100, dev, input: false) { VolumeState.shared.set(volume: v, muted: VolumeState.shared.muted) }
    }
    static func toggleMute() {
        let dev = AudioHW.defaultDevice(input: false)
        AudioHW.setMuted(!VolumeState.shared.muted, dev, input: false)
        VolumeState.shared.set(volume: VolumeState.shared.volume, muted: !VolumeState.shared.muted)
    }
    static func toggleMicMute() {
        let dev = AudioHW.defaultDevice(input: true)
        AudioHW.setMuted(!VolumeState.shared.micMuted, dev, input: true)
        VolumeState.shared.set(mic: VolumeState.shared.mic, muted: !VolumeState.shared.micMuted)
    }
    static func setMic(_ pct: Int) {
        let dev = AudioHW.defaultDevice(input: true), v = max(0, min(100, pct))
        if AudioHW.setVolume(Float(v) / 100, dev, input: true) { VolumeState.shared.set(mic: v, muted: VolumeState.shared.micMuted) }
    }
}
