// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// USAGE / RATE LIMITS: the Claude windows, one compact list. A window is one row: its code, a bar with a tick for how far through
/// the window you are (the pace), the exact %, and its reset countdown. One accent for every bar; it turns orange past 75 % and red past 90 %.
/// Hovering a row names its reset, its pace and, at this speed, when it runs out. A missing reading is an empty bar and "—", never an
/// invented value. A footnote says where the numbers come from and what the % is of.
struct UsageCard: View {
    @ObservedObject private var state = UsageState.shared
    @ObservedObject private var config = HostConfig.shared
    @State private var hover: Int? = nil

    static let pad: CGFloat = 16, width: CGFloat = 380
    private static let h5 = 5.0 * 3600, d7 = 7.0 * 86400

    struct Row: Identifiable {
        let id: String
        let code: String
        let win: UsageWin?
        let len: Double
    }

    private var claudeRows: [Row] {
        let c = state.claude
        var r = [Row(id: "5h", code: "5H", win: c?.five, len: Self.h5), Row(id: "7d", code: "7D", win: c?.seven, len: Self.d7)]
        if let x = c?.sonnet { r.append(Row(id: "so", code: "SONNET", win: x, len: Self.d7)) }
        if let x = c?.opus { r.append(Row(id: "op", code: "OPUS", win: x, len: Self.d7)) }
        return r
    }

    private static let rowH: CGFloat = 30, rowGap: CGFloat = 2, noteH: CGFloat = 14
    /// Shown only while it is switched on in config.json; when off, the card is the header alone.
    static var claudeOn: Bool { UsageConfig.claudeOn() }
    static var size: CGSize {
        func block(_ n: Int) -> CGFloat { 18 + 6 + CGFloat(n) * rowH + CGFloat(max(0, n - 1)) * rowGap }
        let c = UsageState.shared.claude
        let rows = 2 + (c?.sonnet != nil ? 1 : 0) + (c?.opus != nil ? 1 : 0)
        // the header; then, when on, the block and the footnote, 10 pt apart
        let body: CGFloat = claudeOn ? block(rows) + noteH + 20 : 0
        return CGSize(width: width, height: 11 + 12 + 20 + body)
    }

    var body: some View {
        let now = Date().timeIntervalSince1970
        VStack(alignment: .leading, spacing: 10) {
            header
            if Self.claudeOn {
                block("CLAUDE", mark: Brand.claude, rows: claudeRows, hover: $hover, now: now)
                note
            }
        }
        .padding(.horizontal, Self.pad).padding(.top, 11).padding(.bottom, 12)
        .frame(width: Self.width, alignment: .topLeading)
    }

    private func t(_ s: String, _ size: CGFloat, _ color: Color, bold: Bool = true, _ ls: CGFloat = 1.2) -> some View {
        Text(s).font(Pal.font(size, bold ? .bold : .regular)).tracking(ls).foregroundStyle(color)
    }

    private var header: some View {
        let fetched = Self.claudeOn ? (state.claude?.fetched ?? 0) : 0
        let stale = Self.claudeOn && state.claude?.stale == true
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            t("USAGE", 10, Pal.text4, 2.6)
            Text("RATE LIMITS").font(Pal.font(15, .bold)).foregroundStyle(Pal.text1)
            Spacer()
            t("UPDATED " + (fetched > 0 ? f.string(from: Date(timeIntervalSince1970: fetched)) : "—"), 9, stale ? Pal.warn : Pal.text4, bold: false, 1)
            Circle().fill(stale ? Pal.warn : Pal.accent).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }.frame(height: 20)
    }

    /// The one footnote: where the numbers come from and what the % is of. Shortened to fit the card's width.
    private var note: some View {
        t("LOCAL CLAUDE CODE LOGS · % OF YOUR LIMIT OR 30-DAY PEAK", 9, Pal.text4, bold: false, 0.4)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(height: Self.noteH, alignment: .leading)
    }

    // MARK: the vendor block

    private func block(_ title: String, mark: NSImage?, rows: [Row], hover: Binding<Int?>, now: Double) -> some View {
        let h = hover.wrappedValue
        let readout: String = {
            guard let i = h, i < rows.count, let w = rows[i].win else { return "" }
            return Self.readout(rows[i], w, now: now)
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let mark { Image(nsImage: mark).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 13, height: 13) }
                t(title, 10, Pal.text3, 2.2).fixedSize()
                if readout.isEmpty { Rectangle().fill(Pal.hairline).frame(height: 1) }
                else { t(readout, 9, Pal.text2, bold: false, 0.4).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .trailing) }     // the whole width, scaled down before it is ever cut
            }.frame(height: 18)
            VStack(spacing: Self.rowGap) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    windowRow(r, now: now, hot: h == i).onHover { inside in if inside { hover.wrappedValue = i } else if hover.wrappedValue == i { hover.wrappedValue = nil } }
                }
            }
        }
    }

    private func windowRow(_ r: Row, now: Double, hot: Bool) -> some View {
        let w = r.win, pct = w?.pct ?? 0, frac = w?.frac(len: r.len, now: now)
        let sev: Color = pct >= 90 ? Pal.crit : pct >= 75 ? Pal.warn : Pal.accent
        let ahead = frac.map { Double(pct) > $0 * 100 + 10 && pct >= 20 } ?? false
        return HStack(spacing: 9) {
            t(r.code, 9, hot ? Pal.text1 : Pal.text3, 1.2).frame(width: 48, alignment: .leading).lineLimit(1)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Pal.groove).frame(height: hot ? 6 : 4)
                    Capsule().fill(w == nil ? .clear : sev).frame(width: max(hot ? 6 : 4, g.size.width * CGFloat(min(100, pct)) / 100), height: hot ? 6 : 4)
                    if let f = frac { Rectangle().fill(Pal.text1.opacity(0.7)).frame(width: 1, height: 10).offset(x: g.size.width * CGFloat(f) - 0.5) }      // pace: how far through the window
                }.frame(maxHeight: .infinity)
            }.frame(height: 16)
            HStack(spacing: 2) {
                if ahead { Text("▲").font(Pal.font(7)).foregroundStyle(Pal.warn) }
                Text(w == nil ? "—" : "\(pct)%").font(Pal.font(13, .bold)).foregroundStyle(pct >= 90 ? Pal.critInk : hot ? Pal.accent : Pal.text1).monospacedDigit()
            }.frame(width: 48, alignment: .trailing)
            t(w?.resets.map { spanText($0 - now) } ?? "—", 9, hot ? Pal.text1 : Pal.text3, bold: false, 0.4).frame(width: 50, alignment: .trailing).lineLimit(1)
        }
        .padding(.horizontal, 6).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(hot ? Pal.hoverFill : .clear))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hot)
    }

    static func readout(_ r: Row, _ w: UsageWin, now: Double) -> String {
        var parts = [r.code]
        if let rs = w.resets {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            let d = Date(timeIntervalSince1970: rs); f.dateFormat = Calendar.current.isDateInToday(d) ? "'TODAY' HH:mm" : "EEE HH:mm"
            parts.append("RESETS " + f.string(from: d).uppercased())
        }
        if let rs = w.resets, let frac = w.frac(len: r.len, now: now) {
            parts.append("\(Int((frac * 100).rounded()))% THROUGH")
            let elapsed = r.len * frac
            if frac > 0.03, w.pct > 0, w.pct < 100 {
                let toLimit = (100 - Double(w.pct)) / (Double(w.pct) / elapsed)
                if toLimit < rs - now { parts.append("OUT IN " + spanText(toLimit).uppercased()) }
            }
        }
        return parts.joined(separator: " · ")
    }
}
