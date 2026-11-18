// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Foundation

/// The volume and the microphone as the atom and its card show them. Written only by `VolumeEngine` (what CoreAudio reports) and by the
/// helpers in Audio.swift (what the user just set); a setter that changes nothing publishes nothing.
final class VolumeState: ObservableObject {
    static let shared = VolumeState()
    @Published private(set) var volume = 0               // %
    @Published private(set) var muted = false
    @Published private(set) var mic = -1                 // default input's level in %, -1: it has none
    @Published private(set) var micMuted = false

    func set(mic v: Int, muted m: Bool) { if v != mic { mic = v }; if m != micMuted { micMuted = m } }
    func set(volume v: Int, muted m: Bool) { if v != volume { volume = v }; if m != muted { muted = m } }
}
