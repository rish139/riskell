// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import CoreAudio
import RiskellKit

/// VOLUME / MIXER. The master level (a numeral, a mute key, a fader with the live L/R level under it) beside the last minute of what
/// actually came out of the speakers, three readings from that minute (peak, average peak, balance), the apps making sound right now
/// (each with its own mute), the output devices (one click makes one the default) and the microphone with its own fader and mute.
/// Levels come from a system-audio tap that exists only while this card is open.
struct VolumeCard: View {
    @ObservedObject private var s = VolumeState.shared
    @ObservedObject private var m = Mixer.shared
    @State private var hover: Int? = nil
    @State private var hoverRow: String? = nil
    @State private var linkHot: String? = nil

    static let pad: CGFloat = 16, width: CGFloat = 404

    static var size: CGSize {
        let mx = Mixer.shared
        let streams = max(1, mx.streams.count), outs = max(1, mx.outs.count), others = max(0, mx.ins.count - 1)
        return CGSize(width: width, height: 402 + CGFloat(streams) * 40 + CGFloat(outs) * 30 + CGFloat(others) * 28)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Rectangle().fill(Pal.amberGhost).frame(height: 1)
            hero
            rail
            streams
            outputs
            inputs
            footer
        }
        .padding(.horizontal, Self.pad).padding(.top, 14).padding(.bottom, 10)
        .frame(width: Self.width, alignment: .topLeading)
        .background { if !m.meterable { MeterClock() } }      // with a tap the audio callback steps the meter; the clock is the fallback
        .onAppear { Mixer.shared.start() }
        .onDisappear { Mixer.shared.stop() }
        .onChange(of: m.streams.count) { _, _ in PopState.shared.refit() }
        .onChange(of: m.outs.count) { _, _ in PopState.shared.refit() }
        .onChange(of: m.ins.count) { _, _ in PopState.shared.refit() }
    }

    private func t(_ s: String, _ size: CGFloat, _ color: Color, bold: Bool = true, _ ls: CGFloat = 1.2) -> some View {
        Text(s).font(Pal.font(size, bold ? .bold : .regular)).tracking(ls).foregroundStyle(color)
    }

    private var live: Bool { m.meterable && max(m.levelL, m.levelR) > 0.03 && !s.muted }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            t("VOLUME", 10, Pal.amberDim, 2.6)
            Text("MIXER").font(Pal.font(15, .bold)).foregroundStyle(Pal.text1)
            Spacer()
            Circle().fill(live ? Pal.accent : .clear).overlay(Circle().stroke(live ? Color.clear : Pal.text4, lineWidth: 1)).frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }.frame(height: 20)
    }

    // MARK: hero

    private var hero: some View {
        let h = m.hist
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Button { Volume.toggleMute() } label: {
                        Image(systemName: s.muted ? "speaker.slash.fill" : s.volume < 34 ? "speaker.wave.1.fill" : s.volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                            .font(Pal.font(14, .semibold)).foregroundStyle(s.muted ? Pal.text4 : Pal.accent).frame(width: 22, height: 22).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    t("MASTER", 10, Pal.amberDim, 2.6)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(s.volume)").font(Pal.font(27, .bold)).foregroundStyle(s.muted ? Pal.text4 : Pal.text1)
                    Text("%").font(Pal.font(11, .bold)).foregroundStyle(s.muted ? Pal.text4 : Pal.text3)
                }
                HairFader(value: Double(s.volume), muted: s.muted, l: m.levelL, r: m.levelR) { Volume.set(Int($0.rounded())) }
                    .frame(height: 24).padding(.top, 6)
            }.frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                let sel = hover.flatMap { $0 < h.count && !h[$0].db.isNaN ? h[$0] : nil }
                t(sel.map { "-\(Int(Date().timeIntervalSince1970 - $0.t))S  PEAK \(Self.fmtDb($0.db)) DB  VOL \(Int($0.vol))%" } ?? "LISTENING · 60 S",
                  10, sel == nil ? Pal.amberDim : Pal.accent, 1.2).lineLimit(1)
                LoudnessChart(hist: h, hover: $hover).frame(height: 78)
                if !m.meterable { t("NO SIGNAL · ALLOW SYSTEM AUDIO RECORDING IN PRIVACY SETTINGS", 7, Pal.text4, bold: false, 0.4).lineLimit(1).minimumScaleFactor(0.8) }
            }
        }.frame(height: 112)
    }

    // MARK: rail

    private var rail: some View {
        let now = Date().timeIntervalSince1970
        let vals = m.hist.filter { $0.t > now - 60 && !$0.db.isNaN && $0.db > -47 }
        let cur = m.hist.last.flatMap { !$0.db.isNaN && $0.db > -47 ? $0.db : nil }
        let mx = vals.map(\.db).max()
        let avg = vals.isEmpty ? nil : 10 * log10(vals.map { pow(10, $0.db / 10) }.reduce(0, +) / Double(vals.count))
        let bOK = m.dbL > -47 && m.dbR > -47, bd = m.dbL - m.dbR
        let cells: [(String, String, String)] = [
            ("PEAK", cur.map { Self.fmtDb($0) + " dB" } ?? "—", mx.map { "60S MAX " + Self.fmtDb($0) } ?? "SILENT"),
            ("AVG PEAK", avg.map { Self.fmtDb($0) + " dB" } ?? "—", avg == nil ? "NO SIGNAL" : "LAST 60 S"),
            ("BALANCE", bOK ? Self.fmtDb(bd) + " dB" : "—", !bOK ? " " : abs(bd) < 1.5 ? "CENTRED" : bd > 0 ? "LEFT HEAVY" : "RIGHT HEAVY"),
        ]
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                VStack(alignment: .leading, spacing: 2) {
                    t(c.0, 9, Pal.amberDim, 1.2)
                    Text(c.1).font(Pal.font(15, .bold)).foregroundStyle(Pal.text1).lineLimit(1)
                    t(c.2, 8, Pal.text4, bold: false, 0.6).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, i == 0 ? 0 : 12)
                if i < cells.count - 1 { Rectangle().fill(Pal.hairline).frame(width: 1, height: 38) }
            }
        }.frame(height: 48)
    }

    // MARK: sections

    private func secHead(_ title: String, _ readout: String = "") -> some View {
        HStack(spacing: 8) {
            t(title, 10, Pal.amberDim, 2.6)
            Rectangle().fill(Pal.amberGhost).frame(height: 1)
            if !readout.isEmpty { t(readout, 9, Pal.text4, bold: false, 1) }
        }.frame(height: 20)
    }

    private var streams: some View {
        VStack(alignment: .leading, spacing: 0) {
            secHead("STREAMS", m.streams.isEmpty ? "" : "\(m.streams.count) PLAYING")
            if m.streams.isEmpty {
                t("NO ACTIVE STREAMS", 9, Pal.text4, 2.6).frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            }
            ForEach(m.streams) { st in
                let hov = hoverRow == "s\(st.id)"
                HStack(spacing: 9) {
                    Group {
                        if let i = m.icon(st) { Image(nsImage: i).resizable().interpolation(.high) } else { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Pal.accent) }
                    }.frame(width: 20, height: 20)
                    t(st.name.uppercased(), 9, Pal.text1, 0.8).lineLimit(1).frame(width: 70, alignment: .leading)
                    HairFader(value: st.gain * 100, muted: st.muted, l: st.level, r: st.level) { Mixer.shared.setGain(st, $0 / 100) }
                        .frame(height: 24)
                    t(st.muted ? "MUTED" : "\(Int((st.gain * 100).rounded()))%", 9, st.muted ? Pal.text4 : st.gain < 1 ? Pal.accent : Pal.text3, 0.6).frame(width: 42, alignment: .trailing)
                    Button { Mixer.shared.toggleMute(st) } label: {
                        Image(systemName: st.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(Pal.font(12)).foregroundStyle(st.muted ? Pal.text4 : hov ? Pal.text1 : Pal.amberDim)
                            .frame(width: 24, height: 26).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .opacity(st.muted ? 0.55 : 1).padding(.horizontal, 6).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 6).fill(hov ? Pal.hoverFill : .clear))
                .onHover { h in hoverRow = h ? "s\(st.id)" : (hoverRow == "s\(st.id)" ? nil : hoverRow) }
            }
        }
    }

    private var outputs: some View {
        VStack(alignment: .leading, spacing: 0) {
            secHead("OUTPUT")
            if m.outs.isEmpty { t("NO OUTPUT DEVICES", 9, Pal.text4, 2.6).frame(maxWidth: .infinity, minHeight: 30) }
            ForEach(m.outs) { d in deviceRow(d, isDefault: d.id == m.defOut, input: false) }
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 0) {
            secHead("INPUT")
            let dflt = m.ins.first { $0.id == m.defIn }
            VStack(spacing: 2) {
                HStack(spacing: 9) {
                    Button { Volume.toggleMicMute() } label: {
                        Image(systemName: s.micMuted ? "mic.slash.fill" : "mic.fill").font(Pal.font(14, .semibold))
                            .foregroundStyle(s.micMuted ? Pal.text4 : Pal.info).frame(width: 22, height: 22).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Text(dflt?.name ?? "No microphone").font(Pal.font(12)).foregroundStyle(dflt == nil ? Pal.text4 : Pal.text1).lineLimit(1)
                    Spacer(minLength: 0)
                    if s.mic >= 0 { t("\(s.mic)%", 10, Pal.info, 0.6) }
                }
                if s.mic >= 0 { HairFader(value: Double(s.mic), muted: s.micMuted, l: 0, r: 0, tone: Pal.info) { Volume.setMic(Int($0.rounded())) }.frame(height: 20) }
            }.opacity(s.micMuted ? 0.55 : 1).padding(.horizontal, 6).padding(.vertical, 4)
            ForEach(m.ins.filter { $0.id != m.defIn }) { d in deviceRow(d, isDefault: false, input: true) }
        }
    }

    private func deviceRow(_ d: AudioHW.Device, isDefault: Bool, input: Bool) -> some View {
        let hov = hoverRow == "d\(d.id)"
        return HStack(spacing: 10) {
            Image(systemName: Self.deviceIcon(d, input: input)).font(Pal.font(13)).foregroundStyle(isDefault ? Pal.accent : Pal.text4).frame(width: 20)
            Text(d.name).font(Pal.font(12, isDefault ? .bold : .regular)).foregroundStyle(isDefault ? Pal.text1 : Pal.text3).lineLimit(1)
            Spacer(minLength: 0)
            if hov && !isDefault { t("USE", 9, Pal.accent, 1.4) }
            else if isDefault { t("DEFAULT", 8.5, Pal.accent, 1.2) }
        }
        .padding(.horizontal, 6).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(isDefault ? Pal.selected : hov ? Pal.hoverFill : .clear))
        .overlay(alignment: .leading) { if isDefault { Capsule().fill(Pal.accent).frame(width: 2, height: 16) } }
        .contentShape(Rectangle())
        .onHover { h in hoverRow = h ? "d\(d.id)" : (hoverRow == "d\(d.id)" ? nil : hoverRow) }
        .onTapGesture { if input { Mixer.shared.setInput(d) } else { Mixer.shared.setOutput(d) } }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Spacer()
            link("AUDIO MIDI SETUP ↗") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")) }
            link("SOUND SETTINGS ↗") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
        }.frame(height: 18).animation(.easeOut(duration: 0.15), value: linkHot)
    }
    private func link(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button { action(); PopState.shared.close() } label: {
            t(label, 9, linkHot == label ? Pal.accent : Pal.amberDim, 1.4).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { linkHot = $0 ? label : (linkHot == label ? nil : linkHot) }
    }

    // MARK: formatting

    static func fmtDb(_ d: Double) -> String { (d < 0 ? "−" : d > 0 ? "+" : "") + String(format: "%.1f", abs(d)) }
    static func deviceIcon(_ d: AudioHW.Device, input: Bool) -> String {
        let n = d.name.lowercased()
        if n.contains("airpods") || n.contains("headphone") || n.contains("buds") || n.contains("pods") { return "headphones" }
        if input { return n.contains("macbook") || d.transport == kAudioDeviceTransportTypeBuiltIn ? "mic.fill" : "mic" }
        switch d.transport {
        case kAudioDeviceTransportTypeBuiltIn: return n.contains("speaker") ? "laptopcomputer" : "hifispeaker.fill"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        default: return "speaker.wave.2.fill"
        }
    }
}

/// A hairline fader: a 1.5 px groove with decade ticks, an accent fill, a handle that grows while held, and (optionally) the live left and
/// right level as two quiet lines under it. Drag anywhere on it to set the value.
struct HairFader: View {
    let value: Double, muted: Bool, l: Double, r: Double
    var tone: Color = Pal.accent
    let set: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, f = max(0, min(1, value / 100)), cy = g.size.height * 0.42
            ZStack(alignment: .topLeading) {
                ForEach(0...10, id: \.self) { i in
                    Rectangle().fill(Pal.text4.opacity(i % 5 == 0 ? 0.5 : 0.25)).frame(width: 1, height: i % 5 == 0 ? 7 : 4)
                        .offset(x: (w * CGFloat(i) / 10).rounded(), y: cy - (i % 5 == 0 ? 3.5 : 2))
                }
                Capsule().fill(Pal.groove).frame(width: w, height: 1.8).offset(y: cy - 0.9)
                Capsule().fill(muted ? Pal.text4 : tone).frame(width: max(1.8, w * f), height: 1.8).offset(y: cy - 0.9)
                Circle().fill(muted ? Pal.text4 : tone).frame(width: dragging ? 12 : 9, height: dragging ? 12 : 9)
                    .offset(x: w * f - (dragging ? 6 : 4.5), y: cy - (dragging ? 6 : 4.5))
                if l > 0 || r > 0 {
                    Capsule().fill(Pal.info.opacity(0.7)).frame(width: w * CGFloat(min(1, l)), height: 1.4).offset(y: g.size.height - 6)
                    Capsule().fill(Pal.info.opacity(0.7)).frame(width: w * CGFloat(min(1, r)), height: 1.4).offset(y: g.size.height - 3)
                }
            }
            .frame(width: w, height: g.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragging = true; set(Double(max(0, min(1, v.location.x / w))) * 100) }
                .onEnded { _ in dragging = false })
            .animation(.spring(duration: 0.2, bounce: 0.15), value: dragging)
        }
    }
}

/// The last minute of output loudness: the loudest peak in each quarter second as a dB area (accent, 0 at the top), the volume setting as
/// a hairline step line, gaps (the card was closed) left empty, a crosshair on hover that the card reads as a caption.
struct LoudnessChart: View {
    let hist: [LoudSample]
    @Binding var hover: Int?

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                let L: CGFloat = 28, R = size.width - 3, T: CGFloat = 4, B = size.height - 14, win = 60.0
                guard R > L else { return }
                let now = hist.last?.t ?? Date().timeIntervalSince1970
                let x = { (t: TimeInterval) in R - CGFloat((now - t) / win) * (R - L) }
                let y = { (db: Double) in T + CGFloat(1 - (min(0, max(-50, db)) + 50) / 50) * (B - T) }
                func label(_ s: String, _ p: CGPoint, _ a: UnitPoint) { ctx.draw(Text(s).font(Pal.font(7.5)).foregroundStyle(Pal.text4), at: p, anchor: a) }
                for (m, s) in [(1.0, "0"), (0.5, "-25"), (0.0, "-50")] {
                    let yy = (T + CGFloat(1 - m) * (B - T)).rounded() + 0.5
                    ctx.stroke(Path { $0.move(to: CGPoint(x: L, y: yy)); $0.addLine(to: CGPoint(x: R, y: yy)) }, with: .color(Pal.accent.opacity(m == 0 ? 0.20 : 0.07)), lineWidth: 1)
                    label(s, CGPoint(x: L - 5, y: yy), .trailing)
                }
                for (s, secs, a) in [("NOW", 0.0, UnitPoint.topTrailing), ("-30S", 30, .top), ("-60S", 60, .topLeading)] {
                    let xx = (R - CGFloat(secs / win) * (R - L)).rounded() + 0.5
                    ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: T)); $0.addLine(to: CGPoint(x: xx, y: B)) }, with: .color(Pal.accent.opacity(0.06)), lineWidth: 1)
                    label(s, CGPoint(x: xx, y: B + 3), a)
                }
                ctx.clipToLayer { $0.fill(Path(CGRect(x: L, y: 0, width: R - L + 2, height: size.height)), with: .color(.black)) }
                var runs: [[LoudSample]] = [], cur: [LoudSample] = []
                for h in hist { if h.db.isNaN { if !cur.isEmpty { runs.append(cur); cur = [] } } else { cur.append(h) } }
                if !cur.isEmpty { runs.append(cur) }
                // the volume setting: a hairline against the same height (0 % = bottom, 100 % = top)
                var vol = Path(); var started = false
                for h in hist where !h.db.isNaN {
                    let p = CGPoint(x: x(h.t), y: T + CGFloat(1 - h.vol / 100) * (B - T))
                    if started { vol.addLine(to: p) } else { vol.move(to: p); started = true }
                }
                ctx.stroke(vol, with: .color(Pal.text1.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                for run in runs where run.count > 1 {
                    var area = Path(), line = Path()
                    area.move(to: CGPoint(x: x(run[0].t), y: B))
                    for (i, h) in run.enumerated() {
                        let p = CGPoint(x: x(h.t), y: y(h.db)); area.addLine(to: p)
                        if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                    }
                    area.addLine(to: CGPoint(x: x(run.last!.t), y: B)); area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(Gradient(colors: [Pal.accent.opacity(0.35), Pal.accent.opacity(0.02)]), startPoint: CGPoint(x: 0, y: T), endPoint: CGPoint(x: 0, y: B)))
                    ctx.stroke(line, with: .color(Pal.accent), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                }
                if let l = hist.last, !l.db.isNaN { ctx.fill(Path(ellipseIn: CGRect(x: x(l.t) - 2.5, y: y(l.db) - 2.5, width: 5, height: 5)), with: .color(Pal.accent)) }
                if let i = hover, i < hist.count, !hist[i].db.isNaN {
                    let xx = x(hist[i].t).rounded() + 0.5
                    ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: T)); $0.addLine(to: CGPoint(x: xx, y: B)) }, with: .color(Pal.text1.opacity(0.35)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: xx - 2.5, y: y(hist[i].db) - 2.5, width: 5, height: 5)), with: .color(Pal.accent))
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let L: CGFloat = 28, R = g.size.width - 3, now = hist.last?.t ?? 0
                    let t = now - Double((R - p.x) / (R - L)) * 60
                    hover = hist.indices.filter { !hist[$0].db.isNaN }.min { abs(hist[$0].t - t) < abs(hist[$1].t - t) }
                case .ended: hover = nil
                }
            }
        }
    }
}

/// The card's meter tick: a zero-size view that asks for a frame every 0.125 s while the card is on screen (the timeline stops when the card
/// is removed, so nothing runs with the card closed) and steps the mixer on each one.
struct MeterClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.125)) { ctx in
            Color.clear.frame(width: 0, height: 0)
                .onChange(of: ctx.date) { _, _ in Mixer.shared.step() }
        }
    }
}
