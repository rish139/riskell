// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// The battery atom: the figure and the glass cell in both forms, with its card. The numbers come from `SystemState` and
/// `SystemEngine` retains the samplers only while this atom is on a showing bar.
public struct BatAtom: CustomAtom {
    public static let meta = AtomMeta(id: "bat", name: "Battery", priority: 9, maxWidth: 260)
    public init() {}
    public func horizontal(_ env: Env) -> some View { BatFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { BatFace(vertical: true) }
    public var card: Card? { Card(id: "bat", size: { _ in BatteryCard.size }) { BatteryCard() } }
    public func activate(_ env: Env) -> (() -> Void)? { SystemEngine.shared.retainAll(env) }
}

/// The battery: the figure first (bold, dim micro-%), then the glass cell and nothing else at rest. The cell is the icon: a pressed
/// body, a hairline edge, a terminal nub, the charge as a fill with a crown on its crest, and 25/50/75 engravings cut through the bore.
/// Hover swells the cell, gleams it once, warms the figure, and slides the runtime (to empty / to full) in behind it in one tween.
/// Below 20 % and not charging the whole atom pulses.
/// On the left strip (`vertical`) it stands up as a column: a tall cell (nub on top, charge rising from the bottom) with the figure under it,
/// and the runtime unfolds underneath it instead of sideways.
struct BatFace: View {
    @ObservedObject private var state = SystemState.shared
    @State private var hot = false
    @State private var runtimeW: CGFloat = 0
    @State private var pulse = false
    let vertical: Bool

    var body: some View {
        if let pct = state.batPct {
            let charging = state.charging
            let tone = Self.tone(pct, charging)
            let low = pct < 20 && !charging
            let rt = Self.runtime(state.batDetail.minutes, pct: pct, charging: charging)
            Group {
                if vertical {
                    // The left strip: a column. The glass cell is the whole picture; the figure under it, and the runtime unfolding below
                    // the figure on hover.
                    VStack(spacing: 0) {
                        VCell(level: min(1, max(0, Double(pct) / 100)), tone: tone, hot: hot)
                        Color.clear.frame(height: T.gap)
                        Num(value: String(pct), unit: "%", tone: tone, hot: hot && !(pct < 30 && !charging))
                        verticalRuntime(rt, charging: charging)
                    }
                    .fixedSize()
                    .frame(width: 40)
                } else {
                    HStack(spacing: T.gap) {
                        Num(value: String(pct), unit: "%", tone: tone, hot: hot && !(pct < 30 && !charging))
                        Cell(level: min(1, max(0, Double(pct) / 100)), tone: tone, hot: hot)
                        runtime(rt, charging: charging)
                    }
                    .frame(height: G.pill)
                }
            }
            .opacity(low && pulse ? 0.25 : 1)
            .animation(.easeOut(duration: 0.15), value: hot)
            .animation(low ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default, value: pulse)
            .onChange(of: low) { _, l in pulse = l }
            .onAppear { pulse = low }
            .popout("bat", edge: .below, hot: $hot)
        }
    }

    /// the tone chain: ok from 30, warn under 30, crit under 20; charging keeps the ok green
    static func tone(_ pct: Int, _ charging: Bool) -> Color { charging || pct >= 100 ? Pal.ok : pct < 20 ? Pal.crit : pct < 30 ? Pal.warn : Pal.ok }

    static func runtime(_ minutes: Int?, pct: Int, charging: Bool) -> (h: Int, m: String)? {
        guard let m = minutes, !(charging && pct >= 100) else { return nil }
        let h = m / 60 + (m % 60 == 60 ? 1 : 0)
        return (h, String(format: "%02d", m % 60))
    }

    /// 0 px wide until hovered, then widens by exactly its own width and holds
    private func runtime(_ rt: (h: Int, m: String)?, charging: Bool) -> some View {
        let show = hot && rt != nil
        return HStack(spacing: 0) {
            Color.clear.frame(width: 7)
            Text("\(rt?.h ?? 0)").font(T.value).foregroundStyle(Pal.text1)
            Text("h").font(T.unit).foregroundStyle(Pal.text4)
            Color.clear.frame(width: 3)
            Text(rt?.m ?? "00").font(T.value).foregroundStyle(Pal.text1)
            Text("m").font(T.unit).foregroundStyle(Pal.text4)
            Color.clear.frame(width: 6)
            Cap(text: charging ? "TO FULL" : "LEFT")
        }
        .fixedSize()
        .background(GeometryReader { g in Color.clear.preference(key: WidthKey.self, value: g.size.width) })
        .onPreferenceChange(WidthKey.self) { w in var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { runtimeW = w } }      // never animated: the low-battery pulse (repeatForever) must not ride along into the width
        .frame(width: show ? runtimeW : 0, alignment: .leading)
        .clipped()
        .opacity(show ? 1 : 0)
        .animation(.easeOut(duration: 0.17), value: show)
    }

    /// Vertical runtime: 0 px tall until hovered, then unfolds downward by exactly its own height and holds. "TO FULL" splits over
    /// two captions, since it does not fit the 40 pt column on one line.
    private func verticalRuntime(_ rt: (h: Int, m: String)?, charging: Bool) -> some View {
        let show = hot && rt != nil
        return Group {
            if show {
                VStack(spacing: 0) {
                    Color.clear.frame(height: T.gap)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(rt?.h ?? 0)").font(T.value).foregroundStyle(Pal.text1)
                        Text("h").font(T.unit).foregroundStyle(Pal.text4)
                    }
                    Color.clear.frame(height: 3)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(rt?.m ?? "00").font(T.value).foregroundStyle(Pal.text1)
                        Text("m").font(T.unit).foregroundStyle(Pal.text4)
                    }
                    Color.clear.frame(height: 6)
                    Cap(text: charging ? "TO" : "LEFT")
                    if charging { Cap(text: "FULL") }
                }
                .fixedSize()
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.17), value: show)
    }
}

private struct WidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The glass cell, 47 x 14 with a 3 px nub; hover grows it 3.4 px taller about its centre.
private struct Cell: View {
    let level: Double, tone: Color, hot: Bool
    @State private var sheen: CGFloat = 0
    private let w: CGFloat = 38, h: CGFloat = 14, nub: CGFloat = 3
    var body: some View {
        let hh = h + (hot ? 3.4 : 0), bore = w - 2
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3.4).fill(Pal.pressFill).frame(width: w, height: hh)
            RoundedRectangle(cornerRadius: 2.2).fill(tone).frame(width: max(0, bore * level), height: hh - 2)
                .overlay(alignment: .trailing) { Rectangle().fill(Pal.text1.opacity(0.34)).frame(width: 1).opacity(level > 0.01 ? 1 : 0) }
                .overlay { Sheen(x: sheen) }
                .clipShape(RoundedRectangle(cornerRadius: 2.2))
                .padding(.leading, 1)
            RoundedRectangle(cornerRadius: 3.4).stroke(Pal.hairline, lineWidth: 1).frame(width: w, height: hh)
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 2.2, topTrailingRadius: 2.2)
                .fill(hot ? Pal.accent.opacity(0.5) : Pal.line).frame(width: nub, height: 7).offset(x: w)
        }
        .frame(width: w + nub, height: h, alignment: .leading)
        .animation(.spring(duration: 0.26, bounce: 0.18), value: hot)
        .onChange(of: hot) { _, h in
            guard h else { return }
            sheen = 0
            withAnimation(.easeInOut(duration: 0.43)) { sheen = 1 }
        }
    }
}

/// The vertical glass cell: the same cell turned on its end, 14 wide with a 38 px body and a 3 px nub on top; the charge rises
/// from the bottom with its crown on the crest. Hover grows it 3.4 px wider about its centre and gleams it once, top to bottom.
private struct VCell: View {
    let level: Double, tone: Color, hot: Bool
    @State private var sheen: CGFloat = 0
    private let w: CGFloat = 14, len: CGFloat = 38, nub: CGFloat = 3
    var body: some View {
        let ww = w + (hot ? 3.4 : 0), bore = w - 2
        VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 2.2, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 2.2)
                .fill(hot ? Pal.accent.opacity(0.5) : Pal.line).frame(width: 7, height: nub)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3.4).fill(Pal.pressFill)
                RoundedRectangle(cornerRadius: 2.2).fill(tone).frame(width: bore, height: max(0, (len - 2) * CGFloat(level)))
                    .overlay(alignment: .top) { Rectangle().fill(Pal.text1.opacity(0.34)).frame(height: 1).opacity(level > 0.01 ? 1 : 0) }
                    .overlay { VSheen(x: sheen) }
                    .clipShape(RoundedRectangle(cornerRadius: 2.2))
                    .padding(.bottom, 1)
                RoundedRectangle(cornerRadius: 3.4).stroke(Pal.hairline, lineWidth: 1)
            }
            .frame(width: ww, height: len)
        }
        .frame(width: ww, height: len + nub)
        .animation(.spring(duration: 0.26, bounce: 0.18), value: hot)
        .onChange(of: hot) { _, h in
            guard h else { return }
            sheen = 0
            withAnimation(.easeInOut(duration: 0.43)) { sheen = 1 }
        }
    }
}

/// One soft light band that crosses its rectangle once when `x` runs 0 -> 1, top to bottom; parked off to the top otherwise.
private struct VSheen: View {
    let x: CGFloat
    var body: some View {
        GeometryReader { g in
            let sh = max(10, g.size.height * 0.5)
            LinearGradient(colors: [Pal.text1.opacity(0), Pal.text1.opacity(0.55), Pal.text1.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: sh)
                .offset(y: -sh + (g.size.height + sh) * x)
        }.allowsHitTesting(false)
    }
}
