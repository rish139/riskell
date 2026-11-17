// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// WEATHER: the condition glyph in its family's ink, the temperature in the bar's figure size with the feels-like small beside it, and today's high and low stacked beside it.
/// A reading older than half an hour is dimmed. Hover lifts the glyph and opens the weather card (rain chance is there).
/// On the left strip (`vertical`) it stands up as a column: the glyph, the temperature, the feels-like beneath it, a short hairline, then
/// the range, hi over lo. Figures are one decimal under 10 degrees and whole degrees from 10 up ("-12°", as CpuAtom does for watts),
/// because "-12.4°" does not fit the 40 pt column at the figure size.
struct WeatherFace: View {
    @ObservedObject private var state = WeatherState.shared
    @State private var hot = false
    let vertical: Bool

    var body: some View {
        if let w = state.wx {
            let night = w.cur.isDay == 0, env = w.envelope
            let tone = Self.tone(w.cur.code, night: night)
            Group {
                if vertical {
                    column(w, env, tone: tone, night: night)
                } else {
                    HStack(spacing: T.gap) {
                        Image(systemName: WXText.symbol(w.cur.code, day: !night)).font(Pal.font(16, .semibold)).symbolRenderingMode(.monochrome)
                            .foregroundStyle(tone).scaleEffect(hot ? 1.15 : 1).frame(width: 22)
                        HStack(alignment: .center, spacing: 6) {
                            Num(value: String(format: "%.1f", w.cur.temp), unit: "°", hot: hot)
                            Text("≈ " + String(format: "%.1f°", w.cur.feels)).font(Pal.font(11))      // the feels-like, small beside the temperature: "≈", no word
                                .foregroundStyle(Pal.accent).fixedSize()
                        }
                        if let env {
                            Sep(height: 18).padding(.leading, -3).padding(.trailing, 4)      // closer to the feels-like than to the range
                            VStack(alignment: .leading, spacing: 0) {
                                range("arrow.up", env.hi); range("arrow.down", env.lo)
                            }
                        }
                    }
                    .frame(height: G.pill)
                }
            }
            .opacity(Date().timeIntervalSince1970 - w.syncedAt > 1800 ? 0.6 : 1)      // a reading older than half an hour is dimmed, never hidden
            .animation(.spring(duration: 0.26, bounce: 0.18), value: hot)
            .popout("weather", edge: .above, hot: $hot)
        } else if vertical {
            Text("--").font(T.value).foregroundStyle(Pal.text3).frame(width: 40)
        } else {
            Text("Weather --").font(Pal.font(12)).foregroundStyle(Pal.text3).frame(height: G.pill)
        }
    }

    /// The left strip's column, 40 pt wide and centred: glyph, temperature, feels-like, hairline, range.
    private func column(_ w: WX, _ env: (hi: Double, lo: Double)?, tone: Color, night: Bool) -> some View {
        VStack(spacing: 0) {
            Image(systemName: WXText.symbol(w.cur.code, day: !night)).font(Pal.font(16, .semibold)).symbolRenderingMode(.monochrome)
                .foregroundStyle(tone).scaleEffect(hot ? 1.15 : 1).frame(height: 18)
            Color.clear.frame(height: 4)
            Num(value: Self.short(w.cur.temp), unit: "°", hot: hot)
            Text("≈" + Self.short(w.cur.feels) + "°").font(T.sub).foregroundStyle(Pal.accent).fixedSize()      // no space: "≈-8.4°" fits, "≈ -8.4°" does not
            if let env {
                Rectangle().fill(Pal.hairline).frame(width: 24, height: 1).padding(.vertical, 7)
                VStack(spacing: 2) {
                    range("arrow.up", env.hi, column: true); range("arrow.down", env.lo, column: true)
                }
            }
        }
        .fixedSize()
        .frame(width: 40)
        .padding(.vertical, 4)
    }

    /// one decimal under 10 degrees, whole degrees from 10 up (so the widest figure, "-9.9°" or "-12°", stays inside 40 pt)
    static func short(_ v: Double) -> String { abs(v) < 9.95 ? String(format: "%.1f", v) : String(format: "%.0f", v) }

    /// the condition's family ink; amber is never the condition's ink
    static func tone(_ code: Int, night: Bool) -> Color {
        switch code {
        case 0, 95, 96, 99: return night ? Pal.info : Pal.warn
        case 51...67, 80...82: return Pal.info
        case 71...77, 85, 86: return Pal.text1
        case 45, 48: return Pal.text4
        default: return Pal.text3
        }
    }

    private func range(_ arrow: String, _ v: Double, column: Bool = false) -> some View {
        HStack(spacing: column ? 2 : 3) {
            Image(systemName: arrow).font(Pal.font(7.5, .bold)).foregroundStyle(Pal.text4)
            Text(column ? Self.short(v) + "°" : String(format: "%.1f°", v)).font(T.sub).foregroundStyle(hot ? Pal.text2 : Pal.text3)
        }
    }
}
