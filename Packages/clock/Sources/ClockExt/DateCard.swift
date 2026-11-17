// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// The date card. Stage 1 (hover): today at a glance. Stage 2 (click): the same card grows down into the month.
/// The panchang rows (a Hindu calendar detail) are not shown: there is no data source for them yet.
struct DateCard: View {
    @ObservedObject private var pop = PopState.shared
    @State private var viewMonth = Date()          // any date within the month shown
    @State private var selected = Date()
    @State private var hoverDay: Date?

    private static let pad: CGFloat = 16
    static let width: CGFloat = 344
    static let glanceH: CGFloat = 252
    static let monthH: CGFloat = 352
    static func size(stage: Int) -> CGSize { CGSize(width: width, height: glanceH + (stage == 2 ? monthH : 0)) }

    private static var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c }()
    private var cal: Calendar { Self.cal }
    private static func f(_ t: String) -> DateFormatter { let d = DateFormatter(); d.dateFormat = t; return d }
    private static let monthName = f("MMMM"), dow = f("EEE"), year = f("yyyy"), dowFull = f("EEEE")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            glance.frame(height: Self.glanceH, alignment: .top)
            month.frame(height: Self.monthH, alignment: .top).opacity(pop.stage == 2 ? 1 : 0)
        }
        .padding(.horizontal, Self.pad)
        .frame(width: Self.width, alignment: .topLeading)
        .onChange(of: pop.stage) { _, s in if s == 1 { viewMonth = Date(); selected = Date() } }
        .onChange(of: pop.card) { _, _ in viewMonth = Date(); selected = Date() }
    }

    // MARK: glance

    private func label(_ s: String, _ size: CGFloat = 9, color: Color = Pal.text4, tracking: CGFloat = 1.4, weight: Font.Weight = .bold) -> some View {
        Text(s).font(Pal.font(size, weight)).tracking(tracking).foregroundStyle(color)
    }

    private var glance: some View {
        Group {
            let now = ClockModel.shared.minute
            let doy = cal.ordinality(of: .day, in: .year, for: now) ?? 1
            let ylen = cal.range(of: .day, in: .year, for: now)?.count ?? 365
            let week = cal.component(.weekOfYear, from: now)
            let mlen = cal.range(of: .day, in: .month, for: now)?.count ?? 30
            let dom = cal.component(.day, from: now)
            let tz = TimeZone.current
            let off = tz.secondsFromGMT(for: now)
            let offS = String(format: "UTC%+03d:%02d", off / 3600, abs(off) / 60 % 60)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    label("DATE", 10, color: Pal.amberDim, tracking: 2.6)
                    Rectangle().fill(Pal.amberGhost).frame(height: 1)
                    label("WEEK \(week)", 9, color: Pal.text4, tracking: 1.6)
                }.frame(height: 14).padding(.top, Self.pad)

                HStack(alignment: .center, spacing: 0) {
                    HStack(spacing: 11) {
                        Text(String(dom)).font(Pal.font(36, .bold)).foregroundStyle(Pal.text1)
                        VStack(alignment: .leading, spacing: 1) {
                            label("\(Self.dow.string(from: now).uppercased()) · \(Self.monthName.string(from: now).uppercased())", 12, color: Pal.accent, tracking: 1.6)
                            label(Self.year.string(from: now), 10, color: Pal.text4, tracking: 1.4, weight: .regular)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("DAY \(doy)").font(Pal.font(17, .bold)).foregroundStyle(Pal.text1)
                        label("OF \(ylen)", 9, color: Pal.text4, tracking: 1.4, weight: .regular)
                    }
                }.frame(height: 54)

                VStack(spacing: 3) {
                    ZStack(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(Pal.groove)
                            Capsule().fill(Pal.accent).frame(width: g.size.width * CGFloat(doy) / CGFloat(ylen))
                        }
                    }.frame(height: 3)
                    HStack {
                        label("YEAR \(Int((Double(doy) / Double(ylen) * 100).rounded()))%", 9, tracking: 1.2, weight: .regular)
                        Spacer()
                        label("\(ylen - doy) DAYS LEFT", 9, color: Pal.amberDim, tracking: 1.2, weight: .regular)
                    }
                }

                VStack(spacing: 1) {
                    fact("WEEK", "\(week) · ISO \(cal.component(.yearForWeekOfYear, from: now))-W\(String(format: "%02d", week))")
                    fact("MONTH", "\(dom) of \(mlen) · \(mlen - dom) left")
                    fact("ZONE", "\(tz.abbreviation(for: now) ?? tz.identifier) · \(offS)\(tz.isDaylightSavingTime(for: now) ? " · DST" : "")")
                }

                Spacer(minLength: 0)
                Rectangle().fill(Pal.amberGhost).frame(height: 1)
                Button { PopState.shared.setStage(pop.stage == 1 ? 2 : 1) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            label("MONTH ENDS · \(mlen - dom == 0 ? "TODAY" : "\(mlen - dom) DAYS")", 12, color: Pal.text1, tracking: 1)
                            label("NEXT MONDAY · \(Self.nextMonday(now))", 9, color: Pal.accent, tracking: 1.2)
                        }
                        Spacer()
                        label(pop.stage == 2 ? "MONTH ▴" : "MONTH ▾", 10, color: Pal.amberDim, tracking: 1.4)
                    }.frame(height: 34).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.bottom, 14)
            }
        }
    }

    private func fact(_ code: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            label(code, 9, color: Pal.amberDim, tracking: 1.4).frame(width: 44, alignment: .leading)
            Text(value).font(Pal.font(12)).foregroundStyle(Pal.text1).lineLimit(1)
            Spacer(minLength: 0)
        }.frame(height: 16)
    }

    private static func nextMonday(_ d: Date) -> String {
        let next = cal.nextDate(after: d, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? d
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: next)).day ?? 0
        return "\(dayMonth.string(from: next).uppercased()) · IN \(days)D"
    }
    private static let dayMonth = f("d MMM")

    // MARK: month

    private var month: some View {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: viewMonth))!
        let lead = (cal.component(.weekday, from: first) + 5) % 7
        let today = Date()
        let nowMonth = cal.isDate(first, equalTo: today, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Pal.amberGhost).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.monthName.string(from: first).uppercased()).font(Pal.font(14, .bold)).tracking(1.2).foregroundStyle(Pal.text1)
                label(Self.year.string(from: first), 10, tracking: 1.4, weight: .regular)
                Spacer()
                nav("‹") { step(-1) }
                nav("TODAY", enabled: !nowMonth || !cal.isDate(selected, inSameDayAs: today)) { viewMonth = today; selected = today }
                nav("›") { step(1) }
            }
            HStack(spacing: 0) {
                label("W", 9, color: Pal.amberDim, tracking: 0).frame(width: 26)
                ForEach(["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"], id: \.self) { d in
                    label(d, 9, color: Pal.text4, tracking: 1.2).frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { r in
                    let rowStart = cal.date(byAdding: .day, value: r * 7 - lead, to: first)!
                    HStack(spacing: 0) {
                        label(String(cal.component(.weekOfYear, from: cal.date(byAdding: .day, value: 3, to: rowStart)!)), 9, color: Pal.amberDim, tracking: 0, weight: .regular).frame(width: 26)
                        ForEach(0..<7, id: \.self) { c in
                            cell(cal.date(byAdding: .day, value: c, to: rowStart)!, in: first, today: today)
                        }
                    }
                }
            }
            selectedLine(today)
        }
    }

    private func nav(_ s: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label(s, s == "TODAY" ? 9 : 14, color: enabled ? Pal.text3 : Pal.text4.opacity(0.4), tracking: 1.2)
                .padding(.horizontal, 6).frame(height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled)
    }

    private func step(_ n: Int) { viewMonth = cal.date(byAdding: .month, value: n, to: viewMonth) ?? viewMonth }

    private func cell(_ d: Date, in first: Date, today: Date) -> some View {
        let inMonth = cal.isDate(d, equalTo: first, toGranularity: .month)
        let isToday = cal.isDate(d, inSameDayAs: today), isSel = cal.isDate(d, inSameDayAs: selected)
        let wd = cal.component(.weekday, from: d), weekend = wd == 1 || wd == 7
        let hov = hoverDay.map { cal.isDate($0, inSameDayAs: d) } ?? false
        let shape = RoundedRectangle(cornerRadius: 7)
        return Text(String(cal.component(.day, from: d)))
            .font(Pal.font(13, isToday ? .bold : .regular))
            .foregroundStyle(isToday ? Pal.accent : !inMonth ? Pal.text4.opacity(0.5) : weekend ? Pal.text3 : Pal.text1)
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(shape.fill(isSel ? Pal.selected : hov ? Pal.hoverFill : .clear))
            .overlay(shape.stroke(isSel ? Pal.selectedLine : isToday ? Pal.accent.opacity(0.35) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { h in if h { hoverDay = d } else if hoverDay == d { hoverDay = nil } }
            .onTapGesture {
                selected = d
                if !inMonth { viewMonth = d }
            }
            .animation(.easeOut(duration: 0.12), value: hov)
            .animation(.easeOut(duration: 0.12), value: isSel)
    }

    private func selectedLine(_ today: Date) -> some View {
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: today), to: cal.startOfDay(for: selected)).day ?? 0
        let rel = days == 0 ? "TODAY" : days == 1 ? "TOMORROW" : days == -1 ? "YESTERDAY" : days > 0 ? "IN \(days) DAYS" : "\(-days) DAYS AGO"
        let doy = cal.ordinality(of: .day, in: .year, for: selected) ?? 1
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            label("\(Self.dow.string(from: selected).uppercased()) \(cal.component(.day, from: selected))", 12, color: Pal.text1, tracking: 1.2)
            label(rel, 9, color: Pal.accent, tracking: 1.2)
            Spacer()
            label("WEEK \(cal.component(.weekOfYear, from: selected)) · DAY \(doy)", 9, color: Pal.text4, tracking: 1.2, weight: .regular)
        }.padding(.top, 4)
    }
}
