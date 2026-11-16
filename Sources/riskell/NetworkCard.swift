import SwiftUI
import RiskellKit

/// NETWORK: who you are connected to and what is flowing right now (live rates and the last minute), four quantities shown nowhere
/// else (signal, link, latency, traffic since boot), then the four radios as tabs: Wi-Fi (link details, a channel map of the air around
/// you, the networks nearby), Bluetooth (paired devices, one click to connect or disconnect), Ethernet (only when a wired link is up)
/// and tunnels. Everything is read only while the card is open, and the slow reads only for the tab that is on show.
struct NetworkCard: View {
    @EnvironmentObject var s: Store
    @ObservedObject private var n = NetLive.shared
    @State private var hover: Int? = nil
    @State private var hoverNet: String? = nil
    @State private var hoverBt: String? = nil
    @State private var linkHot: String? = nil

    static let pad: CGFloat = 16, width: CGFloat = 472
    static let nearRows = 5

    static var size: CGSize { CGSize(width: width, height: 309 + paneHeight()) }
    static func paneHeight() -> CGFloat {
        let n = NetLive.shared
        switch n.tab {
        case .wifi: return n.wifiOn ? 410 : 60
        case .bt: return 30 + CGFloat(min(7, max(1, n.bt.count))) * 32 + 4
        case .eth: return 30 + 6 * 24
        case .vpn: return 30 + CGFloat(min(6, max(1, n.vpn.count))) * 36 + 4
        }
    }

    private var visibleTabs: [NetLive.Tab] { n.ethPresent ? [.wifi, .bt, .eth, .vpn] : [.wifi, .bt, .vpn] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Rectangle().fill(Pal.amberGhost).frame(height: 1)
            hero
            rail
            tabs
            pane
            footer
        }
        .padding(.horizontal, Self.pad).padding(.top, 14).padding(.bottom, Self.pad)
        .frame(width: Self.width, alignment: .topLeading)
        .onAppear { NetLive.shared.start() }
        .onDisappear { NetLive.shared.stop() }
        .onChange(of: n.tab) { _, _ in Popout.shared.refit() }
        .onChange(of: n.bt.count) { _, _ in if n.tab == .bt { Popout.shared.refit() } }
        .onChange(of: n.vpn.count) { _, _ in if n.tab == .vpn { Popout.shared.refit() } }
        .onChange(of: n.wifiOn) { _, _ in if n.tab == .wifi { Popout.shared.refit() } }
    }

    // MARK: pieces

    private func t(_ s: String, _ size: CGFloat, _ color: Color, bold: Bool = true, _ ls: CGFloat = 1.2) -> some View {
        Text(s).font(Pal.font(size, bold ? .bold : .regular)).tracking(ls).foregroundStyle(color)
    }

    private var kindLabel: String { ["wifi": "WI-FI", "eth": "ETHERNET", "linked": "LINKED", "down": "OFFLINE"][s.wifi.kind] ?? "OFFLINE" }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            t("NETWORK", 10, Pal.amberDim, 2.6)
            Text(kindLabel).font(Pal.font(15, .bold)).foregroundStyle(s.wifi.kind == "down" ? Pal.crit : Pal.text1)
            Spacer()
            Circle().fill(s.wifi.kind == "down" ? Pal.crit : Pal.accent).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }.frame(height: 20)
    }

    private var heroLine: String {
        switch s.wifi.kind {
        case "wifi": return [n.band == 0 ? nil : Self.bandName(n.band), n.channel == 0 ? nil : "CH \(n.channel)", n.phy == "—" ? nil : n.phy].compactMap { $0 }.joined(separator: " · ")
        case "eth": return "WIRED · \((s.wifi.primary ?? "").uppercased())"
        case "linked": return "NO ROUTE TO THE INTERNET"
        default: return "NO CONNECTION"
        }
    }
    private var heroName: String {
        switch s.wifi.kind {
        case "wifi": return s.wifi.ssid ?? "Wi-Fi network"
        case "eth": return "Ethernet"
        case "linked": return s.wifi.ssid ?? "Connected, no internet"
        default: return "Offline"
        }
    }

    private var hero: some View {
        let h = n.hist
        return HStack(alignment: .center, spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                t(heroLine, 10, Pal.amberDim, 1.4).lineLimit(1)
                Text(heroName).font(Pal.font(17, .bold)).foregroundStyle(s.wifi.ssid == nil && s.wifi.kind == "wifi" ? Pal.text3 : Pal.text1).lineLimit(1)
                t(n.localIP.isEmpty ? " " : n.localIP + (n.gateway.isEmpty ? "" : " → " + n.gateway), 9, Pal.text4, bold: false, 0).lineLimit(1).minimumScaleFactor(0.85)
                rate("↓", n.rx, big: true).padding(.top, 5)
                rate("↑", n.tx, big: false)
            }.frame(width: 188, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                let sel = hover.flatMap { $0 < h.count ? h[$0] : nil }
                t(sel.map { "-\(Int(Date().timeIntervalSince1970 - $0.t))S  ↓ \(Self.rateText($0.rx))  ↑ \(Self.rateText($0.tx))" } ?? "THROUGHPUT · 60 S",
                  10, sel == nil ? Pal.amberDim : Pal.accent, 1.2).lineLimit(1)
                RateChart(hist: h, hover: $hover).frame(height: 80)
            }
        }.frame(height: 104)
    }

    private func rate(_ arrow: String, _ v: Double, big: Bool) -> some View {
        let (num, unit) = Self.rateParts(v)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(arrow).font(Pal.font(big ? 13 : 10, .bold)).foregroundStyle(big ? Pal.accent : Pal.text4)
            Text(num).font(Pal.font(big ? 24 : 14, .bold)).foregroundStyle(big ? Pal.text1 : Pal.text3)
            t(unit, big ? 9 : 8, Pal.text4, 0.6)
        }
    }

    private var rail: some View {
        let down = s.wifi.kind == "down", wifi = s.wifi.kind == "wifi"
        let snr = n.rssi != 0 ? n.rssi - n.noise : 0
        let q = n.rssi >= -55 ? "EXCELLENT" : n.rssi >= -65 ? "GOOD" : n.rssi >= -75 ? "FAIR" : "WEAK"
        let lat = n.latency
        let cells: [(String, String, String, Color)] = [
            ("SIGNAL", wifi && n.rssi != 0 ? "\(n.rssi) dBm" : "—", wifi && n.rssi != 0 ? "\(q) · SNR \(snr) DB" : s.wifi.kind == "eth" ? "WIRED" : " ", wifi && n.rssi < -75 ? Pal.warn : Pal.text1),
            ("LINK", wifi && n.txRate > 0 ? "\(Int(n.txRate.rounded())) Mb/s" : "—", wifi ? "\(n.width > 0 ? "\(n.width) MHZ" : "—") · \(n.security)" : " ", Pal.text1),
            ("LATENCY", lat.map { String(format: $0 < 10 ? "%.1f ms" : "%.0f ms", $0) } ?? "—", lat == nil ? (down ? "OFFLINE" : "NO GATEWAY") : "JITTER \(String(format: "%.0f", n.jitter)) MS · LOSS \(n.loss)%",
             (lat ?? 0) > 250 || n.loss >= 20 ? Pal.crit : (lat ?? 0) > 120 || n.loss >= 5 ? Pal.warn : Pal.text1),
            ("SINCE BOOT", "↓ " + Self.bytes(n.totalRx), "↑ " + Self.bytes(n.totalTx), Pal.text1),
        ]
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                VStack(alignment: .leading, spacing: 2) {
                    t(c.0, 9, Pal.amberDim, 1.2)
                    Text(c.1).font(Pal.font(14, .bold)).foregroundStyle(c.3).lineLimit(1).minimumScaleFactor(0.8)
                    t(c.2, 8, Pal.text4, bold: false, 0.4).lineLimit(1).minimumScaleFactor(0.75)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, i == 0 ? 0 : 10)
                if i < cells.count - 1 { Rectangle().fill(Pal.hairline).frame(width: 1, height: 38) }
            }
        }.frame(height: 48)
    }

    private var tabs: some View {
        let keys = visibleTabs, w = (Self.width - 2 * Self.pad) / CGFloat(keys.count)
        let at = keys.firstIndex(of: n.tab) ?? 0
        return ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                ForEach(keys, id: \.self) { k in
                    Button { NetLive.shared.select(k) } label: {
                        HStack(spacing: 5) {
                            t(Self.tabName(k), 10, n.tab == k ? Pal.accent : Pal.text4, 1.6)
                            if let b = badge(k) { t(b, 8, n.tab == k ? Pal.amberDim : Pal.text4.opacity(0.7), 0.4) }
                        }.frame(width: w, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Rectangle().fill(Pal.hairline).frame(height: 1)
            Capsule().fill(Pal.accent).frame(width: w - 20, height: 2).offset(x: CGFloat(at) * w + 10).animation(.spring(duration: 0.3, bounce: 0.1), value: at)
        }.frame(height: 29)
    }
    private func badge(_ k: NetLive.Tab) -> String? {
        switch k {
        case .wifi: return n.wifiOn && !n.nearby.isEmpty ? "\(n.nearby.count)" : nil
        case .bt: let c = n.bt.filter(\.connected).count; return c > 0 ? "\(c)" : nil
        case .eth: return nil
        case .vpn: let c = n.vpn.filter(\.on).count; return c > 0 ? "\(c)" : nil
        }
    }

    // MARK: panes

    @ViewBuilder private var pane: some View {
        Group {
            switch n.tab {
            case .wifi: wifiPane
            case .bt: btPane
            case .eth: ethPane
            case .vpn: vpnPane
            }
        }
        .frame(height: Self.paneHeight(), alignment: .top)
        .animation(.easeOut(duration: 0.18), value: n.tab)
    }

    private func paneHead(_ title: String, _ state: String, on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            t(title, 10, Pal.amberDim, 2.2)
            Rectangle().fill(Pal.amberGhost).frame(height: 1)
            t(state, 9, on ? Pal.text3 : Pal.text4, 1.2)
            MiniSwitch(on: on, set: set)
        }.frame(height: 24).padding(.bottom, 6)
    }

    private var wifiPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            paneHead("WI-FI", n.wifiOn ? (s.wifi.kind == "wifi" ? "CONNECTED" : "ON") : "OFF", on: n.wifiOn) { NetLive.shared.setWifi($0) }
            if n.wifiOn {
                let snr = n.rssi != 0 ? n.rssi - n.noise : 0
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        fact("CHANNEL", n.channel > 0 ? "\(n.channel) · \(Self.bandName(n.band))" : "—")
                        fact("WIDTH", n.width > 0 ? "\(n.width) MHZ" : "—")
                        fact("SECURITY", n.security.isEmpty ? "—" : n.security)
                    }
                    GridRow {
                        fact("STANDARD", n.phy.isEmpty ? "—" : n.phy)
                        fact("NOISE", n.noise != 0 ? "\(n.noise) dBm" : "—")
                        fact("SNR", snr > 0 ? "\(snr) dB" : "—")
                    }
                }.frame(height: 76, alignment: .top)
                ChannelMap(nearby: n.nearby, channel: n.channel, band: n.band, hover: hoverNet).frame(height: 80)
                HStack {
                    t("NEARBY", 9, Pal.amberDim, 1.4); Spacer()
                    t(n.scanning ? "SCANNING…" : "\(n.nearby.count) NETWORKS", 9, Pal.text4, bold: false, 1)
                }.frame(height: 18)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) { ForEach(n.nearby) { nearRow($0) } }
                }.frame(height: CGFloat(Self.nearRows) * 28)
                t(nameHint, 8, Pal.text4.opacity(0.8), bold: false, 0.6).lineLimit(1).minimumScaleFactor(0.8).frame(height: 16)
            }
        }
    }

    /// Names need Location permission; say where things stand only while they are hidden
    private var nameHint: String {
        guard s.wifi.ssid == nil else { return " " }
        switch s.wifi.location {
        case "asking": return "WAITING FOR LOCATION PERMISSION · ANSWER THE PROMPT TO SEE NAMES"
        case "denied": return "NAMES HIDDEN · ALLOW RISKELL IN SYSTEM SETTINGS > PRIVACY > LOCATION"
        default: return "NAMES HIDDEN · macOS SHARES THEM ONLY WITH APPS ALLOWED LOCATION"
        }
    }

    private func fact(_ cap: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            t(cap, 9, Pal.amberDim, 1.2)
            Text(v).font(Pal.font(13, .bold)).foregroundStyle(Pal.text1).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nearRow(_ w: NearbyNet) -> some View {
        let hov = hoverNet == w.id
        let q = max(0, min(100, 2 * (w.rssi + 100)))
        return HStack(spacing: 8) {
            Image(systemName: w.secure ? "lock.fill" : "lock.open").font(.system(size: 9)).foregroundStyle(Pal.text4).frame(width: 12)
            Text(w.ssid ?? "Hidden network").font(Pal.font(12, w.current ? .bold : .regular)).foregroundStyle(w.ssid == nil ? Pal.text3 : Pal.text1).lineLimit(1)
            if w.current { t("● YOURS", 8, Pal.accent, 1) }
            Spacer(minLength: 0)
            t(Self.bandName(w.band), 8, Pal.text4, 0.6).padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Pal.text4.opacity(0.4), lineWidth: 1))
            t("CH \(w.channel)", 9, Pal.text3, 0.6).frame(width: 46, alignment: .trailing)
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<4, id: \.self) { i in RoundedRectangle(cornerRadius: 1).fill(q > i * 25 ? (w.current ? Pal.accent : Pal.text2) : Pal.groove).frame(width: 3, height: CGFloat(4 + i * 2)) }
            }.frame(width: 18, height: 12)
            t("\(w.rssi)", 9, Pal.text4, bold: false, 0.4).frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 6).frame(height: 28).background(RoundedRectangle(cornerRadius: 6).fill(hov ? Pal.hoverFill : (w.current ? Pal.selected : .clear)))
        .contentShape(Rectangle()).onHover { h in hoverNet = h ? w.id : (hoverNet == w.id ? nil : hoverNet) }
    }

    private var btPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHead("BLUETOOTH", n.btOn ? "ON" : "OFF", on: n.btOn) { NetLive.shared.setBluetoothPower($0) }
            if n.bt.isEmpty { t(n.btOn ? "NO PAIRED DEVICES" : "BLUETOOTH IS OFF", 9, Pal.text4, 2).frame(maxWidth: .infinity, minHeight: 40) }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) { ForEach(n.bt) { btRow($0) } }
            }
        }
    }

    private func btRow(_ d: BtDevice) -> some View {
        let hov = hoverBt == d.id, busy = n.btBusy == d.id
        return HStack(spacing: 10) {
            Image(systemName: Self.btIcon(d.name)).font(.system(size: 13)).foregroundStyle(d.connected ? Pal.accent : Pal.text4).frame(width: 20)
            Text(d.name).font(Pal.font(12, d.connected ? .bold : .regular)).foregroundStyle(d.connected ? Pal.text1 : Pal.text3).lineLimit(1)
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.small).scaleEffect(0.6) }
            else if hov { t(d.connected ? "DISCONNECT" : "CONNECT", 9, d.connected ? Pal.warn : Pal.accent, 1.2) }
            else if d.connected { t("CONNECTED", 9, Pal.text3, 1.2) }
            Circle().fill(d.connected ? Pal.accent : Pal.groove).frame(width: 6, height: 6)
        }
        .padding(.horizontal, 6).frame(height: 32).background(RoundedRectangle(cornerRadius: 6).fill(hov ? Pal.hoverFill : .clear))
        .contentShape(Rectangle()).onHover { h in hoverBt = h ? d.id : (hoverBt == d.id ? nil : hoverBt) }
        .onTapGesture { NetLive.shared.toggleBluetooth(d) }
    }

    private var ethPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) { t("ETHERNET", 10, Pal.amberDim, 2.2); Rectangle().fill(Pal.amberGhost).frame(height: 1); t(n.ethPresent ? "LINK UP" : "NO LINK", 9, Pal.text3, 1.2) }.frame(height: 24).padding(.bottom, 6)
            ForEach([("INTERFACE", (n.ethName ?? "—").uppercased()), ("ADDRESS", n.ethIP.isEmpty ? "—" : n.ethIP), ("GATEWAY", s.wifi.kind == "eth" && !n.gateway.isEmpty ? n.gateway : "—"),
                     ("DNS", s.wifi.kind == "eth" && !n.dns.isEmpty ? n.dns.prefix(2).joined(separator: "  ") : "—"), ("MAC", n.ethMAC.isEmpty ? "—" : n.ethMAC),
                     ("DEFAULT ROUTE", s.wifi.kind == "eth" ? "YES" : "NO")], id: \.0) { k, v in
                HStack(spacing: 0) { t(k, 9, Pal.amberDim, 1.2).frame(width: 110, alignment: .leading); Text(v).font(Pal.font(12)).foregroundStyle(Pal.text1).lineLimit(1); Spacer(minLength: 0) }.frame(height: 24)
            }
        }
    }

    private var vpnPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) { t("TUNNELS", 10, Pal.amberDim, 2.2); Rectangle().fill(Pal.amberGhost).frame(height: 1); t("\(n.vpn.filter(\.on).count) UP", 9, Pal.text3, 1.2) }.frame(height: 24).padding(.bottom, 6)
            if n.vpn.isEmpty { t("NO VPN CONFIGURATIONS", 9, Pal.text4, 2).frame(maxWidth: .infinity, minHeight: 36) }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(n.vpn) { v in
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill").font(.system(size: 13)).foregroundStyle(v.on ? Pal.accent : Pal.text4).frame(width: 20)
                            Text(v.name).font(Pal.font(12, v.on ? .bold : .regular)).foregroundStyle(v.on ? Pal.text1 : Pal.text3).lineLimit(1)
                            Spacer(minLength: 0)
                            t(v.state.uppercased(), 9, v.on ? Pal.ok : Pal.text4, 1.2)
                            if n.vpnBusy == v.id { ProgressView().controlSize(.small).scaleEffect(0.6) } else { MiniSwitch(on: v.on) { _ in NetLive.shared.toggleVpn(v) } }
                        }.padding(.horizontal, 6).frame(height: 36)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Spacer()
            link("BLUETOOTH SETTINGS ↗", "x-apple.systempreferences:com.apple.BluetoothSettings")
            link("NETWORK SETTINGS ↗", "x-apple.systempreferences:com.apple.Network-Settings.extension")
        }.frame(height: 24).animation(.easeOut(duration: 0.15), value: linkHot)
    }
    private func link(_ label: String, _ url: String) -> some View {
        Button { if let u = URL(string: url) { NSWorkspace.shared.open(u) }; Popout.shared.close() } label: {
            t(label, 9, linkHot == label ? Pal.accent : Pal.amberDim, 1.4).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { linkHot = $0 ? label : (linkHot == label ? nil : linkHot) }
    }

    // MARK: formatting

    static func tabName(_ k: NetLive.Tab) -> String { ["WIFI", "BLUETOOTH", "ETHERNET", "VPN"][k.rawValue] }
    static func bandName(_ b: Int) -> String { b == 1 ? "2.4G" : b == 2 ? "5G" : b == 3 ? "6G" : "—" }
    static func rateParts(_ b: Double) -> (String, String) {
        if b >= 1_048_576 { return (String(format: b >= 10_485_760 ? "%.1f" : "%.2f", b / 1_048_576), "MB/S") }
        if b >= 1024 { return (String(format: b >= 10_240 ? "%.0f" : "%.1f", b / 1024), "KB/S") }
        return (String(Int(b.rounded())), "B/S")
    }
    static func rateText(_ b: Double) -> String { let (n, u) = rateParts(b); return n + " " + u }
    static func bytes(_ b: Double) -> String {
        if b >= 1_073_741_824 { return String(format: "%.1f GB", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.0f MB", b / 1_048_576) }
        return String(format: "%.0f KB", b / 1024)
    }
    static func btIcon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("pods") || n.contains("headphone") || n.contains("buds") { return "headphones" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "computermouse.fill" }
        if n.contains("dualshock") || n.contains("dualsense") || n.contains("controller") { return "gamecontroller.fill" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("watch") || n.contains("pebble") { return "applewatch" }
        return "dot.radiowaves.left.and.right"
    }
}

/// A small switch: a pill with a knob that slides on a spring.
struct MiniSwitch: View {
    let on: Bool
    let set: (Bool) -> Void
    var body: some View {
        Button { set(!on) } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Pal.accent.opacity(0.85) : Pal.groove).frame(width: 30, height: 17)
                    .overlay(Capsule().stroke(on ? Pal.accent : Pal.hairline, lineWidth: 1))
                Circle().fill(on ? Pal.canvas : Pal.text3).frame(width: 11, height: 11).padding(.horizontal, 3)
            }.animation(.spring(duration: 0.25, bounce: 0.15), value: on).frame(width: 34, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// The last minute of throughput: download filled in the accent, upload a hairline, the axis scaled to the busiest second in the window.
struct RateChart: View {
    let hist: [RateSample]
    @Binding var hover: Int?

    private func niceMax(_ v: Double) -> Double {
        let steps: [Double] = [10e3, 25e3, 50e3, 100e3, 250e3, 500e3, 1e6, 2.5e6, 5e6, 10e6, 25e6, 50e6, 100e6, 250e6, 500e6, 1e9]
        return steps.first { $0 >= v } ?? v
    }

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                let L: CGFloat = 40, R = size.width - 3, T: CGFloat = 4, B = size.height - 14, win = 60.0
                guard R > L else { return }
                let now = hist.last?.t ?? Date().timeIntervalSince1970
                let peak = niceMax(max(hist.map { max($0.rx, $0.tx) }.max() ?? 0, 5e3))
                let x = { (t: TimeInterval) in R - CGFloat((now - t) / win) * (R - L) }
                let y = { (v: Double) in T + CGFloat(1 - min(1, max(0, v) / peak)) * (B - T) }
                func label(_ s: String, _ p: CGPoint, _ a: UnitPoint) { ctx.draw(Text(s).font(Pal.font(7.5)).foregroundStyle(Pal.text4), at: p, anchor: a) }
                for m in [1.0, 0.5, 0.0] {
                    let yy = (T + CGFloat(1 - m) * (B - T)).rounded() + 0.5
                    ctx.stroke(Path { $0.move(to: CGPoint(x: L, y: yy)); $0.addLine(to: CGPoint(x: R, y: yy)) }, with: .color(Pal.accent.opacity(m == 0 ? 0.20 : 0.07)), lineWidth: 1)
                    label(m == 0 ? "0" : NetworkCard.rateText(peak * m).replacingOccurrences(of: "/S", with: ""), CGPoint(x: L - 5, y: yy), .trailing)
                }
                for (s, secs, a) in [("NOW", 0.0, UnitPoint.topTrailing), ("-30S", 30, .top), ("-60S", 60, .topLeading)] {
                    let xx = (R - CGFloat(secs / win) * (R - L)).rounded() + 0.5
                    ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: T)); $0.addLine(to: CGPoint(x: xx, y: B)) }, with: .color(Pal.accent.opacity(0.06)), lineWidth: 1)
                    label(s, CGPoint(x: xx, y: B + 3), a)
                }
                ctx.clipToLayer { $0.fill(Path(CGRect(x: L, y: 0, width: R - L + 2, height: size.height)), with: .color(.black)) }
                guard hist.count > 1 else { return }
                var area = Path(), line = Path(), up = Path()
                area.move(to: CGPoint(x: x(hist[0].t), y: B))
                for (i, h) in hist.enumerated() {
                    let p = CGPoint(x: x(h.t), y: y(h.rx)), u = CGPoint(x: x(h.t), y: y(h.tx))
                    area.addLine(to: p); if i == 0 { line.move(to: p); up.move(to: u) } else { line.addLine(to: p); up.addLine(to: u) }
                }
                area.addLine(to: CGPoint(x: x(hist.last!.t), y: B)); area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [Pal.accent.opacity(0.32), Pal.accent.opacity(0.02)]), startPoint: CGPoint(x: 0, y: T), endPoint: CGPoint(x: 0, y: B)))
                ctx.stroke(up, with: .color(Pal.text1.opacity(0.55)), lineWidth: 1)
                ctx.stroke(line, with: .color(Pal.accent), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                if let l = hist.last { ctx.fill(Path(ellipseIn: CGRect(x: x(l.t) - 2.5, y: y(l.rx) - 2.5, width: 5, height: 5)), with: .color(Pal.accent)) }
                if let i = hover, i < hist.count {
                    let xx = x(hist[i].t).rounded() + 0.5
                    ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: T)); $0.addLine(to: CGPoint(x: xx, y: B)) }, with: .color(Pal.text1.opacity(0.35)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: xx - 2.5, y: y(hist[i].rx) - 2.5, width: 5, height: 5)), with: .color(Pal.accent))
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let L: CGFloat = 40, R = g.size.width - 3, now = hist.last?.t ?? 0
                    let t = now - Double((R - p.x) / (R - L)) * 60
                    hover = hist.indices.min { abs(hist[$0].t - t) < abs(hist[$1].t - t) }
                case .ended: hover = nil
                }
            }
        }
    }
}

/// The air around you: every network as a hump on its channel (width = channel width, height = signal), 2.4 GHz on the left and 5 GHz on
/// the right, yours in the accent. Crowded channels show as overlapping humps.
struct ChannelMap: View {
    let nearby: [NearbyNet]
    let channel: Int, band: Int
    let hover: String?

    var body: some View {
        Canvas { ctx, size in
            let B = size.height - 13, T: CGFloat = 3, split = size.width * 0.38
            func pos(_ n: (ch: Int, band: Int)) -> CGFloat {
                if n.band == 1 { return 18 + (split - 36) * CGFloat(n.ch - 1) / 12.0 }
                let u = CGFloat(n.ch - 36) / 4.0                         // 20 MHz steps from channel 36
                return split + 8 + (size.width - split - 16) * u / 33.0
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: B + 0.5)); $0.addLine(to: CGPoint(x: size.width, y: B + 0.5)) }, with: .color(Pal.hairline), lineWidth: 1)
            ctx.stroke(Path { $0.move(to: CGPoint(x: split, y: T)); $0.addLine(to: CGPoint(x: split, y: B)) }, with: .color(Pal.hairline), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            func tick(_ s: String, _ x: CGFloat) { ctx.draw(Text(s).font(Pal.font(7.5)).foregroundStyle(Pal.text4), at: CGPoint(x: x, y: B + 3), anchor: .top) }
            for c in [1, 6, 11] { tick("\(c)", pos((c, 1))) }
            for c in [36, 52, 100, 149] { tick("\(c)", pos((c, 2))) }
            ctx.draw(Text("2.4 GHZ").font(Pal.font(7.5, .bold)).foregroundStyle(Pal.amberDim), at: CGPoint(x: 4, y: T), anchor: .topLeading)
            ctx.draw(Text("5 GHZ").font(Pal.font(7.5, .bold)).foregroundStyle(Pal.amberDim), at: CGPoint(x: split + 6, y: T), anchor: .topLeading)
            for w in nearby.sorted(by: { $0.rssi < $1.rssi }) where w.band == 1 || w.band == 2 {
                let cx = pos((w.channel, w.band))
                let half: CGFloat = w.band == 1 ? (split - 36) / 12.0 * 2.0 : (size.width - split - 16) / 33.0 * CGFloat(w.width) / 40.0
                let h = (B - T - 8) * CGFloat(max(0.06, min(1, Double(2 * (w.rssi + 100)) / 100)))
                var p = Path()
                p.move(to: CGPoint(x: cx - half, y: B))
                p.addCurve(to: CGPoint(x: cx, y: B - h), control1: CGPoint(x: cx - half * 0.55, y: B), control2: CGPoint(x: cx - half * 0.45, y: B - h))
                p.addCurve(to: CGPoint(x: cx + half, y: B), control1: CGPoint(x: cx + half * 0.45, y: B - h), control2: CGPoint(x: cx + half * 0.55, y: B))
                let cur = w.current, hot = hover == w.id
                ctx.fill(p, with: .color(cur ? Pal.accent.opacity(0.30) : hot ? Pal.text1.opacity(0.25) : Pal.text3.opacity(0.10)))
                ctx.stroke(p, with: .color(cur ? Pal.accent : hot ? Pal.text1 : Pal.text3.opacity(0.55)), lineWidth: cur || hot ? 1.5 : 1)
            }
        }
    }
}
