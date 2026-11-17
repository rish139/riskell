// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// USAGE / RATE LIMITS: the Claude windows and the OpenCode Go meters, each one compact list. A window is one row: its code, a bar with a
/// tick for how far through the window you are (the pace), the exact %, and its reset countdown. One accent for every bar; it turns orange
/// past 75 % and red past 90 %. Hovering a row names its reset, its pace and, at this speed, when it runs out (OpenCode also its dollars).
/// A missing reading is an empty bar and "—", never an invented value. The footnote says where each number comes from.
struct UsageCard: View {
    @ObservedObject private var state = UsageState.shared
    @ObservedObject private var config = HostConfig.shared
    @State private var hoverC: Int? = nil
    @State private var hoverO: Int? = nil
    @State private var linkHot: String? = nil

    static let pad: CGFloat = 16, width: CGFloat = 380
    private static let h5 = 5.0 * 3600, d7 = 7.0 * 86400

    struct Row: Identifiable {
        let id: String
        let code: String
        let win: UsageWin?
        let len: Double
        var money = false          // OpenCode: the readout names the dollars used of the limit
    }

    /// What the card shows, read from config.json (the same reads as the atom).
    struct Shown {
        let claude: Bool
        let limits: Bool
        let oc: OpenCodeSettings?
        let fake: Bool
    }
    static func shown() -> Shown {
        Shown(claude: UsageConfig.claudeOn(), limits: UsageConfig.claudeLimitsOn(), oc: UsageConfig.opencode(), fake: CommandLine.arguments.contains("--fake-usage"))
    }

    private var claudeRows: [Row] {
        let c = state.claude
        var r = [Row(id: "5h", code: "5H", win: c?.five, len: Self.h5), Row(id: "7d", code: "7D", win: c?.seven, len: Self.d7)]
        if let x = c?.sonnet { r.append(Row(id: "so", code: "SONNET", win: x, len: Self.d7)) }
        if let x = c?.opus { r.append(Row(id: "op", code: "OPUS", win: x, len: Self.d7)) }
        return r
    }
    private var ocRows: [Row] {
        let o = state.opencode
        let monthLen: Double = {
            guard let r = o?.month?.resets else { return 30 * 86400 }
            let d = Date(timeIntervalSince1970: r), prev = Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: d) ?? d.addingTimeInterval(-30 * 86400)
            return max(86400, d.timeIntervalSince(prev))
        }()
        return [Row(id: "roll", code: "ROLL", win: o?.roll, len: Self.h5, money: true), Row(id: "week", code: "WEEK", win: o?.week, len: Self.d7, money: true),
                Row(id: "mon", code: "MON", win: o?.month, len: monthLen, money: true)]
    }

    private static let rowH: CGFloat = 30, rowGap: CGFloat = 2, noteH: CGFloat = 14

    /// The footnote lines: where the numbers come from and what the % is of. Empty when no provider is on. `--fake-usage` names no source.
    static func notes(_ s: Shown, limited: Bool) -> [String] {
        guard s.claude || s.oc != nil else { return [] }
        if s.fake { return ["SAMPLE READINGS · NOTHING IS FETCHED"] }
        var lines: [String] = []
        if s.claude {
            if s.limits { lines.append("CLAUDE LIMITS VIA YOUR CLAUDE CODE LOGIN · UNOFFICIAL") }
            else { lines.append(limited ? "LOCAL CLAUDE CODE LOGS · % OF YOUR LIMITS" : "LOCAL LOGS · TOKENS · SET usage.fiveHourTokens FOR A %") }
        }
        if s.oc != nil { lines.append("OPENCODE VIA YOUR BROWSER SESSION") }
        return lines
    }

    /// The card's height: the header, then each block, the plan line, the footnote and the footer, 10 pt apart.
    static var size: CGSize {
        func block(_ n: Int) -> CGFloat { 18 + 6 + CGFloat(n) * rowH + CGFloat(max(0, n - 1)) * rowGap }
        let s = shown()
        let c = UsageState.shared.claude, o = UsageState.shared.opencode
        var items: [CGFloat] = [20]
        if s.claude { items.append(block(2 + (c?.sonnet != nil ? 1 : 0) + (c?.opus != nil ? 1 : 0))) }
        if s.oc != nil {
            items.append(block(3))
            if o?.ending == true { items.append(16) }
        }
        let lines = notes(s, limited: c?.limited == true)
        if !lines.isEmpty { items.append(CGFloat(lines.count) * noteH) }
        if s.oc != nil { items.append(22) }
        return CGSize(width: width, height: 11 + 12 + items.reduce(0, +) + CGFloat(max(0, items.count - 1)) * 10)
    }

    var body: some View {
        let now = Date().timeIntervalSince1970
        let s = Self.shown()
        let lines = Self.notes(s, limited: state.claude?.limited == true)
        VStack(alignment: .leading, spacing: 10) {
            header(s)
            if s.claude { block("CLAUDE", mark: Brand.claude, rows: claudeRows, hover: $hoverC, now: now) }
            if s.oc != nil {
                block("OPENCODE " + (state.opencode?.plan.replacingOccurrences(of: "go-plus", with: "go+").uppercased() ?? "GO"), mark: Brand.opencode, rows: ocRows, hover: $hoverO, now: now)
                if let o = state.opencode, o.ending {
                    t("PLAN ENDS " + Self.dayMonth(o.endsAt), 9, Pal.warn, 1.4).frame(height: 16).padding(.leading, 2)
                }
            }
            if !lines.isEmpty { note(lines) }
            if s.oc != nil { footer(s) }
        }
        .padding(.horizontal, Self.pad).padding(.top, 11).padding(.bottom, 12)
        .frame(width: Self.width, alignment: .topLeading)
    }

    private func t(_ s: String, _ size: CGFloat, _ color: Color, bold: Bool = true, _ ls: CGFloat = 1.2) -> some View {
        Text(s).font(Pal.font(size, bold ? .bold : .regular)).tracking(ls).foregroundStyle(color)
    }

    private func header(_ s: Shown) -> some View {
        let c = state.claude, o = state.opencode
        let times = [s.claude ? c?.fetched : nil, s.oc != nil ? o?.fetched : nil].compactMap { $0 }.filter { $0 > 0 }
        let stale = (s.claude && c?.stale == true) || (s.oc != nil && o?.stale == true)
        let limitsShown = (s.claude && c?.limited == true) || s.oc != nil
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            t("USAGE", 10, Pal.text4, 2.6)
            Text(limitsShown ? "RATE LIMITS" : "TOKENS").font(Pal.font(15, .bold)).foregroundStyle(Pal.text1)
            Spacer()
            t("UPDATED " + (times.min().map { f.string(from: Date(timeIntervalSince1970: $0)) } ?? "—"), 9, stale ? Pal.warn : Pal.text4, bold: false, 1)
            Circle().fill(stale ? Pal.warn : Pal.accent).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }.frame(height: 20)
    }

    /// The footnote, one line per source that is on.
    private func note(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                t(line, 9, Pal.text4, bold: false, 0.4)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(height: Self.noteH, alignment: .leading)
            }
        }
    }

    // MARK: a provider block

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
        let w = r.win, counted = w?.counted == true, pct = counted ? (w?.pct ?? 0) : 0, frac = w?.frac(len: r.len, now: now)
        let sev: Color = pct >= 90 ? Pal.crit : pct >= 75 ? Pal.warn : Pal.accent
        let ahead = counted ? (frac.map { Double(pct) > $0 * 100 + 10 && pct >= 20 } ?? false) : false      // without a limit there is no percentage to be ahead of the pace
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
                Text(w == nil ? "—" : counted ? "\(pct)%" : UsageWin.short(w?.used ?? 0)).font(Pal.font(counted ? 13 : 12, .bold)).foregroundStyle(pct >= 90 ? Pal.critInk : hot ? Pal.accent : Pal.text1).monospacedDigit()
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
        if r.money, let u = w.used, let l = w.limit { parts.append(String(format: "$%.2f/$%.0f", u, l)) }
        if let rs = w.resets, let frac = w.frac(len: r.len, now: now) {
            parts.append("\(Int((frac * 100).rounded()))% THROUGH")
            let elapsed = r.len * frac
            if w.counted, frac > 0.03, w.pct > 0, w.pct < 100 {
                let toLimit = (100 - Double(w.pct)) / (Double(w.pct) / elapsed)
                if toLimit < rs - now { parts.append("OUT IN " + spanText(toLimit).uppercased()) }
            }
        }
        return parts.joined(separator: " · ")
    }

    static func dayMonth(_ t: Double?) -> String {
        guard let t else { return "—" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM d"
        return f.string(from: Date(timeIntervalSince1970: t)).uppercased()
    }

    // MARK: footer

    private func footer(_ s: Shown) -> some View {
        HStack(spacing: 16) {
            Spacer()
            if s.claude { link("CLAUDE USAGE ↗", "https://claude.ai/settings/usage") }
            if let oc = s.oc { link("OPENCODE GO ↗", "https://opencode.ai/console/\(oc.workspace)/go") }
        }.frame(height: 22).animation(.easeOut(duration: 0.15), value: linkHot)
    }

    private func link(_ label: String, _ url: String) -> some View {
        Button { if let u = URL(string: url) { NSWorkspace.shared.open(u) }; PopState.shared.close() } label: {
            t(label, 9, linkHot == label ? Pal.accent : Pal.text4, 1.4).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { linkHot = $0 ? label : (linkHot == label ? nil : linkHot) }
    }
}
