import SwiftUI
import RiskellKit

/// The two vendors' brand marks, native colours (never tinted), rendered once from their own SVG.
enum Brand {
    static let claude: NSImage? = NSImage(data: Data(##"<svg fill="none" height="40" viewBox="0 -.01 39.5 39.53" width="40" xmlns="http://www.w3.org/2000/svg"><path d="m7.75 26.27 7.77-4.36.13-.38-.13-.21h-.38l-1.3-.08-4.44-.12-3.85-.16-3.73-.2-.94-.2-.88-1.16.09-.58.79-.53 1.13.1 2.5.17 3.75.26 2.72.16 4.03.42h.64l.09-.26-.22-.16-.17-.16-3.88-2.63-4.2-2.78-2.2-1.6-1.19-.81-.6-.76-.26-1.66 1.08-1.19 1.45.1.37.1 1.47 1.13 3.14 2.43 4.1 3.02.6.5.24-.17.03-.12-.27-.45-2.23-4.03-2.38-4.1-1.06-1.7-.28-1.02c-.1-.42-.17-.77-.17-1.2l1.23-1.67.68-.22 1.64.22.69.6 1.02 2.33 1.65 3.67 2.56 4.99.75 1.48.4 1.37.15.42h.26v-.24l.21-2.81.39-3.45.38-4.44.13-1.25.62-1.5 1.23-.81.96.46.79 1.13-.11.73-.47 3.05-.92 4.78-.6 3.2h.35l.4-.4 1.62-2.15 2.72-3.4 1.2-1.35 1.4-1.49.9-.71h1.7l1.25 1.86-.56 1.92-1.75 2.22-1.45 1.88-2.08 2.8-1.3 2.24.12.18.31-.03 4.7-1 2.54-.46 3.03-.52 1.37.64.15.65-.54 1.33-3.24.8-3.8.76-5.66 1.34-.07.05.08.1 2.55.24 1.09.06h2.67l4.97.37 1.3.86.78 1.05-.13.8-2 1.02-2.7-.64-6.3-1.5-2.16-.54h-.3v.18l1.8 1.76 3.3 2.98 4.13 3.84.21.95-.53.75-.56-.08-3.63-2.73-1.4-1.23-3.17-2.67h-.21v.28l.73 1.07 3.86 5.8.2 1.78-.28.58-1 .35-1.1-.2-2.26-3.17-2.33-3.57-1.88-3.2-.23.13-1.11 11.95-.52.61-1.2.46-1-.76-.53-1.23.53-2.43.64-3.17.52-2.52.47-3.13.28-1.04-.02-.07-.23.03-2.36 3.24-3.59 4.85-2.84 3.04-.68.27-1.18-.61.11-1.09.66-.97 3.93-5 2.37-3.1 1.53-1.79-.01-.26h-.09l-10.44 6.78-1.86.24-.8-.75.1-1.23.38-.4 3.14-2.16z" fill="#d97757"/></svg>"##.utf8))
    static let opencode: NSImage? = NSImage(data: Data("<svg width='24' height='30' viewBox='0 0 240 300' fill='none' xmlns='http://www.w3.org/2000/svg'><path d='M180 240H60V120H180V240Z' fill='#211E1E'/><path d='M180 60H60V240H180V60ZM240 300H0V0H240V300Z' fill='#CFCECD'/></svg>".utf8))
}

/// "4d12h", "3h20m", "42m", "now": the unit that matters
func spanText(_ seconds: Double) -> String {
    if !seconds.isFinite { return "—" }
    if seconds <= 0 { return "now" }
    let h = Int(seconds / 3600), d = h / 24, hh = h % 24, m = Int((seconds.truncatingRemainder(dividingBy: 3600) / 60).rounded())
    if d > 0 { return hh > 0 ? "\(d)d\(hh)h" : "\(d)d" }
    if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
    return m > 0 ? "\(m)m" : "\(max(1, Int(seconds)))s"
}

/// USAGE, stood up on the strip above the fan: each vendor is a column of its native mark, the exact %, and a bar (Claude: the worse of
/// its 5 h and 7 d windows, OpenCode: its monthly one). Over 60 % the bar warms, over 80 % it goes red, spent shows "MAX" in red;
/// a reading that is old is dimmed. Countdowns live in the card. Hover swells the bars and marks and opens the usage card.
/// On a horizontal bar (`vertical` false) it is one 36 pt row: each vendor is its mark, the figure and a 34 pt bar, the two vendors
/// split by the usual hairline. Same data, tones, dimming and hover.
struct UsageAtom: View {
    @EnvironmentObject var s: Store
    @ObservedObject private var cfg = Config.shared
    @State private var hot = false
    let vertical: Bool

    var body: some View {
        let c = s.claude, o = s.opencode
        // only the vendors switched on in config.json are drawn; with none, the atom is an "off" placeholder and has no card
        let showC = AppConfig.shared.claudeEnabled, showO = AppConfig.shared.opencodeWorkspace != nil
        anchored(Group {
            if !showC && !showO {
                // blank: drawn only in edit mode, so the atom can be moved; elsewhere it is nothing (an island of only this is not drawn at all)
                if cfg.editing {
                    Text("OFF").font(Pal.font(9, .bold)).tracking(1.4).foregroundStyle(Pal.text4)
                        .frame(width: vertical ? G.strip : nil, height: vertical ? nil : G.pill)
                }
            } else if vertical {
                VStack(spacing: 10) {
                    if showC { vendor(mark: Brand.claude, markW: 13, markH: 13, value: c?.rep ?? -1, base: Pal.accent, stale: c?.stale == true) }
                    if showO { vendor(mark: Brand.opencode, markW: 10.4, markH: 13, value: o?.rep ?? -1, base: Pal.accent, stale: o?.stale == true) }
                }
                .frame(width: G.strip)
            } else {
                HStack(spacing: 0) {
                    if showC { row(mark: Brand.claude, markW: 13, markH: 13, value: c?.rep ?? -1, stale: c?.stale == true) }
                    if showC && showO { Sep(height: 18).padding(.horizontal, 5) }
                    if showO { row(mark: Brand.opencode, markW: 10.4, markH: 13, value: o?.rep ?? -1, stale: o?.stale == true) }
                }
                .frame(height: G.pill)
            }
        }
        .animation(.spring(duration: 0.26, bounce: 0.18), value: hot), on: showC || showO)
    }

    /// The card opens only while a vendor is on: with none, hovering the placeholder does nothing.
    @ViewBuilder private func anchored<V: View>(_ v: V, on: Bool) -> some View {
        if on { v.popout("usage", edge: .right, hot: $hot) } else { v }
    }

    /// One vendor on a horizontal bar: the mark, the figure (right-aligned in a fixed bay so the bar does not shift), the bar.
    private func row(mark: NSImage?, markW: CGFloat, markH: CGFloat, value: Int, stale: Bool) -> some View {
        let spent = value >= 100
        let tone: Color = value > 80 ? Pal.crit : value > 60 ? Pal.warn : Pal.accent
        return HStack(spacing: T.gap) {
            Group { if let mark { Image(nsImage: mark).resizable().interpolation(.high).aspectRatio(contentMode: .fit) } }
                .frame(width: markW, height: markH).scaleEffect(hot ? 1.18 : 1)
            Num(value: value < 0 ? "—" : spent ? "MAX" : String(value), unit: value >= 0 && !spent ? "%" : nil,
                tone: spent ? Pal.critInk : Pal.text1, hot: hot && !spent)
                .frame(minWidth: 30, alignment: .trailing)
            Bar(value: value < 0 ? 0 : Double(value) / 100, tone: tone, hot: hot, width: 34)
        }
        .opacity(stale ? 0.6 : 1)
    }

    private func vendor(mark: NSImage?, markW: CGFloat, markH: CGFloat, value: Int, base: Color, stale: Bool) -> some View {
        let spent = value >= 100
        let tone: Color = value > 80 ? Pal.crit : value > 60 ? Pal.warn : base
        return VStack(spacing: 3) {
            Group { if let mark { Image(nsImage: mark).resizable().interpolation(.high).aspectRatio(contentMode: .fit) } }
                .frame(width: markW, height: markH).scaleEffect(hot ? 1.18 : 1)
            HStack(alignment: .firstTextBaseline, spacing: 0.5) {
                Text(value < 0 ? "—" : spent ? "MAX" : String(value)).font(Pal.font(11, .bold)).foregroundStyle(spent ? Pal.critInk : hot ? Pal.accent : Pal.text1)
                if value >= 0 && !spent { Text("%").font(Pal.font(8)).foregroundStyle(Pal.text4) }
            }
            Bar(value: value < 0 ? 0 : Double(value) / 100, tone: tone, hot: hot, width: 26)
        }
        .opacity(stale ? 0.6 : 1)
    }
}
