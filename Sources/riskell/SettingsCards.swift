import SwiftUI
import RiskellKit

/// A section of the layout editor's panel: a header row (a caps title, a one-line summary while it is folded, a chevron) over a rounded card.
/// The header toggles the body with a short animation. `open` is a binding, so whoever owns it can remember it (SettingsView keeps it in UserDefaults).
struct CollapsibleCard<Summary: View, Content: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder let summary: Summary
    @ViewBuilder let content: Content
    @State private var hot = false
    var body: some View {
        VStack(alignment: .leading, spacing: open ? 12 : 0) {
            HStack(spacing: 8) {
                Cap(text: title, hot: hot)
                Spacer(minLength: 8)
                if !open { summary.font(T.sub).foregroundStyle(Pal.text4).lineLimit(1) }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(hot ? Pal.text2 : Pal.text4)
                    .rotationEffect(.degrees(open ? 0 : -90))
            }
            .contentShape(Rectangle())
            .onHover { hot = $0 }
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } }
            if open { content.transition(.opacity) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)      // take the panel's width, however wide the content would like to be
        .background(RoundedRectangle(cornerRadius: 10).fill(Pal.hoverFill))
    }
}

/// The SPACING & SIZE card: scale (automatic or a value, applies on restart), the edge gap, the window gap, the island gap (layout.json) and the
/// corner roundness, with a Reset that puts them all back. The spacing writes go to config.json (Spacing.swift) and apply live.
struct SpacingCard: View {
    @ObservedObject private var cfg = Config.shared

    /// The folded card's one-line summary.
    static func summary() -> String {
        let s = Spacing.current, sc = AppConfig.shared.scale.map { String(format: "%.2f", $0) } ?? "auto"
        return "\(sc) · \(Int(s.edge)) · \(Int(s.window)) · \(Int(Config.shared.gap))"      // scale, edge, window, island: short enough for a folded card in either column mode
    }

    var body: some View {
        let s = Spacing.current, scale = AppConfig.shared.scale
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Scale").font(Pal.font(12, .semibold)).foregroundStyle(Pal.text1)
                Spacer()
                if let v = scale {
                    Chip(text: "−") { AppConfig.setScale(Self.clamp(v - 0.05, 0.5, 2)) }
                    Text(String(format: "%.2f", v)).font(Pal.font(12, .semibold)).foregroundStyle(Pal.text1).frame(width: 44)
                    Chip(text: "+") { AppConfig.setScale(Self.clamp(v + 0.05, 0.5, 2)) }
                } else {
                    Text("auto \(String(format: "%.2f", Scale.factor))").font(T.sub).foregroundStyle(Pal.text4)
                }
                Chip(text: "Auto", on: scale == nil) { AppConfig.setScale(scale == nil ? Self.clamp(Double(Scale.factor), 0.5, 2) : nil) }
            }
            if scale != nil { Text("Scale applies on restart.").font(T.sub).foregroundStyle(Pal.text4) }
            stepRow("Edge gap", "\(Int(s.edge))", minus: { Self.set(edge: s.edge - 1) }, plus: { Self.set(edge: s.edge + 1) })
            stepRow("Window gap", "\(Int(s.window))", minus: { Self.set(window: s.window - 1) }, plus: { Self.set(window: s.window + 1) })
            stepRow("Island gap", "\(Int(cfg.gap))", minus: { cfg.setGap(cfg.gap - 1) }, plus: { cfg.setGap(cfg.gap + 1) })
            stepRow("Corner roundness", "\(Int(s.corner))", minus: { Self.set(radius: s.corner - 1) }, plus: { Self.set(radius: s.corner + 1) })
            HStack { Chip(text: "Reset") { AppConfig.setSpacing(Spacing()); AppConfig.setScale(nil); cfg.setGap(8) }; Spacer() }
        }
    }

    private func stepRow(_ label: String, _ text: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Pal.font(12, .semibold)).foregroundStyle(Pal.text1)
            Spacer()
            Chip(text: "−", action: minus)
            Text(text).font(Pal.font(12, .semibold)).foregroundStyle(Pal.text1).frame(width: 44)
            Chip(text: "+", action: plus)
        }
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, (v * 20).rounded() / 20)) }

    /// Writes one spacing value (the others kept at what is in force), clamped to its range.
    private static func set(edge: CGFloat? = nil, window: CGFloat? = nil, radius: CGFloat? = nil) {
        let s = Spacing.current
        func c(_ v: CGFloat, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, Double(v))) }
        AppConfig.setSpacing(Spacing(edgeGap: edge.map { c($0, Spacing.edgeRange) } ?? Double(s.edge),
                                     windowGap: window.map { c($0, Spacing.windowRange) } ?? Double(s.window),
                                     radius: radius.map { c($0, Spacing.radiusRange) } ?? Double(s.corner)))
    }
}
