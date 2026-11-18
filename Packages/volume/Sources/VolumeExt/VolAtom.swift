// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// The volume atom: the step glyph, a bar, the figure, and the microphone beside it. The card is the mixer.
public struct VolAtom: CustomAtom {
    public static let meta = AtomMeta(id: "vol", name: "Volume", priority: 4, maxWidth: 220)
    public init() {}
    public func horizontal(_ env: Env) -> some View { VolFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { VolFace(vertical: true) }
    public var card: Card? { Card(id: "vol", size: { _ in VolumeCard.size }) { VolumeCard() } }
    public func activate(_ env: Env) -> (() -> Void)? {
        VolumeEngine.shared.start()
        return { VolumeEngine.shared.stop() }
    }
}

/// The volume: the step glyph, a bar, the figure. Muted turns the glyph slashed, the bar red-tinted and the figure "--"; a muted
/// microphone shows small beside the figure (a blue mic and its level while live, a red slashed mic when muted). Hover pops the glyph and
/// thickens the bar; right-click mutes, hover opens the mixer.
struct VolFace: View {
    @ObservedObject private var s = VolumeState.shared
    @State private var hot = false
    let vertical: Bool

    var body: some View {
        let muted = s.muted, level = max(0, min(100, s.volume))
        let glyph = muted ? "speaker.slash.fill" : level >= 50 ? "speaker.wave.3.fill" : level >= 20 ? "speaker.wave.2.fill" : "speaker.wave.1.fill"
        Group {
            if vertical {
                // The left strip: a column. The step glyph, the figure, a short level bar, then the microphone (glyph and level, or a red slashed mic).
                VStack(spacing: 0) {
                    Image(systemName: glyph).font(Pal.font(13, .semibold))
                        .foregroundStyle(muted ? Pal.text4 : Pal.accent)
                        .scaleEffect(hot ? 1.15 : 1).frame(height: 16)
                    Color.clear.frame(height: T.gap)
                    VGauge(value: muted ? 0 : Double(level) / 100, tone: muted ? Pal.crit : Pal.accent, hot: hot)
                    Color.clear.frame(height: T.gap)
                    Num(value: muted ? "--" : String(level), unit: muted ? nil : "%", tone: muted ? Pal.crit : Pal.text1, hot: hot && !muted)
                    if s.mic >= 0 {
                        Color.clear.frame(height: T.gap)
                        HStack(spacing: 2) {
                            Image(systemName: s.micMuted ? "mic.slash.fill" : "mic.fill").font(Pal.font(9.5, .semibold))
                            if !s.micMuted { Text("\(s.mic)%").font(T.sub) }
                        }.foregroundStyle(s.micMuted ? Pal.crit : Pal.info)
                    }
                }
                .fixedSize()
                .frame(width: 40)
            } else {
                HStack(spacing: T.gap) {
                    Image(systemName: glyph).font(Pal.font(13, .semibold))
                        .foregroundStyle(muted ? Pal.text4 : Pal.accent)
                        .scaleEffect(hot ? 1.15 : 1).frame(width: 20)
                    Bar(value: muted ? 0 : Double(level) / 100, tone: muted ? Pal.crit : Pal.accent, hot: hot, width: 52)
                    HStack(alignment: .center, spacing: 6) {      // the small mic readout is centred on the row of the big figure (not on its baseline)
                        Num(value: muted ? "--" : String(level), unit: muted ? nil : "%", tone: muted ? Pal.crit : Pal.text1, hot: hot && !muted)
                            .frame(minWidth: 30, alignment: .trailing)
                        if s.mic >= 0 {      // the microphone at a glance, small beside the figure: live in blue with its level, muted a red slashed mic
                            HStack(spacing: 2) {
                                Image(systemName: s.micMuted ? "mic.slash.fill" : "mic.fill").font(Pal.font(9.5, .semibold))
                                if !s.micMuted { Text("\(s.mic)%").font(Pal.font(11)) }
                            }.foregroundStyle(s.micMuted ? Pal.crit : Pal.info)
                        }
                    }
                }
                .frame(height: G.pill)
            }
        }
        .animation(.spring(duration: 0.26, bounce: 0.18), value: hot)
        .onRightClick { Volume.toggleMute() }
        .onScrollSteps { Volume.step($0) }
        .popout("vol", edge: .above, hot: $hot)
    }
}
