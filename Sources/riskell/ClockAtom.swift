import SwiftUI
import RiskellKit

/// The clock: hh:mm bold over the seconds "drain" (a groove as wide as the digits, filled by ss/60, quarter marks, a live head),
/// then a hairline and the date tier (MON over its day number). 12 h shows a ghost meridiem chip, 24 h the seconds figures.
/// Hover warms the digits and the date, swells the drain and flares its head, and opens the date card.
/// On the left strip (`vertical`) it stands up as a column: HH over MM, the drain as a short bar under them, the meridiem chip
/// (12 h), a hairline, then the date tier (MON over the day number). Same figures, same tones, same hover.
/// Time comes from two TimelineViews (the minute, and the drain once a second) so only what changed is drawn.
/// One timer for every clock reader, aligned to the second. `minute` only changes once a minute, so the digits and the date
/// redraw once a minute and only the drain redraws every second.
final class ClockSeconds: ObservableObject {
    @Published private(set) var second = Calendar.current.component(.second, from: Date())
    func set(_ s: Int) { if s != second { second = s } }
}

final class Clock: ObservableObject {
    static let shared = Clock()
    @Published private(set) var minute = Date()
    /// Its own object: the atom observes only `minute`, so the seconds tick redraws just the drain.
    let seconds = ClockSeconds()
    private var timer: DispatchSourceTimer?
    func start() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + (1 - Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)), repeating: 1, leeway: .milliseconds(15))
        t.setEventHandler { [unowned self] in
            let now = Date(), s = Calendar.current.component(.second, from: now)
            seconds.set(s)
            if s == 0 { minute = now }
        }
        t.resume(); timer = t
    }
}

struct ClockAtom: View {
    @ObservedObject private var clock = Clock.shared
    @State private var hot = false
    let vertical: Bool
    static let twelve = (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    private static let hhFmt = fmt(twelve ? "hh" : "HH"), mmFmt = fmt("mm"), merFmt = fmt("a"), dowFmt = fmt("EEE"), dayFmt = fmt("d")
    private static func fmt(_ f: String) -> DateFormatter { let d = DateFormatter(); d.dateFormat = f; return d }

    var body: some View {
        let d = clock.minute
        Group {
            if vertical {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Text(Self.hhFmt.string(from: d)).font(T.value).foregroundStyle(hot ? Pal.accent : Pal.text1)
                        Text(Self.mmFmt.string(from: d)).font(T.value).foregroundStyle(hot ? Pal.accent : Pal.text1)
                    }
                    .fixedSize()
                    Drain(hot: hot, clock: clock.seconds)
                        .frame(width: 26)
                        .padding(.top, 5)
                    if Self.twelve {
                        Text(Self.merFmt.string(from: d).uppercased()).font(T.cap).tracking(0.5)
                            .foregroundStyle(hot ? Pal.accent : Pal.text4)
                            .padding(.horizontal, 4).frame(height: 13)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Pal.pressFill))
                            .padding(.top, 6)
                    }
                    Rectangle().fill(Pal.hairline).frame(width: 22, height: 1).padding(.vertical, 7)
                    VStack(spacing: 0) {
                        Cap(text: Self.dowFmt.string(from: d).uppercased(), hot: hot)
                        Text(Self.dayFmt.string(from: d)).font(Pal.font(12, .bold)).foregroundStyle(hot ? Pal.text1 : Pal.text2)
                    }
                    .fixedSize()
                }
                .frame(width: 40)
            } else {
                HStack(spacing: T.gap + 3) {
                    HStack(alignment: .center, spacing: 0) {
                        Text(Self.hhFmt.string(from: d)).font(T.value).foregroundStyle(hot ? Pal.accent : Pal.text1)
                        Text(":").font(Pal.font(14)).foregroundStyle(Pal.text4).padding(.horizontal, 1)
                        Text(Self.mmFmt.string(from: d)).font(T.value).foregroundStyle(hot ? Pal.accent : Pal.text1)
                        if Self.twelve { Text(Self.merFmt.string(from: d).uppercased()).font(T.cap).tracking(0.5).foregroundStyle(hot ? Pal.accent : Pal.text4).padding(.leading, 5) }
                    }
                    .fixedSize()
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) { Drain(hot: hot, clock: clock.seconds).padding(.bottom, 1) }    // as wide as the digits, never wider
                    VStack(spacing: 0) {
                        Cap(text: Self.dowFmt.string(from: d).uppercased(), hot: hot)
                        Text(Self.dayFmt.string(from: d)).font(Pal.font(12, .bold)).foregroundStyle(hot ? Pal.text1 : Pal.text2)
                    }
                }
                .frame(height: G.pill)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hot)
        .popout("date", edge: .below, hot: $hot, click: true)
    }
}

/// The seconds drain, redrawn once a second. Its width is whatever the digits above it give it. One Canvas, so the tick costs a draw
/// and not a layout of five views; `k` (0 resting, 1 hovered) is animatable, which keeps the hover spring.
private struct Drain: View {
    let hot: Bool
    @ObservedObject var clock: ClockSeconds
    var body: some View {
        DrainCanvas(f: CGFloat(clock.second) / 60, k: hot ? 1 : 0)
            .animation(.spring(duration: 0.26, bounce: 0.18), value: hot)
            .frame(height: 7)
    }
}

private struct DrainCanvas: View, Animatable {
    var f: CGFloat
    var k: CGFloat
    var animatableData: CGFloat { get { k } set { k = newValue } }
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, mid = size.height / 2
            let track = 2 + 1.7 * k
            let groove = CGRect(x: 0, y: mid - track / 2, width: w, height: track)
            ctx.fill(Path(roundedRect: groove, cornerRadius: track / 2), with: .color(Pal.groove))
            if f > 0 {
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: groove.minY, width: (w * f).rounded(), height: track), cornerRadius: track / 2), with: .color(Pal.accent.opacity(0.40)))
            }
            let hh = track + 3.4
            ctx.fill(Path(roundedRect: CGRect(x: (w * f).rounded() - 1, y: mid - hh / 2, width: 2, height: hh), cornerRadius: 1), with: .color(Pal.accent))
        }
    }
}
