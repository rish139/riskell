import SwiftUI
import RiskellKit

/// Wheel over a view steps a value; this view only takes part in hit-testing while a scroll event is being delivered, so hover, taps and
/// right-clicks underneath keep working. Up (the way fingers or the wheel go, whatever the "natural scrolling" setting) raises.
struct ScrollStep: NSViewRepresentable {
    let step: (Int) -> Void
    func makeNSView(context: Context) -> NSView { let v = Catcher(); v.step = step; return v }
    func updateNSView(_ v: NSView, context: Context) { (v as? Catcher)?.step = step }
    final class Catcher: NSView {
        var step: ((Int) -> Void)?
        private var acc: CGFloat = 0
        override func hitTest(_ p: NSPoint) -> NSView? { NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(p) : nil }
        override func scrollWheel(with e: NSEvent) {
            let dy = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
            acc += e.hasPreciseScrollingDeltas ? dy / 6 : dy * 2        // a trackpad: 1 % per 6 px; a wheel notch: 2 %
            let n = Int(acc); if n != 0 { acc -= CGFloat(n); step?(n) }
        }
    }
}

/// The volume: the step glyph, a bar, the figure. Muted turns the glyph slashed, the bar red-tinted and the figure "--"; a muted
/// microphone shows small beside the figure (a blue mic and its level while live, a red slashed mic when muted). Hover pops the glyph and
/// thickens the bar; the wheel steps the volume, right-click mutes, hover opens the mixer.
struct VolAtom: View {
    @EnvironmentObject var s: Store
    @State private var hot = false
    let vertical: Bool

    var body: some View {
        let muted = s.muted, level = max(0, min(100, s.volume))
        let glyph = muted ? "speaker.slash.fill" : level >= 50 ? "speaker.wave.3.fill" : level >= 20 ? "speaker.wave.2.fill" : "speaker.wave.1.fill"
        Group {
            if vertical {
                // The left strip: a column. The step glyph, the figure, a short level bar, then the microphone (glyph and level, or a red slashed mic).
                VStack(spacing: 0) {
                    Image(systemName: glyph).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(muted ? Pal.text4 : Pal.accent)
                        .scaleEffect(hot ? 1.15 : 1).frame(height: 16)
                    Color.clear.frame(height: T.gap)
                    VGauge(value: muted ? 0 : Double(level) / 100, tone: muted ? Pal.crit : Pal.accent, hot: hot)
                    Color.clear.frame(height: T.gap)
                    Num(value: muted ? "--" : String(level), unit: muted ? nil : "%", tone: muted ? Pal.crit : Pal.text1, hot: hot && !muted)
                    if s.mic >= 0 {
                        Color.clear.frame(height: T.gap)
                        HStack(spacing: 2) {
                            Image(systemName: s.micMuted ? "mic.slash.fill" : "mic.fill").font(.system(size: 9.5, weight: .semibold))
                            if !s.micMuted { Text("\(s.mic)%").font(T.sub) }
                        }.foregroundStyle(s.micMuted ? Pal.crit : Pal.info)
                    }
                }
                .fixedSize()
                .frame(width: 40)
            } else {
                HStack(spacing: T.gap) {
                    Image(systemName: glyph).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(muted ? Pal.text4 : Pal.accent)
                        .scaleEffect(hot ? 1.15 : 1).frame(width: 20)
                    Bar(value: muted ? 0 : Double(level) / 100, tone: muted ? Pal.crit : Pal.accent, hot: hot, width: 52)
                    HStack(alignment: .center, spacing: 6) {      // the small mic readout is centred on the row of the big figure (not on its baseline)
                        Num(value: muted ? "--" : String(level), unit: muted ? nil : "%", tone: muted ? Pal.crit : Pal.text1, hot: hot && !muted)
                            .frame(minWidth: 30, alignment: .trailing)
                        if s.mic >= 0 {      // the microphone at a glance, small beside the figure: live in blue with its level, muted a red slashed mic
                            HStack(spacing: 2) {
                                Image(systemName: s.micMuted ? "mic.slash.fill" : "mic.fill").font(.system(size: 9.5, weight: .semibold))
                                if !s.micMuted { Text("\(s.mic)%").font(Pal.font(11)) }
                            }.foregroundStyle(s.micMuted ? Pal.crit : Pal.info)
                        }
                    }
                }
                .frame(height: G.pill)
            }
        }
        .animation(.spring(duration: 0.26, bounce: 0.18), value: hot)
        .overlay(RightClick { Volume.toggleMute() })
        .overlay(ScrollStep { Volume.step($0) })
        .popout("vol", edge: .above, hot: $hot)
    }
}
