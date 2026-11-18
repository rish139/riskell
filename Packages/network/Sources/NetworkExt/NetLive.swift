// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Foundation
import CoreWLAN
import IOBluetooth
import SystemConfiguration
import Darwin
import RiskellKit

struct RateSample: Equatable { let t: TimeInterval; let rx: Double; let tx: Double }
struct NearbyNet: Identifiable, Equatable {
    let id: String
    let ssid: String?
    let rssi: Int
    let channel: Int
    let band: Int          // 1 = 2.4 GHz, 2 = 5 GHz, 3 = 6 GHz
    let width: Int         // MHz
    let secure: Bool
    var current = false
}
struct BtDevice: Identifiable, Equatable { let id: String; let name: String; var connected: Bool }
struct VpnItem: Identifiable, Equatable { let id: String; let name: String; let state: String; var on: Bool { state == "Connected" || state == "Connecting" } }

/// Everything the network card shows beyond the atom: live throughput, latency, link details, nearby networks, Bluetooth devices and
/// tunnels. All of it is read ONLY while the card is open (start/stop), and the slow or invasive reads (a Wi-Fi scan, the VPN list)
/// only while their tab is the one on show.
final class NetLive: ObservableObject {
    static let shared = NetLive()

    enum Tab: Int, CaseIterable { case wifi, bt, eth, vpn }
    @Published var tab = NetLive.initialTab()
    /// `riskell --pop net:<n>` (a snapshot test) opens the card on its n-th tab.
    private static func initialTab() -> Tab {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--pop"), i + 1 < a.count {
            let p = a[i + 1].split(separator: ":")
            if p.first == "net", p.count > 1, let n = Int(p[1]) { return Tab(rawValue: n - 1) ?? .wifi }
        }
        return .wifi
    }

    // throughput
    private(set) var rx = 0.0
    private(set) var tx = 0.0
    private(set) var hist: [RateSample] = []
    private(set) var totalRx = 0.0
    private(set) var totalTx = 0.0
    // addressing
    private(set) var localIP = ""
    private(set) var gateway = ""
    private(set) var dns: [String] = []
    // latency to the gateway
    private(set) var latency: Double? = nil
    private(set) var jitter = 0.0
    private(set) var loss = 0
    // wi-fi
    private(set) var wifiOn = CWWiFiClient.shared().interface()?.powerOn() ?? false
    private(set) var rssi = 0
    private(set) var noise = 0
    private(set) var txRate = 0.0
    private(set) var channel = 0
    private(set) var band = 0
    private(set) var width = 0
    private(set) var security = ""
    private(set) var phy = ""
    private(set) var nearby: [NearbyNet] = []
    private(set) var scanning = false
    // bluetooth
    private(set) var bt: [BtDevice] = []
    private(set) var btOn = false
    private(set) var btBusy: String? = nil
    // ethernet
    private(set) var ethName: String? = nil
    private(set) var ethIP = ""
    private(set) var ethMAC = ""
    // tunnels
    private(set) var vpn: [VpnItem] = []
    private(set) var vpnBusy: String? = nil

    private var stopTick: (() -> Void)?
    private var users = 0
    private var prevCounters: (rx: UInt64, tx: UInt64, at: TimeInterval)?
    private var tick = 0
    private let queue = DispatchQueue(label: "riskell.net", qos: .utility)
    private var pinging = false, scanningNow = false
    private var pings: [Double?] = []
    private var scanAt = Date.distantPast

    func start() {
        users += 1
        guard stopTick == nil, let env = NetEnv.env else { return }
        prevCounters = nil; tick = 0
        if Demo.on && hist.isEmpty {      // screenshots: a minute of plausible traffic, so the graph is not empty
            let now = Date().timeIntervalSince1970
            hist = (0..<60).map { i in RateSample(t: now - Double(60 - i), rx: Demo.rxAt(i), tx: Demo.txAt(i)) }
        }
        // the kit's repeating schedule fires at once and then every second: the first sample is taken as the card opens
        stopTick = env.repeating(.seconds(1)) { [weak self] in self?.step() }
    }
    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        stopTick?(); stopTick = nil
    }

    func select(_ t: Tab) { tab = t; refreshTab(force: true) }

    /// One publish per update: every assignment above would otherwise redraw the whole card by itself.
    private func pub() { objectWillChange.send() }

    private func step() {
        tick += 1
        let now = Date().timeIntervalSince1970
        readCounters(now)
        readAddressing()
        readWifi()
        if tick % 2 == 1 { ping() }
        refreshTab(force: false)
        pub()
    }

    private func refreshTab(force: Bool) {
        switch tab {
        case .wifi: if force ? Date().timeIntervalSince(scanAt) > 3 : Date().timeIntervalSince(scanAt) > 12 { scan() }
        case .bt: if force || tick % 3 == 1 { readBluetooth() }
        case .eth: readEthernet()
        case .vpn: if force || tick % 4 == 1 { readVpn() }
        }
    }

    // MARK: throughput (64-bit interface counters from the kernel's own table)

    private func interfaceCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
        var out: [String: (UInt64, UInt64)] = [:]
        var off = 0
        while off + MemoryLayout<if_msghdr>.size <= len {
            let hdr = buf.withUnsafeBytes { $0.load(fromByteOffset: off, as: if_msghdr.self) }
            let msgLen = Int(hdr.ifm_msglen); if msgLen <= 0 { break }
            if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                let m = buf.withUnsafeBytes { $0.load(fromByteOffset: off, as: if_msghdr2.self) }
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(m.ifm_index), &name) != nil { out[String(cString: name)] = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes) }
            }
            off += msgLen
        }
        return out
    }

    private func readCounters(_ now: TimeInterval) {
        if Demo.on {      // screenshots: the live figures follow the made-up history, so the numbers and the graph agree
            rx = Demo.rxAt(60 + tick); tx = Demo.txAt(60 + tick)
            hist.append(RateSample(t: now, rx: rx, tx: tx)); trim(now)
            return
        }
        guard let p = NetState.shared.wifi.primary, let c = interfaceCounters()[p] else {
            rx = 0; tx = 0
            hist.append(RateSample(t: now, rx: 0, tx: 0)); trim(now)
            return
        }
        totalRx = Double(c.rx); totalTx = Double(c.tx)
        if let prev = prevCounters, now > prev.at, c.rx >= prev.rx, c.tx >= prev.tx {
            rx = Double(c.rx - prev.rx) / (now - prev.at); tx = Double(c.tx - prev.tx) / (now - prev.at)
            hist.append(RateSample(t: now, rx: rx, tx: tx)); trim(now)
        }
        prevCounters = (c.rx, c.tx, now)
    }
    private func trim(_ now: TimeInterval) { hist.removeAll { $0.t < now - 75 } }

    // MARK: addressing

    private func readAddressing() {
        if let d = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            let r = Demo.address(d["Router"] as? String ?? "", "192.168.1.1")
            if r != gateway { gateway = r }
        } else if !gateway.isEmpty { gateway = "" }
        if let d = SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString) as? [String: Any], let a = d["ServerAddresses"] as? [String] {
            let a = Demo.on ? ["192.168.1.1"] : a
            if a != dns { dns = a }
        } else if !dns.isEmpty { dns = [] }
        let ip = Demo.address(NetState.shared.wifi.primary.flatMap { Self.ipv4($0) } ?? "", "192.168.1.20")
        if ip != localIP { localIP = ip }
    }

    static func ipv4(_ iface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p {
            if String(cString: a.pointee.ifa_name) == iface, let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
            }
            p = a.pointee.ifa_next
        }
        return nil
    }

    // MARK: latency (an unprivileged ICMP echo to the gateway)

    private func ping() {
        let host = gateway
        guard !host.isEmpty, !pinging else { if host.isEmpty { latency = nil }; return }
        pinging = true
        queue.async { [weak self] in
            let r = Self.icmpEcho(host, timeout: 0.8)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pinging = false
                self.pings.append(r); if self.pings.count > 20 { self.pings.removeFirst() }
                let ok = self.pings.compactMap { $0 }
                self.latency = r ?? ok.last
                self.loss = self.pings.isEmpty ? 0 : Int((Double(self.pings.count - ok.count) / Double(self.pings.count) * 100).rounded())
                if ok.count > 1 { let m = ok.reduce(0, +) / Double(ok.count); self.jitter = (ok.map { abs($0 - m) }.reduce(0, +) / Double(ok.count)) } else { self.jitter = 0 }
                self.pub()
            }
        }
    }

    private static func icmpEcho(_ host: String, timeout: Double) -> Double? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: Int32(timeout * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        var pkt = [UInt8](repeating: 0, count: 40)
        pkt[0] = 8; pkt[4] = UInt8.random(in: 0...255); pkt[5] = UInt8.random(in: 0...255); pkt[7] = 1
        var sum: UInt32 = 0
        for i in stride(from: 0, to: pkt.count, by: 2) { sum += UInt32(pkt[i]) << 8 | UInt32(pkt[i + 1]) }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        let ck = ~UInt16(truncatingIfNeeded: sum); pkt[2] = UInt8(ck >> 8); pkt[3] = UInt8(ck & 0xff)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let sent = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pkt, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard sent > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return nil }
            let off = buf[0] >> 4 == 4 ? Int(buf[0] & 0x0f) * 4 : 0       // the reply may carry its IP header
            if n > off, buf[off] == 0 { return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
            if Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 > timeout { return nil }
        }
    }

    // MARK: wi-fi

    private func readWifi() {
        guard let i = CWWiFiClient.shared().interface() else { return }
        let on = i.powerOn()
        if on != wifiOn { wifiOn = on }
        guard on else { rssi = 0; return }
        rssi = i.rssiValue(); noise = i.noiseMeasurement(); txRate = i.transmitRate()
        let ch = i.wlanChannel()
        channel = ch?.channelNumber ?? 0; band = ch?.channelBand.rawValue ?? 0
        width = [1: 20, 2: 40, 3: 80, 4: 160][ch?.channelWidth.rawValue ?? 0] ?? 0
        security = Self.securityName(i.security()); phy = Self.phyName(i.activePHYMode())
    }

    func setWifi(_ on: Bool) {
        try? CWWiFiClient.shared().interface()?.setPower(on)
        readWifi()
        if !on { nearby = [] }
        pub()
    }

    private func scan() {
        if Demo.on {      // screenshots: a made-up neighbourhood, so the channel plot and the list are full at once
            let spec: [(band: Int, channel: Int, rssi: Int, width: Int)] = [(1, 1, -52, 20), (1, 1, -66, 20), (1, 6, -61, 20), (1, 6, -74, 20), (1, 11, -70, 20),
                                                                           (1, 11, -78, 20), (2, 36, -64, 80), (2, 52, -72, 40), (2, 100, -76, 80), (2, 149, -80, 80)]
            var l: [NearbyNet] = []
            for (k, s) in spec.enumerated() { l.append(NearbyNet(id: "demo-\(k)", ssid: nil, rssi: s.rssi, channel: s.channel, band: s.band, width: s.width, secure: true)) }
            l[0].current = true
            nearby = l; scanning = false; pub()
            return
        }
        guard wifiOn, !scanningNow, let i = CWWiFiClient.shared().interface() else { return }
        scanningNow = true; scanning = true; scanAt = Date()
        queue.async { [weak self] in
            let found = (try? i.scanForNetworks(withSSID: nil)) ?? []
            let list = found.map { n in
                NearbyNet(id: n.bssid ?? "\(n.wlanChannel?.channelNumber ?? 0)-\(n.rssiValue)-\(n.ssid ?? "")-\(n.beaconInterval)-\(n.countryCode ?? "")",
                          ssid: n.ssid, rssi: n.rssiValue, channel: n.wlanChannel?.channelNumber ?? 0, band: n.wlanChannel?.channelBand.rawValue ?? 0,
                          width: [1: 20, 2: 40, 3: 80, 4: 160][n.wlanChannel?.channelWidth.rawValue ?? 0] ?? 20, secure: !n.supportsSecurity(.none))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanningNow = false; self.scanning = false
                var l = list.sorted { $0.rssi > $1.rssi }
                // our own access point: same channel, closest signal (the name is hidden, so this is the best identification there is)
                if let k = l.indices.filter({ l[$0].channel == self.channel }).min(by: { abs(l[$0].rssi - self.rssi) < abs(l[$1].rssi - self.rssi) }), abs(l[k].rssi - self.rssi) <= 6 { l[k].current = true }
                if l != self.nearby { self.nearby = l }
                self.pub()
            }
        }
    }

    static func securityName(_ s: CWSecurity) -> String {
        switch s.rawValue {
        case 0: return "OPEN"
        case 1, 6: return "WEP"
        case 2, 3: return "WPA"
        case 4, 5: return "WPA2"
        case 7, 8: return "WPA ENT"
        case 9, 10: return "WPA2 ENT"
        case 11, 13: return "WPA3"
        case 12: return "WPA3 ENT"
        case 14: return "OWE"
        default: return "—"
        }
    }
    static func phyName(_ m: CWPHYMode) -> String {
        switch m.rawValue { case 7: return "WI-FI 7"; case 6: return "WI-FI 6"; case 5: return "WI-FI 5"; case 4: return "WI-FI 4"; case 3: return "802.11G"; case 2: return "802.11B"; case 1: return "802.11A"; default: return "—" }
    }

    // MARK: bluetooth

    private func readBluetooth() {
        let devs = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let list = devs.map { BtDevice(id: $0.addressString ?? $0.name ?? UUID().uuidString, name: $0.name ?? "Unknown", connected: $0.isConnected()) }
            .sorted { $0.connected != $1.connected ? $0.connected : $0.name.lowercased() < $1.name.lowercased() }
        if list != bt { bt = list }
        let on = IOBluetoothHostController.default()?.powerState.rawValue == 1
        if on != btOn { btOn = on }
        pub()
    }

    func toggleBluetooth(_ d: BtDevice) {
        guard btBusy == nil, let dev = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: { $0.addressString == d.id }) else { return }
        btBusy = d.id; pub()
        queue.async { [weak self] in
            _ = d.connected ? dev.closeConnection() : dev.openConnection()
            DispatchQueue.main.async { self?.btBusy = nil; self?.readBluetooth() }
        }
    }

    /// The controller's power switch is a private IOBluetooth call (blueutil uses it too): looked up at run time, a no-op if it ever goes.
    func setBluetoothPower(_ on: Bool) {
        typealias F = @convention(c) (Int32) -> Void
        if let h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY), let s = dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") {
            unsafeBitCast(s, to: F.self)(on ? 1 : 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.readBluetooth() }
    }

    // MARK: ethernet

    private func readEthernet() {
        let wifiIf = CWWiFiClient.shared().interface()?.interfaceName
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return }
        defer { freeifaddrs(head) }
        var found: (String, String, String)? = nil
        var p = head
        var macs: [String: String] = [:]
        while let a = p {
            let name = String(cString: a.pointee.ifa_name)
            if let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) {
                let sdl = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_dl.self)
                if sdl.pointee.sdl_alen == 6 {
                    let base = UnsafeRawPointer(sdl).advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + Int(sdl.pointee.sdl_nlen))
                    macs[name] = (0..<6).map { String(format: "%02X", base.load(fromByteOffset: $0, as: UInt8.self)) }.joined(separator: ":")
                }
            }
            p = a.pointee.ifa_next
        }
        for name in macs.keys.sorted() where name.hasPrefix("en") && name != wifiIf {
            if let ip = Self.ipv4(name), !ip.hasPrefix("169.254") { found = (name, ip, macs[name] ?? ""); break }
        }
        let n = found?.0
        if n != ethName { ethName = n }
        if (found?.1 ?? "") != ethIP { ethIP = found?.1 ?? "" }
        if (found?.2 ?? "") != ethMAC { ethMAC = found?.2 ?? "" }
        pub()
    }
    var ethPresent: Bool { ethName != nil }

    // MARK: tunnels

    private func readVpn() {
        queue.async { [weak self] in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil"); p.arguments = ["--nc", "list"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            let re = try? NSRegularExpression(pattern: #"\((Connected|Disconnected|Connecting|Disconnecting|Invalid)\)\s+(\S+).*?"([^"]*)""#)
            let items: [VpnItem] = out.split(separator: "\n").compactMap { line in
                let l = String(line)
                guard let m = re?.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let s = Range(m.range(at: 1), in: l), let id = Range(m.range(at: 2), in: l), let n = Range(m.range(at: 3), in: l) else { return nil }
                return VpnItem(id: String(l[id]), name: String(l[n]), state: String(l[s]))
            }
            DispatchQueue.main.async { if items != self?.vpn { self?.vpn = items }; self?.pub() }
        }
    }

    func toggleVpn(_ v: VpnItem) {
        guard vpnBusy == nil else { return }
        vpnBusy = v.id; pub()
        queue.async { [weak self] in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
            p.arguments = ["--nc", v.on ? "stop" : "start", v.name]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.vpnBusy = nil; self?.readVpn(); self?.pub() }
        }
    }
}
