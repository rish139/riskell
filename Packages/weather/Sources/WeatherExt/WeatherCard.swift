// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// WEATHER: one card, two pages. TODAY is the live instrument: a sky hero with the sun's path, six readings, the next 24 hours as one
/// ribbon (night shaded, the forecast curve, rain chance rising from the floor, a NOW cursor) and the next 16 days as one band. Clicking
/// an hour or a day turns the same card into that date's page: hero, readings, ribbon and band read a different row of the same payload.
struct WeatherCard: View {
    @ObservedObject private var state = WeatherState.shared
    @ObservedObject private var config = HostConfig.shared
    @ObservedObject private var pop = PopState.shared
    @State private var focus: String? = nil          // a date's page, or nil for today
    @State private var hourHover: Int? = nil
    @State private var dayHover: Int? = nil
    @State private var navHot: String? = nil

    static let pad: CGFloat = 16, width: CGFloat = 508
    static let size = CGSize(width: width, height: 579)

    private var w: WX? { state.wx }
    private var today: String { w?.todayKey ?? "" }
    private var dayKey: String { focus ?? today }
    private var day: WX.Day? { w?.days.first { $0.date == dayKey } }

    var body: some View {
        Group {
            if let w {
                VStack(alignment: .leading, spacing: 10) {
                    header(w)
                    Rectangle().fill(Pal.amberGhost).frame(height: 1)
                    hero(w)
                    readings(w)
                    secHead(focus == nil ? "NEXT 24 HOURS" : "HOURS · \(Self.weekday(dayKey)) \(dayKey.suffix(2))", hourReadout(w))
                    HourRibbon(points: pagePoints(w), nowIndex: pageNow(w), hover: $hourHover) { open(String($0.prefix(10))) }.frame(height: 124)
                    secHead("NEXT 14 DAYS", dayReadout(w))
                    DayBand(days: fortnight(w), today: today, focus: focus, hover: $dayHover) { open($0) }.frame(height: 120)
                    footer(w)
                }
                .padding(.horizontal, Self.pad).padding(.top, 11).padding(.bottom, 12)
            } else {
                Text("WEATHER UNAVAILABLE").font(Pal.font(10, .bold)).tracking(2.4).foregroundStyle(Pal.text4).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.width, alignment: .topLeading)
        .onChange(of: pop.open) { _, o in if !o { focus = nil } }
        .onChange(of: pop.card) { _, c in if c != "weather" { focus = nil } }
    }

    private func open(_ date: String) { withAnimation(.easeOut(duration: 0.2)) { focus = date == today ? nil : date } }

    // MARK: pieces

    private func t(_ s: String, _ size: CGFloat, _ color: Color, bold: Bool = true, _ ls: CGFloat = 1.2) -> some View {
        Text(s).font(Pal.font(size, bold ? .bold : .regular)).tracking(ls).foregroundStyle(color)
    }

    private func header(_ w: WX) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            t("WEATHER", 10, Pal.amberDim, 2.6)
            Text(focus == nil ? "TODAY" : Self.dateLabel(dayKey)).font(Pal.font(15, .bold)).foregroundStyle(Pal.text1)
            t(w.location.uppercased(), 9, Pal.text4, 1.6)
            Spacer()
            if focus != nil {
                nav("‹") { open(Self.shift(dayKey, -1)) }
                nav("TODAY") { open(today) }
                nav("›") { open(Self.shift(dayKey, 1)) }
            } else {
                t(Self.updated(w), 9, Pal.text4, bold: false, 1)
            }
        }.frame(height: 20)
    }
    private func nav(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            t(label, label == "TODAY" ? 9 : 14, navHot == label ? Pal.accent : Pal.text3, 1.2).padding(.horizontal, 5).frame(height: 20).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { navHot = $0 ? label : (navHot == label ? nil : navHot) }
    }

    private func secHead(_ title: String, _ readout: String) -> some View {
        HStack(spacing: 8) {
            t(title, 10, Pal.amberDim, 2.4).lineLimit(1).fixedSize()
            Rectangle().fill(Pal.amberGhost).frame(height: 1)
            t(readout, 9, hourHover != nil || dayHover != nil ? Pal.accent : Pal.text4, bold: false, 0.8).lineLimit(1).fixedSize().layoutPriority(1)     // takes the room it needs from the rule beside it
        }.frame(height: 18)
    }

    // MARK: hero

    private func hero(_ w: WX) -> some View {
        let night = focus == nil && w.cur.isDay == 0
        let code = focus == nil ? w.cur.code : day?.code ?? 0
        let tone = WeatherFace.tone(code, night: night)
        return HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: WXText.symbol(code, day: !night)).font(Pal.font(30, .semibold)).foregroundStyle(tone)
                    if focus == nil {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(String(format: "%.1f", w.cur.temp)).font(Pal.font(36, .bold)).foregroundStyle(Pal.text1)
                            Text("°").font(Pal.font(18)).foregroundStyle(Pal.text3)
                        }
                    } else if let d = day {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(Int(d.max.rounded()))°").font(Pal.font(32, .bold)).foregroundStyle(Pal.text1)
                            Text("\(Int(d.min.rounded()))°").font(Pal.font(20, .bold)).foregroundStyle(Pal.text3)
                        }
                    }
                }
                t(WXText.label(code).uppercased(), 11, tone, 1.6)
                if focus == nil {
                    t("FEELS \(String(format: "%.1f", w.cur.feels))°" + (day.map { " · H \(Int($0.max.rounded()))° L \(Int($0.min.rounded()))°" } ?? ""), 9, Pal.text3, bold: false, 1).lineLimit(1)
                } else if let d = day, let a = d.feelsMax, let b = d.feelsMin {
                    t("FEELS \(Int(b.rounded()))° TO \(Int(a.rounded()))°", 9, Pal.text3, bold: false, 1)
                }
            }
            Spacer(minLength: 0)
            SunDial(sunrise: day?.sunrise ?? "", sunset: day?.sunset ?? "", nowTime: focus == nil ? String(w.cur.time.suffix(5)) : nil, daylight: day?.daylight,
                    tomorrowRise: w.days.first { $0.date == Self.shift(today, 1) }?.sunrise)
                .frame(width: 180, height: 100)
        }
        .frame(height: 104)
    }

    // MARK: readings

    private func readings(_ w: WX) -> some View {
        let c = w.cur
        var cells: [(String, String, String)] = []
        if focus == nil {
            let prev = w.nowIndex.flatMap { $0 >= 3 ? w.hours[$0 - 3].pressure : nil }
            let trend: String = { guard let p = c.pressure, let q = prev else { return "" }; let d = p - q; return abs(d) < 0.7 ? "STEADY" : (d > 0 ? "▲ " : "▼ ") + String(format: "%.1f", abs(d)) }()
            cells = [
                ("WIND", c.windSpeed.map { String(format: "%.0f km/h", $0) } ?? "—", [WXText.windLabel(c.windSpeed), (c.windSpeed ?? 0) >= 2 ? WXText.windArrow(c.windDir) : "", c.windGusts.map { "G\(Int($0.rounded()))" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")),
                ("HUMIDITY", c.humidity.map { "\(Int($0.rounded()))%" } ?? "—", WXText.dew(c.dew)),
                ("PRESSURE", c.pressure.map { "\(Int($0.rounded())) hPa" } ?? "—", trend),
                ("UV INDEX", c.uv.map { String(format: "%.1f", $0) } ?? "—", WXText.uv(c.uv)),
                ("AIR", w.aqi.map { "\(Int($0.usAqi.rounded())) AQI" } ?? "—", w.aqi.map { WXText.aqi($0.usAqi) } ?? "NO READING"),
                ("VISIBILITY", c.visibility.map { String(format: "%.0f km", $0 / 1000) } ?? "—", c.cloud.map { "CLOUD \(Int($0.rounded()))%" } ?? ""),
            ]
        } else if let d = day {
            cells = [
                ("WIND", d.windMax.map { String(format: "%.0f km/h", $0) } ?? "—", [WXText.windLabel(d.windMax), (d.windMax ?? 0) >= 2 ? WXText.windArrow(d.windDir) : "", d.gustMax.map { "G\(Int($0.rounded()))" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")),
                ("RAIN", d.precipSum.map { String(format: "%.1f mm", $0) } ?? "—", d.precipHours.map { "\(Int($0.rounded())) H" } ?? ""),
                ("CHANCE", d.pop.map { "\(Int($0.rounded()))%" } ?? "—", "PEAK"),
                ("UV MAX", d.uv.map { String(format: "%.1f", $0) } ?? "—", WXText.uv(d.uv)),
                ("DAYLIGHT", d.daylight.map { WXText.dur(Int($0 / 60)) } ?? "—", d.sunshine.map { "SUN " + WXText.dur(Int($0 / 60)) } ?? ""),
                ("SUN", "↑ \(d.sunrise)", "↓ \(d.sunset)"),
            ]
        }
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                VStack(alignment: .leading, spacing: 1) {
                    t(c.0, 8.5, Pal.amberDim, 0.8).lineLimit(1)
                    Text(c.1).font(Pal.font(12.5, .bold)).foregroundStyle(Pal.text1).lineLimit(1).minimumScaleFactor(0.7)
                    t(c.2, 7.5, Pal.text4, bold: false, 0.3).lineLimit(1).minimumScaleFactor(0.7)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, i == 0 ? 0 : 8)
                if i < cells.count - 1 { Rectangle().fill(Pal.hairline).frame(width: 1, height: 34) }
            }
        }.frame(height: 40)
    }

    // MARK: ribbon and band data

    private func pagePoints(_ w: WX) -> [WX.Hour] {
        if focus == nil {
            guard let i = w.nowIndex else { return [] }
            let a = max(0, i - 3); return Array(w.hours[a..<min(w.hours.count, a + 27)])
        }
        return w.hours.filter { $0.time.hasPrefix(dayKey) }
    }
    private func pageNow(_ w: WX) -> Int { focus == nil ? (w.nowIndex.map { min($0, 3) } ?? -1) : -1 }
    private func fortnight(_ w: WX) -> [WX.Day] {
        guard let i = w.days.firstIndex(where: { $0.date == today }) else { return [] }
        return Array(w.days[i..<min(w.days.count, i + 14)])
    }

    private func hourReadout(_ w: WX) -> String {
        let p = pagePoints(w)
        if let h = hourHover, h < p.count { let x = p[h]; return "\(x.time.suffix(5)) · \(Int(x.temp.rounded()))° · \(WXText.label(x.code).uppercased())\(x.pop.map { " · RAIN \(Int($0.rounded()))%" } ?? "")" }
        let rain = Self.rainHint(p, from: max(0, pageNow(w)))
        return rain
    }
    private func dayReadout(_ w: WX) -> String {
        let f = fortnight(w)
        if let h = dayHover, h < f.count { let d = f[h]; return "\(Self.weekday(d.date)) \(d.date.suffix(2)) · \(Int(d.max.rounded()))°/\(Int(d.min.rounded()))° · \(WXText.label(d.code).uppercased())\(d.pop.map { " · \(Int($0.rounded()))%" } ?? "")" }
        return "CLICK A DAY"
    }

    // MARK: footer

    /// "HAMBURG 53.55N 10.00E · OPEN-METEO": the configured place (config.json `location`), or just the source when none is set.
    private var placeLine: String {
        guard let lat = config.number("location.lat"), let lon = config.number("location.lon") else { return "OPEN-METEO" }
        let c = String(format: "%.2f%@ %.2f%@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
        return ((config.string("location.name")?.uppercased()).map { $0 + " " } ?? "") + c + " · OPEN-METEO"
    }

    private func footer(_ w: WX) -> some View {
        let m = WXText.moon()
        return HStack(spacing: 8) {
            MoonDisc(p: m.p).frame(width: 18, height: 18)
            t("\(m.name) · \(Int((m.illum * 100).rounded()))%", 9, Pal.text3, 1.2)
            Spacer()
            t(placeLine, 8, Pal.text4, bold: false, 0.8)
        }.frame(height: 28)
    }

    // MARK: formatting

    private static let ymd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f }()
    static func date(_ s: String) -> Date? { ymd.date(from: s) }
    static func weekday(_ s: String) -> String { guard let d = date(s) else { return "" }; let f = DateFormatter(); f.dateFormat = "EEE"; f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: d).uppercased() }
    static func dateLabel(_ s: String) -> String { guard let d = date(s) else { return s }; let f = DateFormatter(); f.dateFormat = "EEE d MMM"; f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: d).uppercased() }
    static func shift(_ s: String, _ n: Int) -> String { guard let d = date(s) else { return s }; return ymd.string(from: d.addingTimeInterval(Double(n) * 86400)) }
    static func updated(_ w: WX) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return "UPDATED " + f.string(from: Date(timeIntervalSince1970: w.syncedAt)) }

    /// "RAIN LIKELY 16:00-19:00 · 70%" / "DRY THROUGH THE NEXT 14 HOURS"
    static func rainHint(_ p: [WX.Hour], from: Int) -> String {
        guard !p.isEmpty else { return "" }
        let end = min(p.count, from + 14)
        var first = -1, last = -1, peak = 0.0, wet = false
        for i in from..<end {
            let pop = p[i].pop ?? 0, w = WXText.isWet(p[i].code) || (p[i].precip ?? 0) > 0.05
            if pop >= 45 || w { if first < 0 { first = i }; last = i; peak = max(peak, pop); if w { wet = true } }
        }
        if first < 0 { return "DRY THROUGH THE NEXT \(end - from) HOURS" }
        let what = wet ? (peak >= 45 ? "RAIN LIKELY" : "RAIN POSSIBLE") : (peak >= 45 ? "SHOWERS LIKELY" : "SHOWERS POSSIBLE")
        let until = last + 1 >= p.count ? "" : " \(p[first].time.suffix(5))–\(p[min(last + 1, p.count - 1)].time.suffix(5))"
        return what + until + (peak >= 20 ? " · \(Int(peak.rounded()))%" : "")
    }
}

/// The sun's path: an arc from sunrise to sunset with the sun at the current time (a full daylight arc on another date's page), the two
/// times at its ends, daylight and time to sunset beneath. After dark the dot rests below the line and the caption counts to sunrise.
struct SunDial: View {
    let sunrise: String, sunset: String, nowTime: String?, daylight: Double?
    var tomorrowRise: String? = nil
    var body: some View {
        Canvas { ctx, size in
            guard let a = WXText.mins(sunrise), let b = WXText.mins(sunset), b > a else { return }
            let cx = size.width / 2, base = size.height - 30, r = min(size.width / 2 - 14, base - 6)
            func pt(_ f: Double) -> CGPoint { let ang = Double.pi * (1 - f); return CGPoint(x: cx + CGFloat(cos(ang)) * r, y: base - CGFloat(sin(ang)) * r) }
            let now = nowTime.flatMap(WXText.mins), frac = now.map { Double($0 - a) / Double(b - a) }
            var arc = Path(); arc.addArc(center: CGPoint(x: cx, y: base), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            ctx.stroke(arc, with: .color(Pal.text4.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let upTo = frac.map { min(1, max(0, $0)) } ?? 1
            if upTo > 0 {
                var lit = Path(); lit.addArc(center: CGPoint(x: cx, y: base), radius: r, startAngle: .degrees(180), endAngle: .degrees(180 + 180 * upTo), clockwise: false)
                ctx.stroke(lit, with: .color(Pal.accent.opacity(0.85)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: cx - r - 8, y: base)); $0.addLine(to: CGPoint(x: cx + r + 8, y: base)) }, with: .color(Pal.text4.opacity(0.5)), lineWidth: 1)
            if let f = frac, f >= 0, f <= 1 {       // the sun, while it is up (after dark there is nothing to show on the arc)
                let p = pt(f)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(Pal.accent.opacity(0.18)))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(Pal.accent))
            }
            func lab(_ s: String, _ p: CGPoint, _ anchor: UnitPoint, _ c: Color = Pal.text3, _ bold: Bool = false) { ctx.draw(Text(s).font(Pal.font(8, bold ? .bold : .regular)).foregroundStyle(c), at: p, anchor: anchor) }
            lab("↑ " + sunrise, CGPoint(x: cx - r, y: base + 6), .top)
            lab("↓ " + sunset, CGPoint(x: cx + r, y: base + 6), .top)
            let day = daylight.map { Int($0 / 60) } ?? (b - a)
            var cap = "DAYLIGHT " + WXText.dur(day)
            if let n = now { cap = n < a ? "SUNRISE IN " + WXText.dur(a - n) : n > b ? (tomorrowRise.flatMap(WXText.mins).map { "SUNRISE IN " + WXText.dur(24 * 60 - n + $0) } ?? "SUNRISE TOMORROW") : "SUNSET IN " + WXText.dur(b - n) }
            lab(cap, CGPoint(x: cx, y: base - r * 0.35), .center, Pal.text1, true)
            if nowTime != nil { lab("DAYLIGHT " + WXText.dur(day), CGPoint(x: cx, y: base + 20), .top, Pal.text4) }
        }
    }
}

/// The phase disc, drawn (not a glyph): the terminator is the projected ellipse x = cos(2 pi p) * r * sqrt(1 - (y/r)^2).
struct MoonDisc: View {
    let p: Double
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 0.5, c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Pal.groove))
            var lit = Path(); let n = 40, k = CGFloat(cos(2 * Double.pi * p)), sign: CGFloat = p < 0.5 ? 1 : -1
            func edge(_ i: Int) -> (CGFloat, CGFloat) { let y = -r + 2 * r * CGFloat(i) / CGFloat(n); return (y, r * sqrt(max(0, 1 - (y / r) * (y / r)))) }
            for i in 0...n { let (y, w) = edge(i); let pt = CGPoint(x: c.x + sign * w, y: c.y + y); i == 0 ? lit.move(to: pt) : lit.addLine(to: pt) }          // the lit limb, top to bottom
            for i in stride(from: n, through: 0, by: -1) { let (y, w) = edge(i); lit.addLine(to: CGPoint(x: c.x + sign * k * w, y: c.y + y)) }               // back up the terminator
            lit.closeSubpath()
            ctx.fill(lit, with: .color(Pal.text1.opacity(0.9)))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Pal.text4.opacity(0.6)), lineWidth: 1)
        }
    }
}

/// The 24-hour ribbon: night shaded, the forecast curve (the part already lived dimmed), rain chance rising from the floor as cool columns,
/// a condition glyph and the hour every third point, a NOW cursor, and a crosshair on hover. Click an hour to open that day.
/// Two layers: the chart itself (redrawn only when its data changes) and the crosshair (the only thing a pointer move redraws).
struct HourRibbon: View {
    let points: [WX.Hour]
    let nowIndex: Int
    @Binding var hover: Int?
    let pick: (String) -> Void

    private static let L: CGFloat = 8, T: CGFloat = 26

    var body: some View {
        GeometryReader { g in
            ZStack {
                RibbonBase(points: points, nowIndex: nowIndex).equatable()
                Canvas { ctx, size in
                    let n = points.count
                    guard let hv = hover, hv < n, n > 1 else { return }
                    let L = Self.L, R = size.width - 8, B = size.height - 18, step = (R - L) / CGFloat(n - 1)
                    let temps = points.map(\.temp), lo = (temps.min() ?? 0) - 1, hi = max((temps.max() ?? 1) + 1, lo + 2)
                    let hx = L + CGFloat(hv) * step, hy = B - CGFloat((points[hv].temp - lo) / (hi - lo)) * (B - Self.T)
                    let col = Path(roundedRect: CGRect(x: hx - step / 2, y: 0, width: step, height: size.height), cornerRadius: 5)     // the whole hour lights up
                    ctx.fill(col, with: .color(Pal.text1.opacity(0.09))); ctx.stroke(col, with: .color(Pal.accent.opacity(0.45)), lineWidth: 1)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: hx, y: 0)); $0.addLine(to: CGPoint(x: hx, y: B)) }, with: .color(Pal.text1.opacity(0.35)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: hx - 3.5, y: hy - 3.5, width: 7, height: 7)), with: .color(Pal.accent))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let n = points.count
                    let h = n > 1 ? max(0, min(n - 1, Int(((p.x - 8) / max(1, g.size.width - 16) * CGFloat(n - 1)).rounded()))) : nil
                    if h != hover { hover = h }
                case .ended: if hover != nil { hover = nil }
                }
            }
            .onTapGesture { if let h = hover, h < points.count { pick(points[h].time) } }
        }
    }
}

private struct RibbonBase: View, Equatable {
    let points: [WX.Hour]
    let nowIndex: Int
    var body: some View {
        Canvas { ctx, size in
            let n = points.count
            guard n > 1 else { return }
            let L: CGFloat = 8, R = size.width - 8, T: CGFloat = 26, B = size.height - 18
            let step = (R - L) / CGFloat(n - 1)
            let temps = points.map(\.temp), lo = (temps.min() ?? 0) - 1, hi = max((temps.max() ?? 1) + 1, lo + 2)
            let x = { (i: Int) in L + CGFloat(i) * step }
            let y = { (v: Double) in B - CGFloat((v - lo) / (hi - lo)) * (B - T) }
            var i = 0
            while i < n {
                if points[i].isDay == 0 {
                    var j = i; while j + 1 < n, points[j + 1].isDay == 0 { j += 1 }
                    ctx.fill(Path(CGRect(x: x(i) - step / 2, y: 0, width: x(j) - x(i) + step, height: size.height)), with: .color(Pal.canvas.opacity(0.35)))
                    i = j + 1
                } else { i += 1 }
            }
            for (k, h) in points.enumerated() {
                let ch = CGFloat((h.pop ?? 0) / 100) * (B - T) * 0.7
                if ch > 0.5 { ctx.fill(Path(roundedRect: CGRect(x: x(k) - step * 0.3, y: B - ch, width: step * 0.6, height: ch), cornerRadius: 1.5), with: .color(Pal.info.opacity(0.28))) }
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: L, y: B + 0.5)); $0.addLine(to: CGPoint(x: R, y: B + 0.5)) }, with: .color(Pal.hairline), lineWidth: 1)
            func curve(_ range: ClosedRange<Int>) -> Path {
                var p = Path()
                for k in range { let pt = CGPoint(x: x(k), y: y(points[k].temp)); k == range.lowerBound ? p.move(to: pt) : p.addLine(to: pt) }
                return p
            }
            let nowK = max(0, min(n - 1, nowIndex))
            if nowIndex > 0 { ctx.stroke(curve(0...nowK), with: .color(Pal.accent.opacity(0.4)), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)) }
            ctx.stroke(curve((nowIndex > 0 ? nowK : 0)...(n - 1)), with: .color(Pal.accent), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            for k in stride(from: nowIndex >= 0 ? nowIndex % 3 : 0, to: n, by: 3) {
                let h = points[k]
                ctx.draw(ctx.resolve(Image(systemName: WXText.symbol(h.code, day: h.isDay != 0)).symbolRenderingMode(.monochrome)), at: CGPoint(x: x(k), y: 9), anchor: .center)
                ctx.draw(Text(String(h.time.suffix(5).prefix(2))).font(Pal.font(8)).foregroundStyle(Pal.text4), at: CGPoint(x: x(k), y: size.height - 8), anchor: .center)
                ctx.draw(Text("\(Int(h.temp.rounded()))°").font(Pal.font(8, .bold)).foregroundStyle(Pal.text3), at: CGPoint(x: x(k), y: y(h.temp) - 8), anchor: .center)
            }
            if nowIndex >= 0, nowIndex < n {
                let nx = x(nowIndex)
                ctx.stroke(Path { $0.move(to: CGPoint(x: nx, y: T - 4)); $0.addLine(to: CGPoint(x: nx, y: B)) }, with: .color(Pal.accent.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                ctx.fill(Path(ellipseIn: CGRect(x: nx - 3.5, y: y(points[nowIndex].temp) - 3.5, width: 7, height: 7)), with: .color(Pal.accent))
            }
        }
    }
}

/// The 16-day band: max and min curves with the volume between them filled, one column per day, weeks ruled in, rain chance as a thin meter
/// under the date. The page you are on is marked. Click a day to open it. Chart and hover marker are separate layers (see HourRibbon).
struct DayBand: View {
    let days: [WX.Day]
    let today: String
    let focus: String?
    @Binding var hover: Int?
    let pick: (String) -> Void

    var body: some View {
        GeometryReader { g in
            ZStack {
                BandBase(days: days, today: today, focus: focus).equatable()
                Canvas { ctx, size in
                    let n = days.count
                    guard let h = hover, h < n, n > 1 else { return }
                    let step = (size.width - 24) / CGFloat(n - 1), x = 12 + CGFloat(h) * step
                    let col = Path(roundedRect: CGRect(x: x - step / 2, y: 0, width: step, height: size.height), cornerRadius: 5)     // the whole day lights up
                    ctx.fill(col, with: .color(Pal.text1.opacity(0.09))); ctx.stroke(col, with: .color(Pal.accent.opacity(0.45)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let n = days.count
                    let h = n > 1 ? max(0, min(n - 1, Int(((p.x - 12) / max(1, g.size.width - 24) * CGFloat(n - 1)).rounded()))) : nil
                    if h != hover { hover = h }
                case .ended: if hover != nil { hover = nil }
                }
            }
            .onTapGesture { if let h = hover, h < days.count { pick(days[h].date) } }
        }
    }
}

private struct BandBase: View, Equatable {
    let days: [WX.Day]
    let today: String
    let focus: String?
    var body: some View {
        Canvas { ctx, size in
            let n = days.count
            guard n > 1 else { return }
            let L: CGFloat = 12, R = size.width - 12, T: CGFloat = 22, B = size.height - 38
            let step = (R - L) / CGFloat(n - 1)
            let hi = (days.map(\.max).max() ?? 1) + 1, lo = (days.map(\.min).min() ?? 0) - 1
            let x = { (i: Int) in L + CGFloat(i) * step }
            let y = { (v: Double) in B - CGFloat((v - lo) / max(1, hi - lo)) * (B - T) }
            if let f = days.firstIndex(where: { $0.date == (focus ?? today) }) { ctx.fill(Path(roundedRect: CGRect(x: x(f) - step / 2, y: 0, width: step, height: size.height), cornerRadius: 5), with: .color(Pal.selected)) }
            for (k, d) in days.enumerated() where WeatherCard.weekday(d.date) == "MON" && k > 0 {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(k) - step / 2, y: 4)); $0.addLine(to: CGPoint(x: x(k) - step / 2, y: size.height - 4)) }, with: .color(Pal.amberGhost), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            var up = Path(), dn = Path()
            for (k, d) in days.enumerated() { let p = CGPoint(x: x(k), y: y(d.max)); k == 0 ? up.move(to: p) : up.addLine(to: p) }
            for (k, d) in days.enumerated() { let p = CGPoint(x: x(k), y: y(d.min)); k == 0 ? dn.move(to: p) : dn.addLine(to: p) }
            var fill = up
            for k in stride(from: n - 1, through: 0, by: -1) { fill.addLine(to: CGPoint(x: x(k), y: y(days[k].min))) }
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [Pal.accent.opacity(0.22), Pal.info.opacity(0.10)]), startPoint: CGPoint(x: 0, y: T), endPoint: CGPoint(x: 0, y: B)))
            ctx.stroke(up, with: .color(Pal.accent), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            ctx.stroke(dn, with: .color(Pal.info), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            for (k, d) in days.enumerated() {
                ctx.draw(ctx.resolve(Image(systemName: WXText.symbol(d.code)).symbolRenderingMode(.monochrome)), at: CGPoint(x: x(k), y: 8), anchor: .center)
                do {
                    ctx.draw(Text("\(Int(d.max.rounded()))°").font(Pal.font(8, .bold)).foregroundStyle(Pal.text3), at: CGPoint(x: x(k), y: y(d.max) - 7), anchor: .center)
                    ctx.draw(Text("\(Int(d.min.rounded()))°").font(Pal.font(8)).foregroundStyle(Pal.text4), at: CGPoint(x: x(k), y: y(d.min) + 8), anchor: .center)
                }
                let label = k == 0 ? "TOD" : String(WeatherCard.weekday(d.date).prefix(2)) + String(d.date.suffix(2))
                ctx.draw(Text(label).font(Pal.font(7.5, k == 0 ? .bold : .regular)).foregroundStyle(k == 0 ? Pal.accent : Pal.text4), at: CGPoint(x: x(k), y: size.height - 17), anchor: .center)
                let pw = step * 0.6, px = x(k) - pw / 2, p = (d.pop ?? 0) / 100
                ctx.fill(Path(roundedRect: CGRect(x: px, y: size.height - 8, width: pw, height: 2), cornerRadius: 1), with: .color(Pal.groove))
                ctx.fill(Path(roundedRect: CGRect(x: px, y: size.height - 8, width: pw * CGFloat(p), height: 2), cornerRadius: 1), with: .color(Pal.info.opacity(0.7)))
            }
        }
    }
}
