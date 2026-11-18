// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// FANS / THERMAL, read-only. The hero is the turbines themselves (one per fan): a 60-tick ring gauge lit by load with a notch at the fan's
/// target, a swept rotor spinning at a PERCEIVED speed (never the true ~100 rev/s, which would alias into a wagon-wheel strobe) with ghost
/// copies behind it for motion blur, and the rpm as the numeral in the hub. Below: three readings the turbines do not show (system power,
/// the battery's flow, CPU load) and the thermal chart: the last 30 minutes of every sensor group over a faint band of fan speed. The rows
/// under it are the legend: hover one to light its trace, click to hide it.
struct FanCard: View {
    @ObservedObject private var state = SystemState.shared      // the battery
    @ObservedObject private var gauges = SystemGauges.shared    // redraws on the timer-driven numbers (CPU load)
    @ObservedObject private var live = FanLive.shared
    @State private var hover: Int? = nil
    @State private var hoverRow: Int? = nil
    @State private var hidden = Set<Int>()

    static let pad: CGFloat = 16, width: CGFloat = 408
    static let size = CGSize(width: width, height: 531)
    static var tints: [Color] { [Pal.accent, Pal.text1, Pal.info, Pal.text3, Pal.amberDim, Pal.text4] }      // one warm hue, light and dim neutrals, one cool: no rainbow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Rectangle().fill(Pal.amberGhost).frame(height: 1)
            HStack(spacing: 12) {
                ForEach(Array(live.snap.fans.enumerated()), id: \.offset) { i, f in turbineBlock(i, f) }
            }.frame(maxWidth: .infinity).frame(height: 184)
            rail
            sensors
        }
        .padding(.horizontal, Self.pad).padding(.top, 11).padding(.bottom, 12)
        .frame(width: Self.width, alignment: .topLeading)
        .onAppear { FanLive.shared.start() }
        .onDisappear { FanLive.shared.stop() }
    }

    private func t(_ s: String, _ size: CGFloat, _ color: Color, bold: Bool = true, _ ls: CGFloat = 1.2) -> some View {
        Text(s).font(Pal.font(size, bold ? .bold : .regular)).tracking(ls).foregroundStyle(color)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            t("FANS", 10, Pal.amberDim, 2.6)
            Text("THERMAL").font(Pal.font(15, .bold)).foregroundStyle(Pal.text1)
            Spacer()
            Circle().fill(live.snap.fans.isEmpty ? Color.clear : Pal.accent).overlay(Circle().stroke(live.snap.fans.isEmpty ? Pal.text4 : .clear, lineWidth: 1))
                .frame(width: 7, height: 7)
        }.frame(height: 20)
    }

    private func turbineBlock(_ i: Int, _ f: FanInfo) -> some View {
        VStack(spacing: 3) {
            Turbine(rpm: f.rpm, target: f.target, minRPM: f.min, maxRPM: f.max).frame(width: 156, height: 156)
            t("FAN \(i + 1)", 9, Pal.amberDim, 1.8)
            t(f.rpm < 50 ? "RESTING · MIN \(Int(f.min))" : "TARGET \(Int(f.target)) · MAX \(Int(f.max))", 8, Pal.text4, bold: false, 0.5).lineLimit(1)
        }.frame(maxWidth: .infinity)
    }

    // MARK: rail

    private var rail: some View {
        let sn = live.snap
        let batt = sn.battW ?? 0
        let cells: [(String, String, String, Double?)] = [
            ("SYSTEM", sn.sysW.map { String(format: "%.1f W", $0) } ?? "—", sn.dcW.map { "DC IN " + String(format: "%.1f W", $0) } ?? "", nil),
            ("BATTERY", sn.battW.map { String(format: "%.1f W", abs($0)) } ?? "—", state.charging ? "CHARGING" : state.onAC ? "ON AC" : batt > 0.5 ? "DISCHARGING" : "IDLE", nil),
            ("CPU LOAD", "\(gauges.cpu)%", "ALL CORES", Double(gauges.cpu) / 100),
        ]
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                VStack(alignment: .leading, spacing: 2) {
                    t(c.0, 9, Pal.amberDim, 1.2)
                    Text(c.1).font(Pal.font(15, .bold)).foregroundStyle(Pal.text1).lineLimit(1)
                    if let b = c.3 {
                        GeometryReader { g in
                            Capsule().fill(Pal.groove)
                            Capsule().fill(Pal.calm(b)).frame(width: g.size.width * CGFloat(min(1, b)))
                        }.frame(height: 3)
                    }
                    t(c.2, 8, Pal.text4, bold: false, 0.6).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, i == 0 ? 0 : 12)
                if i < cells.count - 1 { Rectangle().fill(Pal.hairline).frame(width: 1, height: 40) }
            }
        }.frame(height: 50)
    }

    // MARK: sensors

    private var sensors: some View {
        let h = live.hist, last = h.last
        let readout: String = {
            guard let i = hover, i < h.count else { return "" }
            let p = h[i], ago = Int((Date().timeIntervalSince1970 - p.t) / 60)
            return "-\(ago)M  " + Thermal.groups.indices.compactMap { k in (hidden.contains(k) || p.temps[k] == nil) ? nil : "\(Thermal.groups[k].short) \(Int(p.temps[k]!.rounded()))°" }.joined(separator: " · ")
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                t("SENSORS", 10, Pal.amberDim, 2.4).fixedSize()
                if readout.isEmpty { Rectangle().fill(Pal.amberGhost).frame(height: 1); t("30 MIN", 9, Pal.text4, bold: false, 1) }
                else { t(readout, 9, Pal.accent, bold: false, 0.4).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .trailing) }
            }.frame(height: 18)
            HeatChart(hist: h, maxRPM: live.snap.maxRPM, hidden: hidden, focus: hoverRow, hover: $hover).frame(height: 118)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 4) {
                ForEach(Thermal.groups.indices, id: \.self) { k in
                    let v = last?.temps[k], off = hidden.contains(k)
                    HStack(spacing: 6) {
                        Circle().fill(Self.tints[k]).frame(width: 7, height: 7)
                        t(Thermal.groups[k].short, 9, hoverRow == k ? Pal.text1 : Pal.text3, 1)
                        Spacer(minLength: 0)
                        Text(v.map { "\(Int($0.rounded()))°" } ?? "—").font(Pal.font(12, .bold)).foregroundStyle(v == nil ? Pal.text4 : Pal.text1)
                    }
                    .opacity(off ? 0.35 : 1).padding(.horizontal, 6).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hoverRow == k ? Pal.hoverFill : .clear))
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { hoverRow = k } else if hoverRow == k { hoverRow = nil } }
                    .onTapGesture { if off { hidden.remove(k) } else if hidden.count < Thermal.groups.count - 1 { hidden.insert(k) } }
                }
            }
        }
    }
}

/// One turbine: the ring gauge, the rotor and its ghosts, the numeral in the hub.
private struct Turbine: View {
    let rpm: Double, target: Double, minRPM: Double, maxRPM: Double

    var body: some View {
        let frac = maxRPM > 0 ? max(0, min(1, rpm / maxRPM)) : 0, on = rpm >= 50
        ZStack {
            Ring(frac: frac, targetFrac: maxRPM > 0 ? target / maxRPM : 0, on: on).equatable()
            // the smear: above a third of the load the blades blur into a disc
            if on && frac > 0.3 {
                Circle().fill(AngularGradient(colors: [Pal.accent.opacity(0.0), Pal.accent.opacity(0.18 * frac), Pal.accent.opacity(0.0)], center: .center))
                    .frame(width: 104, height: 104).blur(radius: 1.5)
            }
            SpinningRotor(revPerSec: on ? 0.4 + 2.6 * frac : 0, ghosts: on && frac > 0.2).frame(width: 120, height: 120)
            Circle().fill(Pal.cardSolid).frame(width: 44, height: 44).overlay(Circle().stroke(Pal.hairline, lineWidth: 1))
            Text(on ? String(Int(rpm.rounded())) : "OFF").font(Pal.font(on ? 16 : 12, .bold)).foregroundStyle(on ? Pal.text1 : Pal.text4).monospacedDigit()
        }
    }
}

/// The rotor and its two ghosts as Core Animation layers: a repeating rotation the window server runs by itself, so the turbines turn at no
/// CPU cost. A change of speed carries on from the angle the blades are at (no jump).
private struct SpinningRotor: NSViewRepresentable {
    let revPerSec: Double, ghosts: Bool
    func makeNSView(context: Context) -> RotorView { RotorView() }
    func updateNSView(_ v: RotorView, context: Context) { v.set(revPerSec: revPerSec, ghosts: ghosts) }

    final class RotorView: NSView {
        private let layersList: [CALayer] = (0..<3).map { _ in CALayer() }      // main, then two ghosts behind it
        private let lags: [Double] = [0, 13, 26], alphas: [Float] = [1, 0.30, 0.16]
        private var rps = -1.0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let img = Rotor.cgImage
            for l in layersList { l.contents = img; l.contentsScale = 3; l.contentsGravity = .resize; layer?.addSublayer(l) }
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            for l in layersList { l.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height); l.position = CGPoint(x: bounds.midX, y: bounds.midY) }
        }

        func set(revPerSec: Double, ghosts: Bool) {
            for (i, l) in layersList.enumerated() { l.opacity = i == 0 ? (revPerSec > 0 ? 1 : 0.7) : (ghosts ? alphas[i] : 0) }
            guard abs(revPerSec - rps) > max(0.05, rps * 0.08) || (revPerSec == 0) != (rps == 0) else { return }
            rps = revPerSec
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (i, l) in layersList.enumerated() {
                let cur = (l.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? (lags[i] * .pi / 180)
                l.removeAnimation(forKey: "spin")
                l.setValue(cur, forKeyPath: "transform.rotation.z")
                guard revPerSec > 0 else { continue }
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = cur; a.toValue = cur - Double.pi * 2          // clockwise
                a.duration = 1 / revPerSec; a.repeatCount = .infinity; a.timingFunction = CAMediaTimingFunction(name: .linear)
                l.add(a, forKey: "spin")
            }
            CATransaction.commit()
        }
    }
}

/// 60 ticks around the dial, lit up to the load (yellow into red as it climbs), with a notch at the target.
private struct Ring: View, Equatable {
    let frac: Double, targetFrac: Double, on: Bool
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2 - 3
            for i in 0..<60 {
                let a = Double.pi * 2 * Double(i) / 60 - Double.pi / 2, ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
                let lit = on && Double(i) / 60 < frac, major = i % 5 == 0
                let r0 = r - (major ? 9 : 6)
                let col: Color = lit ? Pal.calm(0.8 * Double(i) / 60) : Pal.text4.opacity(major ? 0.5 : 0.3)
                ctx.stroke(Path { $0.move(to: CGPoint(x: c.x + r0 * ca, y: c.y + r0 * sa)); $0.addLine(to: CGPoint(x: c.x + r * ca, y: c.y + r * sa)) }, with: .color(col), lineWidth: major ? 2 : 1.4)
            }
            if on && targetFrac > 0 {
                let a = Double.pi * 2 * min(1, targetFrac) - Double.pi / 2, ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
                ctx.stroke(Path { $0.move(to: CGPoint(x: c.x + (r - 13) * ca, y: c.y + (r - 13) * sa)); $0.addLine(to: CGPoint(x: c.x + (r + 2) * ca, y: c.y + (r + 2) * sa)) }, with: .color(Pal.text1), lineWidth: 2.4)
            }
        }
    }
}

/// Seven swept blades, rendered once to an image (rotating a cached image costs next to nothing, redrawing the blades every frame would not).
private enum Rotor {
    private static let cachedImage: NSImage? = MainActor.assumeIsolated {      // first used while a card is drawn, on the main thread
        let view = Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r0: CGFloat = 16, r1: CGFloat = 50
            for b in 0..<7 {
                let base = Double.pi * 2 * Double(b) / 7
                var p = Path(); let n = 14
                func pt(_ t: Double, _ edge: Double) -> CGPoint {
                    let r = r0 + (r1 - r0) * CGFloat(t), th = base + 0.62 * t + edge * (0.40 - 0.22 * t)
                    return CGPoint(x: c.x + r * CGFloat(cos(th)), y: c.y + r * CGFloat(sin(th)))
                }
                for i in 0...n { let q = pt(Double(i) / Double(n), 0); i == 0 ? p.move(to: q) : p.addLine(to: q) }
                for i in stride(from: n, through: 0, by: -1) { p.addLine(to: pt(Double(i) / Double(n), 1)) }
                p.closeSubpath()
                ctx.fill(p, with: .linearGradient(Gradient(colors: [Pal.text3.opacity(0.9), Pal.text2.opacity(0.95)]), startPoint: CGPoint(x: c.x, y: c.y), endPoint: CGPoint(x: c.x + 50, y: c.y)))
            }
        }.frame(width: 120, height: 120)
        let r = ImageRenderer(content: view); r.scale = 3
        return r.nsImage
    }
    static var cgImage: CGImage? { cachedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
}

/// 30 minutes of every sensor group on an auto-fit degree axis, over a faint band of fan speed. Hover a row of the legend to light its trace,
/// hover the chart for a crosshair (the card prints the readout).
private struct HeatChart: View {
    let hist: [HeatPoint]
    let maxRPM: Double
    let hidden: Set<Int>
    let focus: Int?
    @Binding var hover: Int?

    var body: some View {
        GeometryReader { g in
            ZStack {
                ChartBase(hist: hist, maxRPM: maxRPM, hidden: hidden, focus: focus).equatable()
                Canvas { ctx, size in
                    guard let h = hover, h < hist.count, hist.count > 1 else { return }
                    let L: CGFloat = 26, R = size.width - 4, now = hist.last!.t
                    let x = R - CGFloat((now - hist[h].t) / 1800) * (R - L)
                    let col = Path(roundedRect: CGRect(x: x - 3, y: 0, width: 6, height: size.height - 14), cornerRadius: 3)
                    ctx.fill(col, with: .color(Pal.text1.opacity(0.08)))
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 2)); $0.addLine(to: CGPoint(x: x, y: size.height - 14)) }, with: .color(Pal.text1.opacity(0.4)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    guard hist.count > 1 else { return }
                    let L: CGFloat = 26, R = g.size.width - 4, now = hist.last!.t
                    let tt = now - Double((R - p.x) / (R - L)) * 1800
                    let i = hist.indices.min { abs(hist[$0].t - tt) < abs(hist[$1].t - tt) }
                    if i != hover { hover = i }
                case .ended: if hover != nil { hover = nil }
                }
            }
        }
    }
}

private struct ChartBase: View, Equatable {
    let hist: [HeatPoint]
    let maxRPM: Double
    let hidden: Set<Int>
    let focus: Int?
    var body: some View {
        Canvas { ctx, size in
            let L: CGFloat = 26, R = size.width - 4, T: CGFloat = 4, B = size.height - 14, span = 1800.0
            guard hist.count > 1, R > L else { return }
            let now = hist.last!.t
            let vals = hist.flatMap { p in p.temps.indices.compactMap { hidden.contains($0) ? nil : p.temps[$0] } }
            guard let lo0 = vals.min(), let hi0 = vals.max() else { return }
            let lo = (lo0 - 2).rounded(.down), hi = max((hi0 + 2).rounded(.up), lo + 6)
            let x = { (t: TimeInterval) in R - CGFloat((now - t) / span) * (R - L) }
            let y = { (v: Double) in B - CGFloat((v - lo) / (hi - lo)) * (B - T) }
            func label(_ s: String, _ p: CGPoint, _ a: UnitPoint) { ctx.draw(Text(s).font(Pal.font(7.5)).foregroundStyle(Pal.text4), at: p, anchor: a) }
            for m in [1.0, 0.5, 0.0] {
                let yy = (T + CGFloat(1 - m) * (B - T)).rounded() + 0.5
                ctx.stroke(Path { $0.move(to: CGPoint(x: L, y: yy)); $0.addLine(to: CGPoint(x: R, y: yy)) }, with: .color(Pal.accent.opacity(m == 0 ? 0.2 : 0.07)), lineWidth: 1)
                label("\(Int((lo + (hi - lo) * m).rounded()))°", CGPoint(x: L - 4, y: yy), .trailing)
            }
            for (s, f, a) in [("NOW", 0.0, UnitPoint.topTrailing), ("-15M", 0.5, .top), ("-30M", 1.0, .topLeading)] {
                label(s, CGPoint(x: R - CGFloat(f) * (R - L), y: B + 3), a)
            }
            // fan speed as a quiet band along the floor
            if maxRPM > 0 {
                var band = Path(); band.move(to: CGPoint(x: x(hist[0].t), y: B))
                for p in hist { band.addLine(to: CGPoint(x: x(p.t), y: B - CGFloat(p.rpm / maxRPM) * (B - T) * 0.35)) }
                band.addLine(to: CGPoint(x: x(hist.last!.t), y: B)); band.closeSubpath()
                ctx.fill(band, with: .color(Pal.text4.opacity(0.16)))
            }
            ctx.clipToLayer { $0.fill(Path(CGRect(x: L, y: 0, width: R - L + 3, height: size.height)), with: .color(.black)) }
            for k in Thermal.groups.indices where !hidden.contains(k) {
                var line = Path(); var started = false
                for p in hist { guard let v = p.temps[k] else { continue }; let pt = CGPoint(x: x(p.t), y: y(v)); if started { line.addLine(to: pt) } else { line.move(to: pt); started = true } }
                let dim = focus != nil && focus != k
                ctx.stroke(line, with: .color(FanCard.tints[k].opacity(dim ? 0.25 : 0.95)), style: StrokeStyle(lineWidth: focus == k ? 2.2 : 1.4, lineJoin: .round))
            }
        }
    }
}
