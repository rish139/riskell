import SwiftUI
import RiskellKit

/// The notch grown sideways: a pitch-black body from the cutout's edges out to `e` x (wing width), flush with the screen's top
/// edge, concave fillets where it meets that edge (the same Bézier ear as the hug strip) and rounded bottom corners.
/// e = 0 is exactly the hardware notch (invisible, nothing drawn outside it).
struct NotchIsland: Shape {
    var notchL: CGFloat, notchR: CGFloat, wing: CGFloat, r: CGFloat
    var e: CGFloat
    var animatableData: CGFloat { get { e } set { e = newValue } }

    func path(in rect: CGRect) -> Path {
        let l = notchL - wing * e, rr = notchR + wing * e, h = rect.height
        let re = r * e, k: CGFloat = 0.5522847498
        let rb = max(re, r)          // the bottom corners are never square: collapsed, this is the hardware notch, whose own corners are round
        var p = Path()
        p.move(to: CGPoint(x: l - re, y: 0))
        p.addLine(to: CGPoint(x: rr + re, y: 0))
        // right ear: solid corner (rr, 0)
        p.addCurve(to: CGPoint(x: rr, y: re), control1: CGPoint(x: rr + re * (1 - k), y: 0), control2: CGPoint(x: rr, y: re * (1 - k)))
        p.addLine(to: CGPoint(x: rr, y: h - rb))
        p.addCurve(to: CGPoint(x: rr - rb, y: h), control1: CGPoint(x: rr, y: h - rb + rb * k), control2: CGPoint(x: rr - rb + rb * k, y: h))
        p.addLine(to: CGPoint(x: l + rb, y: h))
        p.addCurve(to: CGPoint(x: l, y: h - rb), control1: CGPoint(x: l + rb - rb * k, y: h), control2: CGPoint(x: l, y: h - rb + rb * k))
        p.addLine(to: CGPoint(x: l, y: re))
        // left ear
        p.addCurve(to: CGPoint(x: l - re, y: 0), control1: CGPoint(x: l, y: re * (1 - k)), control2: CGPoint(x: l - re * (1 - k), y: 0))
        p.closeSubpath()
        return p
    }
}

/// The notch wings (a dynamic island): the playing app's icon just left of the notch, play/pause just right of it, on pitch
/// black that grows out of the notch. Nothing while no app has media.
struct Wings: View {
    @ObservedObject var s = store
    let notchL: CGFloat, notchR: CGFloat       // notch edges, in the top panel's coordinates
    let bandH: CGFloat
    private let box: CGFloat = 18, gap: CGFloat = 4.5, pad: CGFloat = 9   // Void: scaled(16) icon box, scaled(4) gap to the cutout

    var body: some View {
        let on = s.media != nil
        ZStack(alignment: .topLeading) {
            NotchIsland(notchL: notchL, notchR: notchR, wing: gap + box + pad, r: G.radius, e: on ? 1 : 0)
                .fill(Color.black)
                .animation(.spring(duration: 0.42, bounce: 0.22), value: on)
            if let m = s.media {
                Image(nsImage: Self.icon(m.bundle))
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: box, height: box)
                    .modifier(Swell()).offset(x: notchL - gap - box, y: (bandH - box) / 2)
                    .onTapGesture { Self.raise(m.bundle) }
                    .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.12)))
                Image(systemName: m.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.accent)
                    .frame(width: box, height: box).contentShape(Rectangle())
                    .modifier(Swell()).offset(x: notchR + gap, y: (bandH - box) / 2)
                    .onTapGesture { NowPlaying.toggle() }
                    .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.12)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(on)
    }

    static var cache: [String: NSImage] = [:]
    static func icon(_ bundle: String) -> NSImage {
        if let i = cache[bundle] { return i }
        let i = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!
        cache[bundle] = i; return i
    }
    static func raise(_ bundle: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate()
    }
}
