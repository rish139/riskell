// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// ONE FLAT ROW: the link glyph (wifi / cable / none), four equal blocks, the exact %. Blocks are discrete steps (level =
/// ceil(signal / 25), at least 1 for any signal), the same size at 5 % and 95 %, and the figure sits in a fixed right-aligned bay so the
/// end of the bar never shifts. Down: every groove turns crit, nothing is lit, "-" in crit. Hover runs a pulse through the four cells
/// and warms the label.
struct NetFace: View {
    @ObservedObject private var s = NetState.shared
    @State private var hot = false
    @State private var phase: Double = 1
    let vertical: Bool

    var body: some View {
        let w = s.wifi, down = w.kind == "down"
        let pct = w.pct, level = down ? 0 : min(4, max(pct > 0 ? 1 : 0, Int((Double(pct) / 25).rounded(.up))))
        let glyph = down ? "wifi.slash" : w.kind == "eth" ? "cable.connector" : w.kind == "linked" ? "network" : "wifi"
        let figure = down || w.kind != "wifi" ? "—" : String(pct), unit = !down && w.kind == "wifi" ? "%" : nil
        let figureTone = down ? Pal.crit : Pal.text1
        Group {
            if vertical {
                // The left strip: a column. The link glyph on top, the four cells stacked in the middle (weakest at the bottom, lit
                // from the bottom up), the figure (or state dash) underneath. Equal gaps above and below the cells.
                VStack(spacing: 0) {
                    Image(systemName: glyph).font(Pal.font(12, .semibold)).foregroundStyle(down ? Pal.crit : hot ? Pal.accent : Pal.text3)
                        .scaleEffect(hot ? 1.15 : 1).frame(height: 16)
                    Color.clear.frame(height: T.gap)
                    Cells(level: level, down: down, phase: phase, w: 7, vertical: true)
                    Color.clear.frame(height: T.gap)
                    Num(value: figure, unit: unit, tone: figureTone, hot: hot && !down)
                }
                .fixedSize()
                .frame(width: 40)
            } else {
                HStack(spacing: T.gap) {
                    Image(systemName: glyph).font(Pal.font(12, .semibold)).foregroundStyle(down ? Pal.crit : hot ? Pal.accent : Pal.text3)
                        .scaleEffect(hot ? 1.15 : 1).frame(width: 18)
                    Cells(level: level, down: down, phase: phase)
                    Num(value: figure, unit: unit, tone: figureTone, hot: hot && !down)
                        .frame(minWidth: 30, alignment: .trailing)
                }
                .frame(height: G.pill)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hot)
        .popout("net", edge: .above, hot: $hot)
        .onChange(of: hot) { _, h in
            guard h else { return }
            phase = 0
            withAnimation(.linear(duration: 0.56)) { phase = 1 }
        }
    }
}

/// The four cells. Animatable in `phase`, so the pulse is computed every frame (a derived scale would only interpolate end to end).
private struct Cells: View, Animatable {
    let level: Int, down: Bool
    var phase: Double
    var w: CGFloat = 8      // cell width: 8 in the row, 7 on the strip so the four cells and their pulse stay inside 40 pt
    var vertical = false    // the strip: a column, cell 0 (the weakest) at the bottom, lit from the bottom up
    var animatableData: Double { get { phase } set { phase = newValue } }
    /// one cell's bump: a half sine travelling along the row, each cell 0.2 of the pass behind the last
    private func bump(_ i: Int) -> CGFloat {
        let t = phase * 1.8 - Double(i) * 0.2
        return t <= 0 || t >= 1 ? 0 : CGFloat(sin(Double.pi * t))
    }
    private func cell(_ i: Int) -> some View {
        RoundedRectangle(cornerRadius: 1.7)
            .fill(i < level ? Pal.accent : down ? Pal.crit.opacity(0.45) : Pal.groove)
            .frame(width: w, height: 7)
            .scaleEffect(1 + 0.5 * bump(i))
    }
    var body: some View {
        if vertical {
            VStack(spacing: 2) {
                ForEach([3, 2, 1, 0], id: \.self) { i in cell(i) }
            }
        } else {
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in cell(i) }
            }
        }
    }
}
