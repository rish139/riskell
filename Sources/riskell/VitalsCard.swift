import SwiftUI
import RiskellKit

/// STATS / SYSTEM: one screen, no tabs. The machine's pulse (CPU %, load, uptime, the last minute of CPU and memory), attention pills
/// that exist only when something needs attention, the die laid out as the silicon is, six facts shown nowhere else, and the apps
/// using the machine grouped by application, sortable, searchable, with a confirmed END. Everything is read in-process, and only
/// while this card is open (Vitals.start/stop).
struct VitalsCard: View {
    @EnvironmentObject var s: Store
    @EnvironmentObject var gauges: Gauges      // redraws on the timer-driven numbers
    @ObservedObject private var v = Vitals.shared
    @ObservedObject private var pop = Popout.shared

    static let pad: CGFloat = 16, width: CGFloat = 468
    static let rowH: CGFloat = 31, rowsShown = 6
    static var size: CGSize { CGSize(width: width, height: 673 + CGFloat(alerts().count) * 38) }

    @State private var sortCPU = true
    @State private var searching = false
    @State private var query = ""
    @State private var confirm: String? = nil
    @State private var hoverRow: String? = nil
    @State private var hoverIdx: Int? = nil
    @FocusState private var searchFocus: Bool

    // MARK: attention

    struct Alert: Hashable { let text: String; let crit: Bool }
    static func alerts() -> [Alert] {
        var a: [Alert] = []
        let v = Vitals.shared, gb = { (b: Double) in String(format: "%.1f GB", b / 1_073_741_824) }
        for d in v.disks {
            let pct = Double(d.used) / Double(d.total) * 100
            if pct >= 85 || d.free < 4_000_000_000 { a.append(Alert(text: "DISK \(d.name.uppercased()) \(Int(pct.rounded()))% FULL · \(gb(Double(d.free))) LEFT", crit: pct >= 95)) }
        }
        if v.pressure >= 4 { a.append(Alert(text: "MEMORY PRESSURE CRITICAL · \(gb(v.available)) AVAILABLE", crit: true)) }
        else if v.pressure >= 2 { a.append(Alert(text: "MEMORY PRESSURE · \(gb(v.available)) AVAILABLE", crit: false)) }
        let cores = Double(max(1, ProcessInfo.processInfo.processorCount)), q = v.load[0] / cores * 100
        if q >= 150 { a.append(Alert(text: "CPU OVERLOADED · LOAD \(String(format: "%.1f", v.load[0])) ON \(Int(cores)) CORES", crit: q >= 250)) }
        if let t = store.thermal.tempC, t >= 85 { a.append(Alert(text: "CPU HOT · \(Int(t.rounded()))°C", crit: t >= 95)) }
        if let b = store.batPct, !store.onAC, b <= 15 { a.append(Alert(text: "BATTERY \(b)%", crit: b <= 8)) }
        if let hog = v.procs.max(by: { $0.cpu < $1.cpu }), hog.cpu >= 2.5 { a.append(Alert(text: "\(hog.name.uppercased()) USING \(String(format: "%.1f", hog.cpu)) CORES", crit: false)) }
        return a
    }

    var body: some View {
        let alerts = Self.alerts()
        VStack(alignment: .leading, spacing: 10) {
            header(alerts)
            Rectangle().fill(Pal.amberGhost).frame(height: 1)
            pulse
            ForEach(alerts, id: \.self) { pill($0) }
            die
            facts
            apps
            footer
        }
        .padding(.horizontal, Self.pad).padding(.top, 14).padding(.bottom, Self.pad)
        .frame(width: Self.width, alignment: .topLeading)
        .onAppear { Vitals.shared.start() }
        .onDisappear { Vitals.shared.stop(); if searching { Popout.shared.setKeyable(false) }; searching = false; query = ""; confirm = nil }
        .onChange(of: alerts.count) { _, _ in Popout.shared.refit() }
    }

    // MARK: pieces

    private func t(_ s: String, _ size: CGFloat, _ color: Color, bold: Bool = true, _ ls: CGFloat = 1.2) -> some View {
        Text(s).font(Pal.font(size, bold ? .bold : .regular)).tracking(ls).foregroundStyle(color)
    }

    private func header(_ alerts: [Alert]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            t("SYSTEM", 10, Pal.amberDim, 2.6)
            Text("STATS").font(Pal.font(15, .bold)).foregroundStyle(Pal.text1)
            Spacer()
            Circle().fill(alerts.contains { $0.crit } ? Pal.crit : alerts.isEmpty ? Pal.accent : Pal.warn).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }.frame(height: 20)
    }

    private var pulse: some View {
        let hist = v.hist
        return HStack(alignment: .center, spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                t("CPU · \(Self.chip)", 10, Pal.amberDim, 1.4).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(s.cpu)").font(Pal.font(27, .bold)).foregroundStyle(Pal.text1)
                    Text("%").font(Pal.font(11, .bold)).foregroundStyle(Pal.text3)
                }
                t("LOAD " + v.load.map { String(format: "%.2f", $0) }.joined(separator: " · "), 9, Pal.text4, bold: false).lineLimit(1)
                t("UP " + Self.uptime(v.uptime), 9, Pal.text4, bold: false)
            }.frame(width: 169, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                let h = hoverIdx.flatMap { $0 < hist.count && hist[$0].cpu == hist[$0].cpu ? hist[$0] : nil }
                t(h.map { "-\(Int(Date().timeIntervalSince1970 - $0.t))S  CPU \(Int($0.cpu.rounded()))%  MEM \(Int($0.mem.rounded()))%" } ?? "CPU · MEMORY · 60 S",
                  10, h == nil ? Pal.amberDim : Pal.accent, 1.4).lineLimit(1)
                PctChart(hist: hist, hover: $hoverIdx).frame(height: 78)
            }
        }.frame(height: 96)
    }

    private func pill(_ a: Alert) -> some View {
        let c = a.crit ? Pal.crit : Pal.warn
        return t("▲  " + a.text, 9, c, 1.2).lineLimit(1)
            .padding(.horizontal, 10).frame(height: 22, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(c.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(c.opacity(0.55), lineWidth: 1))
            .frame(height: 22).padding(.vertical, 3)
    }

    // the die: one block per cluster, each core a cell whose heat is its real load (one canvas, and no easing: the loads are 2 s samples, and a 0.4 s ease redraws it at the display's rate for a fifth of the time)
    private var die: some View {
        DieCanvas(u: LoadVec(s.cores.map(Double.init)))
            .frame(height: 90)
    }

    // MARK: facts

    private var facts: some View {
        let w = (Self.width - 2 * Self.pad - 28) / 3
        let gb = { (b: Double) in String(format: "%.1f GB", b / 1_073_741_824) }
        let d = store.batDetail, bp = store.batPct
        let temp = store.thermal.tempC, rpm = store.thermal.fanRPM
        let cores = Double(max(1, ProcessInfo.processInfo.processorCount))
        return VStack(spacing: 0) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    tile("MEMORY", String(format: "%.1f / %.0f", s.memUsedG, s.memTotalG), "GB", g1: s.memTotalG > 0 ? s.memUsedG / s.memTotalG : -1,
                         g2: s.memTotalG > 0 ? min(v.cached, v.available) / 1_073_741_824 / s.memTotalG : 0,
                         sub: "\(gb(v.available).uppercased()) AVAILABLE",
                         sub2: v.swapTotal > 0 ? "SWAP \(gb(v.swapUsed)) / \(gb(v.swapTotal))".uppercased() : "NO SWAP").frame(width: w)
                    tile("BATTERY", bp.map(String.init) ?? "—", "%", g1: bp.map { Double($0) / 100 } ?? -1,
                         gColor: (bp ?? 100) <= 20 && !store.onAC ? Pal.crit : Pal.accent,
                         sub: batSub(bp: bp, eta: d.minutes),
                         sub2: d.health.map { "HEALTH \(Int($0.rounded()))% · \(d.cycles ?? 0) CYC" } ?? "").frame(width: w)
                    tile("THERMAL", temp.map { String(Int($0.rounded())) } ?? "—", "°C", g1: temp.map { max(0, min(1, ($0 - 25) / 65)) } ?? -1,
                         gColor: (temp ?? 0) >= 80 ? Pal.crit : (temp ?? 0) >= 65 ? Pal.warn : Pal.accent,
                         sub: temp == nil ? "NO SENSORS" : "CPU DIE · AVERAGE",
                         sub2: rpm.map { $0 < 50 ? "FAN OFF" : "FAN · " + ($0 >= 1000 ? String(format: "%.1fK", Double($0) / 1000) : "\($0)") + " RPM" } ?? "").frame(width: w)
                }
                GridRow {
                    storage.gridCellColumns(2)
                    VStack(alignment: .leading, spacing: 4) {
                        t("PRESSURE", 9, Pal.amberDim, 1.2)
                        pressureRow("CPU", v.load[0] / cores * 100, warn: 100)
                        pressureRow("MEM", Double(100 - v.freePct), warn: 70)
                    }.frame(width: w, alignment: .topLeading)
                }
            }.padding(.vertical, 4)
        }
    }

    private func batSub(bp: Int?, eta: Int?) -> String {
        guard bp != nil else { return "NO BATTERY" }
        let p = abs(s.powerW ?? 0), e = eta.map { $0 >= 60 ? "\($0 / 60)H \(String(format: "%02d", $0 % 60))M" : "\($0)M" }
        if store.charging { return "+\(String(format: "%.1f", p)) W" + (e.map { " · \($0) TO FULL" } ?? " CHARGING") }
        if !store.onAC { return "\(String(format: "%.1f", p)) W DRAW" + (e.map { " · \($0) LEFT" } ?? "") }
        return "NOT CHARGING · ON AC"
    }

    private func tile(_ label: String, _ value: String, _ unit: String, g1: Double, g2: Double = 0, gColor: Color = Pal.accent, sub: String, sub2: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            t(label, 9, Pal.amberDim, 1.2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Pal.font(17, .bold)).foregroundStyle(Pal.text1).lineLimit(1).minimumScaleFactor(0.7)
                t(unit, 9, Pal.text4)
            }
            if g1 >= 0 {
                GeometryReader { g in
                    Capsule().fill(Pal.groove)
                    Capsule().fill(gColor.opacity(0.28)).frame(width: g.size.width * max(0, min(1 - g1, g2))).offset(x: g.size.width * min(1, g1))
                    Capsule().fill(gColor).frame(width: g.size.width * max(0, min(1, g1)))
                }.frame(height: 3).padding(.vertical, 1)
            }
            if !sub.isEmpty { t(sub, 9, Pal.text3, bold: false, 0.6).lineLimit(1).minimumScaleFactor(0.8) }
            if !sub2.isEmpty { t(sub2, 9, Pal.text4, bold: false, 0.6).lineLimit(1).minimumScaleFactor(0.8) }
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                t("STORAGE", 9, Pal.amberDim, 1.2); Spacer()
                t("R \(Self.rate(v.ioR))  ·  W \(Self.rate(v.ioW))", 9, Pal.text4, bold: false, 1)
            }
            ForEach(v.disks) { d in
                let pct = Double(d.used) / Double(d.total) * 100
                HStack(spacing: 9) {
                    t(String(d.name.uppercased().prefix(9)), 9, Pal.text3).frame(width: 58, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(Pal.groove)
                        Capsule().fill(pct >= 95 ? Pal.crit : pct >= 85 ? Pal.warn : Pal.accent).frame(width: g.size.width * min(1, pct / 100))
                    }.frame(height: 3)
                    Text("\(Int(pct.rounded()))%").font(Pal.font(12, .bold)).foregroundStyle(pct >= 85 ? Pal.warn : Pal.text1).frame(width: 38, alignment: .trailing)
                    t(String(format: "%.0f GB FREE", Double(d.free) / 1_073_741_824), 9, Pal.text4, bold: false, 1).frame(width: 78, alignment: .trailing).lineLimit(1)
                }.frame(height: 17)
            }
        }
    }

    private func pressureRow(_ name: String, _ val: Double, warn: Double) -> some View {
        HStack(spacing: 6) {
            t(name, 9, Pal.text3).frame(width: 25, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(Pal.groove)
                Capsule().fill(val >= warn ? Pal.warn : Pal.accent).frame(width: g.size.width * min(1, val / 100))
            }.frame(height: 3)
            Text("\(Int(val.rounded()))%").font(Pal.font(12, .bold)).foregroundStyle(val >= warn ? Pal.warn : Pal.text1).frame(width: 36, alignment: .trailing)
        }.frame(height: 17)
    }

    // MARK: apps

    private var groups: [ProcGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = q.isEmpty ? v.procs : v.procs.filter { $0.name.lowercased().contains(q) }
        // bucketed, so a row only moves when an app genuinely changes tier
        let metric: (ProcGroup) -> Double = { sortCPU ? $0.cpu : Double($0.rss) }
        let bucket: (ProcGroup) -> Int = { sortCPU ? Int(($0.cpu * 5).rounded()) : Int((Double($0.rss) / 1.5e8).rounded()) }
        return Array(all.sorted { bucket($0) != bucket($1) ? bucket($0) > bucket($1) : metric($0) > metric($1) }.prefix(30))
    }

    private var apps: some View {
        let list = groups
        let top = max(sortCPU ? 1.0 : 1, list.map { sortCPU ? $0.cpu : Double($0.rss) }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .trailing) {
                HStack(spacing: 8) {
                    t("APPS", 10, Pal.amberDim, 2.6)
                    Rectangle().fill(Pal.amberGhost).frame(height: 1)
                    chip("CPU", sortCPU) { sortCPU = true }
                    chip("MEMORY", !sortCPU) { sortCPU = false }
                }.padding(.trailing, 30).opacity(searching ? 0 : 1).allowsHitTesting(!searching)
                searchField(count: list.count)
            }.frame(height: 26)
            if list.isEmpty {
                t(query.isEmpty ? "READING…" : "NO APP MATCHES “\(query.uppercased())”", 9, Pal.text4, 2.6)
                    .frame(maxWidth: .infinity, minHeight: Self.rowH * CGFloat(Self.rowsShown), alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) { ForEach(list) { row($0, top: top) } }
                }.frame(height: Self.rowH * CGFloat(Self.rowsShown), alignment: .top)
            }
        }
    }

    private func chip(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { t(label, 9, on ? Pal.accent : Pal.text4, 1.2).padding(.vertical, 4).contentShape(Rectangle()) }.buttonStyle(.plain)
    }

    private func searchField(count: Int) -> some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(searching ? Pal.canvas.opacity(0.92) : .clear)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(searching ? Pal.accent.opacity(searchFocus ? 0.75 : 0.4) : Pal.amberDim.opacity(0.5), lineWidth: 1))
                .frame(width: searching ? nil : 24, height: 24)
            if searching {
                HStack(spacing: 6) {
                    ZStack(alignment: .leading) {
                        if query.isEmpty { t("SEARCH APPS", 9, Pal.text4, 1.4) }
                        TextField("", text: $query).textFieldStyle(.plain).font(Pal.font(12)).foregroundStyle(Pal.text1)
                            .focused($searchFocus).onSubmit { }.onExitCommand { closeSearch() }
                    }.padding(.leading, 13)
                    if !query.isEmpty { t("\(count) " + (count == 1 ? "MATCH" : "MATCHES"), 9, count > 0 ? Pal.text3 : Pal.warn, 1.2) }
                    Button { closeSearch() } label: { Text("✕").font(Pal.font(10)).foregroundStyle(Pal.amberDim) }.buttonStyle(.plain).padding(.trailing, 28)
                }
            }
            Button { searching ? closeSearch() : openSearch() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(searching ? Pal.accent : Pal.text3)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .animation(.spring(duration: 0.3, bounce: 0.05), value: searching)
    }

    private func openSearch() { searching = true; Popout.shared.setKeyable(true); DispatchQueue.main.async { searchFocus = true } }
    private func closeSearch() { searching = false; query = ""; searchFocus = false; Popout.shared.setKeyable(false) }

    private func row(_ g: ProcGroup, top: Double) -> some View {
        let frac = max(0, min(1, (sortCPU ? g.cpu : Double(g.rss)) / top))
        let hov = hoverRow == g.name, confirming = confirm == g.name
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ZStack(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 6).fill(Pal.accent.opacity(hov ? 0.16 : 0.09))
                    .frame(width: max(0, geo.size.width * frac), height: Self.rowH - 4).frame(maxHeight: .infinity)
                    .opacity(frac > 0.008 ? 1 : 0)
            }
            HStack(spacing: 8) {
                Text(highlight(g.name, q)).font(Pal.font(12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                t(g.n > 1 ? "×\(g.n)" : "", 9, Pal.text4).frame(width: 30, alignment: .trailing)
                t(g.cpu >= 0.1 ? String(format: "%.1f CORES", g.cpu) : "IDLE", 9, g.cpu < 0.1 ? Pal.text4 : sortCPU ? Pal.accent : Pal.text3).frame(width: 66, alignment: .trailing)
                t(String(format: "%.1f GB", Double(g.rss) / 1_073_741_824), 9, sortCPU ? Pal.text3 : Pal.accent).frame(width: 56, alignment: .trailing)
                ZStack {   // reserved gutter: the END chip lives here, so it never covers a number
                    if g.mine && hov && !confirming {
                        Button { confirm = g.name } label: {
                            t("END", 8, Pal.warn, 1).padding(.horizontal, 6).padding(.vertical, 3)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Pal.warn.opacity(0.6), lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }.frame(width: 38)
            }.padding(.leading, 9).padding(.trailing, 2).opacity(confirming ? 0.15 : 1)
            if confirming {
                HStack(spacing: 8) {
                    t("END \(g.name.uppercased())\(g.n > 1 ? "  ·  \(g.n) PROCESSES" : "") ?", 9, Pal.text1, 1).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    confirmBtn("END", hot: true) { signal(g, SIGTERM) }
                    confirmBtn("FORCE", hot: true) { signal(g, SIGKILL) }
                    confirmBtn("CANCEL", hot: false) { confirm = nil }
                }.padding(.horizontal, 9)
            }
        }
        .frame(height: Self.rowH).contentShape(Rectangle())
        .onHover { h in if h { hoverRow = g.name } else if hoverRow == g.name { hoverRow = nil; if confirm == g.name { confirm = nil } } }
        .animation(.easeOut(duration: 0.15), value: hov)
    }

    private func confirmBtn(_ l: String, hot: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            t(l, 8, hot ? Pal.warn : Pal.text3, 1).padding(.horizontal, 7).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke((hot ? Pal.warn : Pal.text4).opacity(0.6), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func signal(_ g: ProcGroup, _ sig: Int32) { for p in g.pids { kill(p, sig) }; confirm = nil }

    /// the name, with the matched part picked out in the accent colour
    private func highlight(_ name: String, _ q: String) -> AttributedString {
        var a = AttributedString(name); a.foregroundColor = Pal.text1
        if !q.isEmpty, let r = a.range(of: q, options: .caseInsensitive) { a[r].foregroundColor = Pal.accent; a[r].font = Pal.font(12, .bold) }
        return a
    }

    @State private var linkHot: String? = nil
    private var footer: some View {
        HStack(spacing: 16) {
            Spacer()
            link("BTOP ↗") { Self.openBtop() }
            link("ACTIVITY MONITOR ↗") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
        }.frame(height: 24).animation(.easeOut(duration: 0.15), value: linkHot)
    }
    private func link(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button { action(); Popout.shared.close() } label: {
            t(label, 9, linkHot == label ? Pal.accent : Pal.amberDim, 1.4).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { linkHot = $0 ? label : (linkHot == label ? nil : linkHot) }
    }
    /// btop in a new WezTerm window (your terminal)
    static func openBtop() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-na", "WezTerm", "--args", "start", "--", "/opt/homebrew/bin/btop"]
        try? p.run()
    }

    // MARK: formatting

    static let chip: String = {
        var sz = 0; sysctlbyname("machdep.cpu.brand_string", nil, &sz, nil, 0)
        var b = [CChar](repeating: 0, count: max(1, sz)); sysctlbyname("machdep.cpu.brand_string", &b, &sz, nil, 0)
        let s = String(cString: b).replacingOccurrences(of: "Apple ", with: "").uppercased()
        return s.isEmpty ? "CPU" : s
    }()
    static func uptime(_ t: TimeInterval) -> String {
        let m = Int(t / 60), h = m / 60, d = h / 24
        return d > 0 ? "\(d)D \(h % 24)H" : h > 0 ? "\(h)H \(m % 60)M" : "\(m)M"
    }
    static func rate(_ b: Double) -> String {
        if b < 1 { return "0 B/S" }
        if b >= 1_048_576 { return String(format: b >= 10_485_760 ? "%.0f MB/S" : "%.1f MB/S", b / 1_048_576) }
        if b >= 1024 { return "\(Int(b / 1024)) KB/S" }
        return "\(Int(b)) B/S"
    }
}

/// The last minute of CPU (accent, filled) and memory (hairline), % on a fixed 0-100 axis, gaps bridged by a dashed line, a crosshair
/// on hover that the card reads as a caption.
struct PctChart: View {
    let hist: [HistSample]
    @Binding var hover: Int?

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                let L: CGFloat = 26, R = size.width - 3, T: CGFloat = 4, B = size.height - 14, win = 60.0
                guard R > L else { return }
                let now = hist.last?.t ?? Date().timeIntervalSince1970
                let x = { (t: TimeInterval) in R - CGFloat((now - t) / win) * (R - L) }
                let y = { (v: Double) in T + CGFloat(1 - min(1, max(0, v) / 100)) * (B - T) }
                func label(_ s: String, _ p: CGPoint, _ a: UnitPoint) { ctx.draw(Text(s).font(Pal.font(7.5)).foregroundStyle(Pal.text4), at: p, anchor: a) }
                for m in [1.0, 0.5, 0.0] {
                    let yy = (T + CGFloat(1 - m) * (B - T)).rounded() + 0.5
                    ctx.stroke(Path { $0.move(to: CGPoint(x: L, y: yy)); $0.addLine(to: CGPoint(x: R, y: yy)) }, with: .color(Pal.accent.opacity(m == 0 ? 0.20 : 0.07)), lineWidth: 1)
                    label(String(Int(100 * m)), CGPoint(x: L - 5, y: yy), .trailing)
                }
                for (s, secs, a) in [("NOW", 0.0, UnitPoint.topTrailing), ("-30S", 30, .top), ("-60S", 60, .topLeading)] {
                    let xx = (R - CGFloat(secs / win) * (R - L)).rounded() + 0.5
                    ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: T)); $0.addLine(to: CGPoint(x: xx, y: B)) }, with: .color(Pal.accent.opacity(0.06)), lineWidth: 1)
                    label(s, CGPoint(x: xx, y: B + 3), a)
                }
                // runs of valid samples; a marker (NaN) ends one, and the gap between runs is bridged by a dashed line
                var runs: [[HistSample]] = [], cur: [HistSample] = []
                for h in hist { if h.cpu.isNaN { if !cur.isEmpty { runs.append(cur); cur = [] } } else { cur.append(h) } }
                if !cur.isEmpty { runs.append(cur) }
                let clip = Path(CGRect(x: L, y: 0, width: R - L + 2, height: size.height))
                ctx.clipToLayer { $0.fill(clip, with: .color(.black)) }
                for (k, run) in runs.enumerated() {
                    if k > 0, let a = runs[k - 1].last, let b = run.first {
                        for (get, color) in [({ (h: HistSample) in h.cpu }, Pal.accent.opacity(0.5)), ({ (h: HistSample) in h.mem }, Pal.text1.opacity(0.35))] as [((HistSample) -> Double, Color)] {
                            ctx.stroke(Path { $0.move(to: CGPoint(x: x(a.t), y: y(get(a)))); $0.addLine(to: CGPoint(x: x(b.t), y: y(get(b)))) }, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        }
                    }
                    guard run.count > 1 else { continue }
                    var area = Path(), line = Path(), mem = Path()
                    area.move(to: CGPoint(x: x(run[0].t), y: B))
                    for (i, h) in run.enumerated() {
                        let p = CGPoint(x: x(h.t), y: y(h.cpu)), m = CGPoint(x: x(h.t), y: y(h.mem))
                        area.addLine(to: p); if i == 0 { line.move(to: p); mem.move(to: m) } else { line.addLine(to: p); mem.addLine(to: m) }
                    }
                    area.addLine(to: CGPoint(x: x(run.last!.t), y: B)); area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(Gradient(colors: [Pal.accent.opacity(0.32), Pal.accent.opacity(0.02)]), startPoint: CGPoint(x: 0, y: T), endPoint: CGPoint(x: 0, y: B)))
                    ctx.stroke(mem, with: .color(Pal.text1.opacity(0.55)), lineWidth: 1)
                    ctx.stroke(line, with: .color(Pal.accent), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
                if let l = hist.last, !l.cpu.isNaN { ctx.fill(Path(ellipseIn: CGRect(x: x(l.t) - 2.5, y: y(l.cpu) - 2.5, width: 5, height: 5)), with: .color(Pal.accent)) }
                if let i = hover, i < hist.count, !hist[i].cpu.isNaN {
                    let xx = x(hist[i].t).rounded() + 0.5
                    ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: T)); $0.addLine(to: CGPoint(x: xx, y: B)) }, with: .color(Pal.text1.opacity(0.35)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: xx - 2.5, y: y(hist[i].cpu) - 2.5, width: 5, height: 5)), with: .color(Pal.accent))
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let L: CGFloat = 26, R = g.size.width - 3, now = hist.last?.t ?? 0
                    let t = now - Double((R - p.x) / (R - L)) * 60
                    hover = hist.indices.filter { !hist[$0].cpu.isNaN }.min { abs(hist[$0].t - t) < abs(hist[$1].t - t) }
                case .ended: hover = nil
                }
            }
        }
    }
}

/// Ten per-core loads that interpolate together, so the canvas below eases between samples.
struct LoadVec: VectorArithmetic, Equatable {
    var v: [Double]
    init(_ v: [Double]) { self.v = v.count == 10 ? v : v + [Double](repeating: 0, count: max(0, 10 - v.count)) }
    static var zero: LoadVec { LoadVec([]) }
    static func + (a: LoadVec, b: LoadVec) -> LoadVec { LoadVec(zip(a.v, b.v).map(+)) }
    static func - (a: LoadVec, b: LoadVec) -> LoadVec { LoadVec(zip(a.v, b.v).map(-)) }
    mutating func scale(by r: Double) { v = v.map { $0 * r } }
    var magnitudeSquared: Double { v.reduce(0) { $0 + $1 * $1 } }
}

/// The processor as a floorplan: E cores, then two 4-core P clusters; a cell's heat is that core's load, a hairline gauge per cluster
/// shows its mean.
struct DieCanvas: View, Animatable {
    var u: LoadVec
    var animatableData: LoadVec { get { u } set { u = newValue } }
    private static let clusters: [(String, [Int])] = [("E", [0, 1]), ("P · A", [2, 3, 4, 5]), ("P · B", [6, 7, 8, 9])]

    var body: some View {
        Canvas { ctx, size in
            let unit = (size.width - 12) / 10
            var x: CGFloat = 0
            for (name, ids) in Self.clusters {
                let w = unit * CGFloat(ids.count), mean = ids.map { u.v[$0] }.reduce(0, +) / Double(ids.count)
                let block = Path(roundedRect: CGRect(x: x + 0.5, y: 0.5, width: w - 1, height: size.height - 1), cornerRadius: 8)
                ctx.fill(block, with: .color(Pal.canvas.opacity(0.35)))
                ctx.stroke(block, with: .color(Pal.accent.opacity(0.17)), lineWidth: 1)
                ctx.draw(Text(name).font(Pal.font(9, .bold)).foregroundStyle(Pal.amberDim), at: CGPoint(x: x + 8, y: 8), anchor: .topLeading)
                ctx.draw(Text("\(Int(mean.rounded()))%").font(Pal.font(9, .bold)).foregroundStyle(mean > 70 ? Pal.accent : Pal.text3), at: CGPoint(x: x + w - 8, y: 8), anchor: .topTrailing)
                let gy: CGFloat = 8 + 14
                ctx.fill(Path(roundedRect: CGRect(x: x + 8, y: gy, width: w - 16, height: 1.7), cornerRadius: 0.85), with: .color(Pal.groove))
                ctx.fill(Path(roundedRect: CGRect(x: x + 8, y: gy, width: max(1.7, (w - 16) * mean / 100), height: 1.7), cornerRadius: 0.85), with: .color(Pal.accent))
                let cw = (w - 16 - 4 * CGFloat(ids.count - 1)) / CGFloat(ids.count)
                for (k, id) in ids.enumerated() {
                    let load = max(0, min(100, u.v[id])), frac = load / 100
                    let cell = CGRect(x: x + 8 + CGFloat(k) * (cw + 4), y: 29, width: cw, height: 54)
                    let shape = Path(roundedRect: cell, cornerRadius: 4.5)
                    ctx.fill(shape, with: .color(Pal.canvas.opacity(0.8)))
                    ctx.drawLayer { l in
                        l.clip(to: shape)
                        let h = cell.height * frac
                        l.fill(Path(CGRect(x: cell.minX, y: cell.maxY - h, width: cell.width, height: h)),
                               with: .linearGradient(Gradient(colors: [(load > 88 ? Pal.warn : Pal.accent).opacity(0.8), Pal.accent.opacity(0.22)]),
                                                     startPoint: CGPoint(x: 0, y: cell.maxY - h), endPoint: CGPoint(x: 0, y: cell.maxY)))
                    }
                    ctx.stroke(shape, with: .color(Pal.accent.opacity(0.10 + 0.30 * frac)), lineWidth: 1)
                    let ink = load > 55 ? Pal.canvas : load > 4 ? Pal.text1 : Pal.text4
                    let num = ctx.resolve(Text("\(Int(load.rounded()))").font(Pal.font(11.5, .bold)).foregroundStyle(ink))
                    let pct = ctx.resolve(Text("%").font(Pal.font(8, .bold)).foregroundStyle(ink))
                    let nw = num.measure(in: CGSize(width: 100, height: 20)).width, pw = pct.measure(in: CGSize(width: 100, height: 20)).width
                    let x0 = cell.midX - (nw + pw + 0.5) / 2
                    ctx.draw(num, at: CGPoint(x: x0, y: cell.midY), anchor: .leading)
                    ctx.draw(pct, at: CGPoint(x: x0 + nw + 0.5, y: cell.midY + 1.5), anchor: .leading)
                }
                x += w + 6
            }
        }
    }
}
