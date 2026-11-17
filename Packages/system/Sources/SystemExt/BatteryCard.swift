// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// The battery card: what the atom does not already say, six readings in a grid. No header (the atom you are hovering is the title).
/// Power is signed (+ charging, - discharging), temperature and health carry the shell's tone chains.
struct BatteryCard: View {
    @ObservedObject private var state = SystemState.shared
    @ObservedObject private var gauges = SystemGauges.shared      // redraws on the timer-driven numbers
    @ObservedObject private var pop = PopState.shared
    static let pad: CGFloat = 15
    static let size = CGSize(width: 182, height: 164)

    var body: some View {
        let d = state.batDetail, p = gauges.powerW ?? 0
        let temp = d.tempC, health = d.health
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 13) {
            GridRow {
                reading("POWER", (p >= 0 ? "+" : "−") + String(format: "%.1f", abs(p)), "W", p >= 0 ? Pal.ok : Pal.text1)
                reading("TEMP", temp.map { String(format: "%.0f", $0) } ?? "—", temp == nil ? "" : "°C", temp.map { $0 > 55 ? Pal.crit : $0 > 45 ? Pal.warn : Pal.text1 } ?? Pal.text4)
            }
            GridRow {
                reading("HEALTH", health.map { String(format: "%.0f", $0) } ?? "—", health == nil ? "" : "%", health.map { $0 < 60 ? Pal.crit : $0 < 80 ? Pal.warn : Pal.text1 } ?? Pal.text4)
                reading("CYCLES", d.cycles.map(String.init) ?? "—", "", Pal.text1)
            }
            GridRow {
                reading("ADAPTER", d.adapterW.map(String.init) ?? "—", d.adapterW == nil ? "" : "W", d.adapterW == nil ? Pal.text4 : Pal.text1)
                reading("ENERGY", d.wh.map { String(format: "%.1f", $0) } ?? "—", d.wh == nil ? "" : "Wh", Pal.text1)
            }
        }
        .padding(Self.pad)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .opacity(pop.open ? 1 : 0).offset(y: pop.open ? 0 : 6)
        .animation(.easeOut(duration: 0.22).delay(0.04), value: pop.open)
    }

    private func reading(_ cap: String, _ value: String, _ unit: String, _ tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cap).font(Pal.font(9, .bold)).tracking(1.4).foregroundStyle(Pal.text4)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(Pal.font(17, .bold)).foregroundStyle(tone)
                if !unit.isEmpty { Text(unit).font(Pal.font(10)).foregroundStyle(Pal.text4) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
