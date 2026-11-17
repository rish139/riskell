// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// The fan atom: what it draws. FAN, read-only: a status box (OFF when the fans rest, AUTO while the system runs them, MAX near their limit),
/// the speed in rpm with ONE trace under it (the last ~3 minutes, newest last, normalised to its own peak) and the hottest sensor in degrees.
/// Stood up on the strip; on a horizontal bar (`vertical` false) it is one 36 pt row: the status box, the rpm with its trace, the hottest sensor.
/// Hover runs a scan along the trace and warms the captions, and opens the thermal card.
struct FanFace: View {
    @ObservedObject private var gauges = SystemGauges.shared      // redraws on the timer-driven numbers (the thermal reading is one)
    @ObservedObject private var live = FanLive.shared
    @State private var hot = false
    @State private var phase: Double = 1
    let vertical: Bool

    var body: some View {
        let th = gauges.thermal
        let rpm = th.fanRPM ?? 0, hottest = th.hottest ?? th.tempC
        let maxRPM = live.snap.maxRPM, off = rpm < 50
        let state = off ? "OFF" : (maxRPM > 0 && Double(rpm) >= maxRPM * 0.9) ? "MAX" : "AUTO"
        let tone: Color = (hottest ?? 0) > 85 ? Pal.crit : (hottest ?? 0) > 70 ? Pal.warn : Pal.text1
        Group {
            if vertical {
                VStack(spacing: 3.4) {
                    cap("FAN")
                    Text(state).font(Pal.font(7.5, .bold)).tracking(0.9)
                        .foregroundStyle(state == "MAX" ? Pal.warn : off ? Pal.text4 : Pal.text3)
                        .padding(.horizontal, 4.5).frame(height: 15)
                        .background(RoundedRectangle(cornerRadius: 4.5).fill(Pal.pressFill))
                        .overlay(RoundedRectangle(cornerRadius: 4.5).stroke(state == "MAX" ? Pal.warn.opacity(0.5) : hot ? Pal.accent.opacity(0.6) : Pal.line, lineWidth: 1))
                    Rectangle().fill(Pal.hairline).frame(width: 22, height: 1)
                    Text(rpm > 0 ? String(rpm) : "—").font(Pal.font(12.4, .bold)).foregroundStyle(off ? Pal.text3 : Pal.text1)
                    cap("RPM")
                    Trace(rpms: live.hist.suffix(20).map(\.rpm), phase: phase).frame(width: 29, height: 8)
                    Rectangle().fill(Pal.hairline).frame(width: 22, height: 1)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Image(systemName: "thermometer.medium").font(Pal.font(8.5)).foregroundStyle(Pal.text4)
                        Text(hottest.map { String(Int($0.rounded())) } ?? "—").font(Pal.font(11.5, .bold)).foregroundStyle(hottest == nil ? Pal.text4 : tone)
                        if hottest != nil { Text("°C").font(Pal.font(8)).foregroundStyle(Pal.text4) }
                    }
                }
                .frame(width: G.strip)
            } else {
                // One 36 pt row: the state chip, the speed with its trace, the hottest sensor. The chip keeps the column's styling.
                HStack(spacing: T.gap) {
                    Cap(text: "FAN", hot: hot)
                    Text(state).font(Pal.font(7.5, .bold)).tracking(0.9)
                        .foregroundStyle(state == "MAX" ? Pal.warn : off ? Pal.text4 : Pal.text3)
                        .padding(.horizontal, 4.5).frame(height: 15)
                        .background(RoundedRectangle(cornerRadius: 4.5).fill(Pal.pressFill))
                        .overlay(RoundedRectangle(cornerRadius: 4.5).stroke(state == "MAX" ? Pal.warn.opacity(0.5) : hot ? Pal.accent.opacity(0.6) : Pal.line, lineWidth: 1))
                    Sep(height: 18).padding(.horizontal, 5)
                    Cap(text: "RPM", hot: hot)
                    Num(value: rpm > 0 ? String(rpm) : "—", unit: nil, tone: off ? Pal.text3 : Pal.text1)
                    Trace(rpms: live.hist.suffix(20).map(\.rpm), phase: phase).frame(width: 34, height: 14)
                    Sep(height: 18).padding(.horizontal, 5)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Image(systemName: "thermometer.medium").font(Pal.font(9.5)).foregroundStyle(Pal.text4)
                        Num(value: hottest.map { String(Int($0.rounded())) } ?? "—", unit: hottest == nil ? nil : "°C",
                            tone: hottest == nil ? Pal.text4 : tone)
                    }
                }
                .frame(height: G.pill)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hot)
        .popout("fan", edge: .right, hot: $hot)
        .onChange(of: hot) { _, h in
            guard h else { return }
            phase = 0
            withAnimation(.linear(duration: 0.56)) { phase = 1 }
        }
    }

    private func cap(_ t: String) -> some View { Text(t).font(Pal.font(8.5, .bold)).tracking(0.8).foregroundStyle(hot ? Pal.text3 : Pal.text4) }

    /// The speed trace: rpm over the kept ring as 1 px columns, a scan lifts them in turn on hover.
    private struct Trace: View, Animatable {
        let rpms: [Double]
        var phase: Double
        var animatableData: Double { get { phase } set { phase = newValue } }
        var body: some View {
            Canvas { ctx, size in
                let n = rpms.count, slots = 20, step = size.width / CGFloat(slots), peak = max(1, rpms.max() ?? 1)
                ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Pal.groove))
                for (i, v) in rpms.enumerated() {
                    let t = phase * 1.7 - Double(i) / Double(max(1, n)) * 0.7, lift = t <= 0 || t >= 1 ? 0 : sin(Double.pi * t)
                    let h = max(1, (size.height - 1) * CGFloat(v / peak)) * (1 + 0.5 * CGFloat(lift)), x = size.width - CGFloat(n - i) * step
                    ctx.fill(Path(CGRect(x: x.rounded(), y: size.height - min(size.height, h), width: max(1, (step - 0.7).rounded()), height: min(size.height, h))),
                             with: .color(i == n - 1 ? Pal.accent : Pal.amberDim))
                }
            }
        }
    }
}
