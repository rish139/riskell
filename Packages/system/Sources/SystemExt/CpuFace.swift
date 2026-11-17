// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// The core deck: CPU % with a meter (85 % notch), the ten cores as √-scaled columns (2 efficiency | 4 | 4 performance, hairline rules
/// between clusters), RAM % with its meter and GB, and the signed power draw with its 3-minute trace. Hover runs a wave through the
/// deck, swells and gleams the meters and warms the captions. Click-free: hover opens the vitals card, right-click opens Activity Monitor.
/// On the left strip (`vertical`) it stands up as a column of the same modules: CPU, the core deck, RAM, then PW with its trace, each
/// module a caption over its figure over a short bar, separated by the strip's hairline. Same data, tones and hover.
struct CpuFace: View {
    @ObservedObject private var gauges = SystemGauges.shared      // redraws on the timer-driven numbers
    @State private var hot = false
    @State private var phase: Double = 1
    let vertical: Bool

    var body: some View {
        let cpuTone = Pal.heat(Double(gauges.cpu) / 100), ramTone = Pal.heat(Double(gauges.mem) / 100)
        let p = gauges.powerW ?? 0
        Group {
            if vertical {
                VStack(spacing: 0) {
                    Stat(cap: "CPU", value: String(gauges.cpu), tone: cpuTone, fraction: Double(gauges.cpu) / 100, hot: hot)
                    Rule()
                    CoreDeck(cores: gauges.cores, phase: phase, vertical: true)
                    Rule()
                    Stat(cap: "RAM", value: String(gauges.mem), tone: ramTone, fraction: Double(gauges.mem) / 100, hot: hot)
                    if gauges.powerW != nil {
                        Rule()
                        VStack(spacing: 0) {
                            Cap(text: "PW", hot: hot)
                            Color.clear.frame(height: 3)
                            // 40 pt: whole watts from 10 up ("−16 W"), one decimal below ("−8.0 W")
                            Num(value: (p >= 0 ? "+" : "−") + String(format: abs(p) >= 10 ? "%.0f" : "%.1f", abs(p)), unit: "W")
                            Color.clear.frame(height: T.gap)
                            PowerTrace(hist: gauges.powerHist).frame(width: 38, height: 15)
                            Color.clear.frame(height: 6)      // the pill's bottom edge is not the trace's baseline
                        }
                    }
                }
                .fixedSize()
                .frame(width: 40)
            } else {
                HStack(spacing: T.gap) {
                    Cap(text: "CPU", hot: hot)
                    Num(value: String(gauges.cpu), unit: "%", tone: cpuTone)
                    Bar(value: Double(gauges.cpu) / 100, tone: cpuTone, hot: hot, width: 34)
                    Sep(height: 18).padding(.horizontal, 5)
                    CoreDeck(cores: gauges.cores, phase: phase)
                    Sep(height: 18).padding(.horizontal, 5)
                    Cap(text: "RAM", hot: hot)
                    Num(value: String(gauges.mem), unit: "%", tone: ramTone)
                    Bar(value: Double(gauges.mem) / 100, tone: ramTone, hot: hot, width: 34)
                    if gauges.powerW != nil {
                        Sep(height: 18).padding(.horizontal, 5)
                        Cap(text: "PW", hot: hot)
                        Num(value: (p >= 0 ? "+" : "−") + String(format: "%.1f", abs(p)), unit: "W")
                        PowerTrace(hist: gauges.powerHist).frame(width: 38, height: 15)
                    }
                }
                .frame(height: G.pill)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hot)
        .onRightClick { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
        .popout("vitals", edge: .above, hot: $hot)
        .onChange(of: hot) { _, h in
            guard h else { return }
            phase = 0
            withAnimation(.linear(duration: 0.64)) { phase = 1 }
        }
    }

}

/// A module on the strip, as the volume and network columns: the caption on top, a vertical gauge in the middle, the figure under it.
private struct Stat: View {
    let cap: String, value: String, tone: Color, fraction: Double, hot: Bool
    var body: some View {
        VStack(spacing: 0) {
            Cap(text: cap, hot: hot)
            Color.clear.frame(height: 4)
            VGauge(value: fraction, tone: tone, hot: hot, length: 30)
            Color.clear.frame(height: T.gap)
            Num(value: value, unit: "%", tone: tone)
        }
    }
}

/// Ten columns, height ~ √(load), each lifted by a half sine travelling left to right while `phase` runs 0 -> 1.
/// `vertical`: the same ten, in a 36 pt row (narrower columns and gaps) for the 40 pt strip.
private struct CoreDeck: View, Animatable {
    let cores: [Int]
    var phase: Double
    var vertical = false
    var animatableData: Double { get { phase } set { phase = newValue } }
    private static let clusters = [[0, 1], [2, 3, 4, 5], [6, 7, 8, 9]]
    private func bump(_ i: Int) -> CGFloat {
        let t = phase * 2 - Double(i) * 0.1
        return t <= 0 || t >= 1 ? 0 : CGFloat(sin(Double.pi * t))
    }
    var body: some View {
        let col: CGFloat = vertical ? 2.2 : 3.4, inner: CGFloat = vertical ? 1 : 1.7, outer: CGFloat = vertical ? 1.5 : 2
        HStack(spacing: outer) {
            ForEach(Self.clusters.indices, id: \.self) { c in
                HStack(spacing: inner) {
                    ForEach(Self.clusters[c], id: \.self) { i in
                        let v = i < cores.count ? Double(cores[i]) / 100 : 0
                        let h: CGFloat = 20 + 5.6 * bump(i)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1.4).fill(Pal.groove)
                            RoundedRectangle(cornerRadius: 1.4).fill(Pal.heat(v)).frame(height: max(1, h * CGFloat(sqrt(min(1, max(0, v))))))
                        }.frame(width: col, height: h)
                    }
                    if c < 2 { Rectangle().fill(Pal.hairline).frame(width: 1, height: 20) }
                }
            }
        }.frame(height: 26)
    }
}

/// Three minutes of the 5 s power samples as 1 px columns, the newest in the accent.
private struct PowerTrace: View {
    let hist: [Double]
    var body: some View {
        Canvas { ctx, size in
            let slots = 20, n = min(slots, hist.count), step = size.width / CGFloat(slots)
            ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Pal.groove))
            let peak = max(0.5, hist.map { abs($0) }.max() ?? 0.5)
            for i in 0..<n {
                let v = abs(hist[hist.count - n + i])
                let h = max(1, (size.height * CGFloat(min(1, v / peak))).rounded())
                let x = (size.width - CGFloat(n - i) * step).rounded()
                ctx.fill(Path(CGRect(x: x, y: size.height - h, width: max(1, (step - 0.8).rounded()), height: h)),
                         with: .color(i == n - 1 ? Pal.accent : Pal.amberDim))
            }
        }
    }
}

/// The CPU atom: the core deck and the figures in both forms, and the vitals card (STATS) on hover. Its numbers come from the package's
/// `SystemEngine`, which runs only while this atom is on a showing bar.
public struct CpuAtom: CustomAtom {
    public static let meta = AtomMeta(id: "cpu", name: "CPU", priority: 5, maxWidth: 460)
    public init() {}
    public func horizontal(_ env: Env) -> some View { CpuFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { CpuFace(vertical: true) }
    public var card: Card? { Card(id: "vitals", size: { _ in VitalsCard.size }) { VitalsCard() } }
    public func activate(_ env: Env) -> (() -> Void)? { SystemEngine.shared.retainAll(env) }
}
