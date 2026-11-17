// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import AppKit
import RiskellKit

struct LoudSample: Equatable { let t: TimeInterval; let db: Double; let vol: Double }   // NaN db = a gap (the card was closed, or nothing to measure)
struct AudioStream: Identifiable, Equatable {
    let id: String                  // the app's name: helper processes of one app are one stream
    let pid: Int32
    let objectIDs: [AudioObjectID]
    let name: String
    let bundle: String
    var gain: Double                // 0...1, this app's own volume (1 = untouched, no tap)
    var level: Double = 0           // 0...1 on a dB scale, while a tap is on it
    var muted: Bool { gain <= 0.001 }
}

/// A CoreAudio process tap read through a private aggregate device: `peaks()` gives the loudest sample per channel since the last call.
/// Tapping what is playing needs the "System Audio Recording" permission (asked once, the bundle's purpose string says why); without it
/// the tap delivers silence, which shows as "no signal". Used for the default output's level meter (while the mixer card is open) and,
/// with `playback: true`, as a per-app volume: the app is muted at the source and its audio is played straight back through the default
/// output at `gain`, so the app sounds as if it had its own volume control.
final class AudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown), aggID = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var pL: Float = 0, pR: Float = 0
    private var g: Float = 1
    private(set) var ok = false
    /// Called on the main queue at most every 0.125 s, from the audio callback itself: the meter steps when sound data arrives, so the card needs no
    /// clock of its own while a tap is running.
    var onKick: (() -> Void)?
    private var lastKick: UInt64 = 0
    var gain: Double { get { lock.lock(); defer { lock.unlock() }; return Double(g) } set { lock.lock(); g = Float(max(0, min(1, newValue))); lock.unlock() } }

    /// processes == nil: everything that plays (a stereo mixdown of the whole output). Otherwise just those processes.
    init(processes: [AudioObjectID]?, playback: Bool, gain: Double = 1) {
        guard #available(macOS 14.2, *) else { return }
        self.g = Float(gain)
        let desc = processes.map { CATapDescription(stereoMixdownOfProcesses: $0) } ?? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "riskell"
        desc.isPrivate = true
        desc.muteBehavior = playback ? CATapMuteBehavior.muted : CATapMuteBehavior.unmuted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return }
        let out = AudioHW.defaultDevice(input: false)
        guard let outUID = AudioHW.string(out, kAudioDevicePropertyDeviceUID) else { destroy(); return }
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "riskell tap",
            kAudioAggregateDeviceUIDKey: "riskell-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID) == noErr else { destroy(); return }
        let q = DispatchQueue(label: "riskell.tap", qos: .userInitiated)
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, q) { [weak self] _, inData, _, outData, _ in
            guard let self else { return }
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            // the tap's stream is the LAST of the aggregate's inputs (a sub-device with its own inputs comes first)
            var l: UnsafeMutablePointer<Float>?, r: UnsafeMutablePointer<Float>?, ls = 1, rs = 1, frames = 0
            if ins.count >= 2, ins[ins.count - 2].mNumberChannels == 1, ins[ins.count - 1].mNumberChannels == 1 {
                l = ins[ins.count - 2].mData?.assumingMemoryBound(to: Float.self); r = ins[ins.count - 1].mData?.assumingMemoryBound(to: Float.self)
                frames = Int(ins[ins.count - 1].mDataByteSize / 4)
            } else if let b = ins.last, b.mNumberChannels >= 2, let d = b.mData {
                let f = d.assumingMemoryBound(to: Float.self); l = f; r = f + 1; ls = Int(b.mNumberChannels); rs = ls; frames = Int(b.mDataByteSize) / 4 / ls
            } else if let b = ins.last, let d = b.mData { l = d.assumingMemoryBound(to: Float.self); r = l; frames = Int(b.mDataByteSize / 4) }
            guard let l, let r, frames > 0 else { return }
            var pl: Float = 0, pr: Float = 0
            vDSP_maxmgv(l, vDSP_Stride(ls), &pl, vDSP_Length(frames)); vDSP_maxmgv(r, vDSP_Stride(rs), &pr, vDSP_Length(frames))
            self.lock.lock(); self.pL = max(self.pL, pl); self.pR = max(self.pR, pr); let gain = self.g; self.lock.unlock()
            if let kick = self.onKick {
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- self.lastKick >= 125_000_000 { self.lastKick = now; DispatchQueue.main.async { kick() } }
            }
            guard playback else { return }
            let outs = UnsafeMutableAudioBufferListPointer(outData)
            for (i, ob) in outs.enumerated() {
                guard let od = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = Int(ob.mNumberChannels), n = min(frames, Int(ob.mDataByteSize / 4) / max(1, ch))
                if ch >= 2 {                      // interleaved output: L R (other channels silent)
                    for f in 0..<n { od[f * ch] = l[f * ls] * gain; od[f * ch + 1] = r[f * rs] * gain; for c in 2..<max(2, ch) { od[f * ch + c] = 0 } }
                } else if i < 2 {                 // planar output: one buffer per channel
                    let src = i == 0 ? l : r, st = i == 0 ? ls : rs
                    for f in 0..<n { od[f] = src[f * st] * gain }
                }
            }
        }
        guard status == noErr, let proc, AudioDeviceStart(aggID, proc) == noErr else { destroy(); return }
        ok = true
    }

    func peaks() -> (Float, Float) {
        lock.lock(); defer { lock.unlock(); }
        let v = (pL, pR); pL = 0; pR = 0; return v
    }

    func destroy() {
        if let proc, aggID != kAudioObjectUnknown { AudioDeviceStop(aggID, proc); AudioDeviceDestroyIOProcID(aggID, proc) }
        proc = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
        ok = false
    }
    deinit { destroy() }
}

/// The mixer card's data: default devices and their lists, the mic, what is playing and how loud, and the apps making sound. Read ONLY
/// while the card is open (start/stop), except the per-app mutes, which stay in force until you lift them.
final class Mixer: ObservableObject {
    static let shared = Mixer()

    private(set) var outs: [AudioHW.Device] = [], ins: [AudioHW.Device] = []
    private(set) var defOut = AudioObjectID(0), defIn = AudioObjectID(0)
    private(set) var levelL = 0.0, levelR = 0.0          // 0...1 on a dB scale, with a quick fall
    private(set) var dbL = -99.0, dbR = -99.0
    private(set) var hist: [LoudSample] = []
    private(set) var meterable = false
    private(set) var streams: [AudioStream] = []

    private var sink: AudioTap?
    private var users = 0, tick = 0, wasQuiet = false
    private var peakAcc = 0.0                             // the loudest peak since the last history sample
    private var appTaps: [String: (tap: AudioTap, ids: [AudioObjectID], pid: Int32, bundle: String, name: String)] = [:]
    private var lastGain: [String: Double] = [:]       // what a muted app goes back to
    private var levels: [String: Double] = [:]
    private var iconCache: [String: (String, NSImage?)] = [:]

    func start() {
        users += 1
        guard users == 1 else { return }
        tick = 0
        if Demo.on && hist.isEmpty {      // screenshots: a minute of plausible loudness, so the graph is not empty
            let now = Date().timeIntervalSince1970
            hist = (0..<240).map { i in LoudSample(t: now - Double(240 - i) * 0.25, db: Demo.dbAt(i), vol: Double(VolumeState.shared.volume)) }
        }
        if let last = hist.last, Date().timeIntervalSince1970 - last.t > 1 { hist.append(LoudSample(t: Date().timeIntervalSince1970, db: .nan, vol: Double(VolumeState.shared.volume))) }
        if ProcessInfo.processInfo.environment["RK_NO_TAP"] == nil { sink = AudioTap(processes: nil, playback: false); meterable = sink?.ok ?? false; sink?.onKick = { [weak self] in self?.kick() } }
        refreshDevices(); refreshStreams()
    }
    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        sink?.destroy(); sink = nil; meterable = false
        levelL = 0; levelR = 0
    }

    private static func db(_ p: Float) -> Double { p > 1e-5 ? max(-60, 20 * log10(Double(p))) : -99 }

    /// The tap's audio callback asks for a step (see `AudioTap.onKick`); only while the card is open.
    func kick() { if users > 0 { step() } }

    /// One meter step: every 0.125 s while the card is open, from the tap's audio callback (or the card's `MeterClock` when there is no tap).
    func step() {
        tick += 1
        let now = Date().timeIntervalSince1970
        if let s = sink {
            let (l, r) = s.peaks()
            dbL = Self.db(l); dbR = Self.db(r)
            let fall = 0.82
            levelL = max(max(0, (dbL + 50) / 50), levelL * fall); levelR = max(max(0, (dbR + 50) / 50), levelR * fall)
            peakAcc = max(peakAcc, Double(max(l, r)))
        }
        if tick % 2 == 0 {            // the history: one sample per 250 ms, the loudest peak in it
            let d = meterable ? Self.db(Float(peakAcc)) : .nan
            peakAcc = 0
            hist.append(LoudSample(t: now, db: d.isNaN ? .nan : max(-50, d), vol: Double(VolumeState.shared.volume)))
            hist.removeAll { $0.t < now - 75 }
        }
        for (k, t) in appTaps {      // each tapped app's own level
            let (l, r) = t.tap.peaks(); levels[k] = max(max(0, (Self.db(max(l, r)) + 50) / 50), (levels[k] ?? 0) * 0.82)
        }
        if !appTaps.isEmpty { streams = streams.map { var x = $0; x.level = levels[$0.id] ?? 0; return x } }
        if tick % 8 == 0 { refreshStreams() }
        if tick % 16 == 1 { refreshDevices() }
        // silence: nothing moves between history samples (every other step), so the card is redrawn at 4 Hz instead of 8 Hz
        let quiet = levelL < 0.005 && levelR < 0.005 && wasQuiet && appTaps.isEmpty
        wasQuiet = levelL < 0.005 && levelR < 0.005
        if !quiet || tick % 2 == 0 { objectWillChange.send() }
    }

    // MARK: devices

    func refreshDevices() {
        outs = AudioHW.devices(input: false); ins = AudioHW.devices(input: true)
        let was = defOut
        defOut = AudioHW.defaultDevice(input: false); defIn = AudioHW.defaultDevice(input: true)
        if was != 0, was != defOut { rebuildTaps() }
    }
    func setOutput(_ d: AudioHW.Device) { AudioHW.setDefault(d.id, input: false); defOut = d.id; objectWillChange.send() }
    func setInput(_ d: AudioHW.Device) { AudioHW.setDefault(d.id, input: true); defIn = d.id; objectWillChange.send() }

    // MARK: streams: the apps that are producing sound right now, each with its own volume

    func refreshStreams() {
        guard #available(macOS 14.2, *) else { return }
        var a = AudioHW.addr(kAudioHardwarePropertyProcessObjectList), size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioHW.system, &a, 0, nil, &size) == noErr else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioHW.system, &a, 0, nil, &size, &ids) == noErr else { return }
        var seen: [String: AudioStream] = [:]
        for id in ids {
            guard (AudioHW.uint32(id, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0 else { continue }
            let pid = Int32(bitPattern: AudioHW.uint32(id, kAudioProcessPropertyPID) ?? 0), bundle = AudioHW.string(id, kAudioProcessPropertyBundleID) ?? ""
            if pid == ProcessInfo.processInfo.processIdentifier { continue }      // our own taps show up as an output
            let (name, _) = appInfo(bundle: bundle, pid: pid), key = name
            if let x = seen[key] { seen[key] = AudioStream(id: key, pid: x.pid, objectIDs: x.objectIDs + [id], name: x.name, bundle: x.bundle, gain: x.gain) }
            else { seen[key] = AudioStream(id: key, pid: pid, objectIDs: [id], name: name, bundle: bundle, gain: appTaps[key]?.tap.gain ?? 1) }
        }
        // an app with its own volume keeps its row while it is quiet, so the volume can be put back; a quit app loses its tap
        for (k, t) in appTaps where seen[k] == nil {
            if NSRunningApplication(processIdentifier: t.pid) == nil { t.tap.destroy(); appTaps[k] = nil; continue }
            seen[k] = AudioStream(id: k, pid: t.pid, objectIDs: t.ids, name: t.name, bundle: t.bundle, gain: t.tap.gain)
        }
        // a tap built for the old process list does not cover a new helper process: build it again
        for (k, st) in seen { if let t = appTaps[k], Set(t.ids) != Set(st.objectIDs), !st.objectIDs.isEmpty, t.tap.gain < 1 { setGain(st, t.tap.gain) } }
        var list = seen.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for i in list.indices { list[i].level = levels[list[i].id] ?? 0 }
        if list != streams { streams = list }
    }

    /// The app a (possibly helper) audio process belongs to: its own bundle, else the longest prefix of its bundle id that is an app.
    func appInfo(bundle: String, pid: Int32) -> (String, NSImage?) {
        if let c = iconCache[bundle], !bundle.isEmpty { return c }
        var parts = bundle.split(separator: ".").map(String.init)
        var result: (String, NSImage?)? = nil
        while !parts.isEmpty, result == nil {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) {
                result = (FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: ""), NSWorkspace.shared.icon(forFile: u.path))
            }
            parts.removeLast()
        }
        let r = result.map { (Demo.process($0.0), $0.1) } ?? (Demo.process(NSRunningApplication(processIdentifier: pid)?.localizedName ?? (bundle.isEmpty ? "pid \(pid)" : bundle)), NSRunningApplication(processIdentifier: pid)?.icon)
        if !bundle.isEmpty { iconCache[bundle] = r }
        return r
    }
    func icon(_ s: AudioStream) -> NSImage? { appInfo(bundle: s.bundle, pid: s.pid).1 }

    /// An app's own volume: below 100 % the app is tapped (muted at the source) and played back at this gain; at 100 % the tap goes away.
    func setGain(_ s: AudioStream, _ gain: Double) {
        let g = max(0, min(1, gain))
        if g >= 0.995 { if let t = appTaps.removeValue(forKey: s.id) { t.tap.destroy() }; levels[s.id] = nil }
        else {
            if let t = appTaps[s.id], Set(t.ids) == Set(s.objectIDs) { t.tap.gain = g }
            else {
                appTaps[s.id]?.tap.destroy()
                let t = AudioTap(processes: s.objectIDs, playback: true, gain: g)
                if t.ok { appTaps[s.id] = (t, s.objectIDs, s.pid, s.bundle, s.name) } else { appTaps[s.id] = nil }
            }
            if g > 0.001 { lastGain[s.id] = g }
        }
        streams = streams.map { var x = $0; if x.id == s.id { x.gain = appTaps[s.id]?.tap.gain ?? 1 }; return x }
        objectWillChange.send()
    }
    func toggleMute(_ s: AudioStream) { setGain(s, s.muted ? (lastGain[s.id] ?? 1) : 0) }

    /// The default output changed: every tap plays through the old one, so build them again against the new one.
    private func rebuildTaps() {
        let old = appTaps; appTaps = [:]
        for (_, t) in old { t.tap.destroy() }
        for (k, t) in old { setGain(AudioStream(id: k, pid: t.pid, objectIDs: t.ids, name: t.name, bundle: t.bundle, gain: 1), t.tap.gain) }
    }
}
