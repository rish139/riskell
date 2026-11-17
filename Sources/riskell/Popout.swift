import AppKit
import SwiftUI
import RiskellKit

/// The one popout host. There is a single panel for every card: an atom reports hover, the panel is placed against the bar,
/// the card springs open from the bar's side and closes on leave or (when pinned by a click) on a click anywhere else.
/// Cards are plain SwiftUI views looked up by id in `PopCard`; their size is declared in `PopCard.size`.
final class Popout: ObservableObject {
    static let shared = Popout()

    @Published private(set) var card: String? = nil { didSet { PopState.shared.sync(card: card, stage: stage, open: open) } }     // the card on the panel (kept until the close spring is done)
    @Published private(set) var open = false { didSet { PopState.shared.sync(card: card, stage: stage, open: open) } }           // the spring target
    @Published private(set) var stage = 1 { didSet { PopState.shared.sync(card: card, stage: stage, open: open) } }                // 1 glance (closes on leave), 2 expanded (pinned: closes on a click elsewhere)
    @Published private(set) var edge = PopEdge.below
    /// A strip's card is pushed back inside the area between the top and bottom bars; the island it opens from floats by the margin part of
    /// that push (SwiftUI points, positive = down) so the two stay together. Zero for cards of the top and bottom bars.
    @Published private(set) var floatY: CGFloat = 0
    /// The card on the panel is drawn in the chat style (its bar's spill), and where its neck sits (ChatCard.swift).
    @Published private(set) var chat = false
    @Published private(set) var chatGeo = ChatGeo(neckLo: 0, neckHi: 0)

    private var panel: PopPanel?
    private var host: NSHostingView<AnyView>?
    private var anchor = CGRect.zero
    private var island = CGRect.zero        // the whole island the atom is in (screen), for the chat card's neck
    private var hold = CGRect.zero          // extra screen area that still counts as "on the atom" (the floated rail)
    /// A drag in progress keeps the card out whatever the pointer does.
    var holdOpen = false { didSet { if oldValue && !holdOpen { scheduleClose() } } }
    private var atomHot = false, cardHot = false
    private var closeWork: DispatchWorkItem?
    private var teardown: DispatchWorkItem?
    private var monitors: [Any] = []

    // MARK: atom side

    func hover(_ id: String, anchor a: CGRect, edge e: PopEdge, island isl: CGRect? = nil) {
        if Config.shared.editing { return }      // no cards while the layout is being edited (on any bar)
        atomHot = true; closeWork?.cancel()
        if card == id && open { return }
        if card != id { stage = 1 }
        // A pointer moving to another widget of an island that is already floated reports rectangles that include the float; the placement
        // works from rest positions (as `reanchor` does), or the island would drop back while its card stays where it was.
        let floated = open && e == edge ? floatY : 0
        anchor = a.offsetBy(dx: 0, dy: floated); island = (isl ?? a).offsetBy(dx: 0, dy: floated); edge = e; card = id
        let c = Config.shared.isChat(BarKey.bar(for: e))
        if c != chat { chat = c }
        place()
        panel?.orderFrontRegardless()
        teardown?.cancel()
        open = true
        armClickAway(); startWatch()
    }
    /// The atom moved or resized (the battery slides its runtime out): the card follows it, so it stays centred on what you see.
    /// The island is re-read with it: a chat card's neck joins the whole pill, which may have grown too.
    func reanchor(_ id: String, _ a: CGRect, island isl: CGRect?) {
        guard card == id, open else { return }
        anchor = a.offsetBy(dx: 0, dy: floatY); if let isl { island = isl.offsetBy(dx: 0, dy: floatY) }     // the atom may be floating: its natural place is where it was
        place()
    }
    func leave(_ id: String) { if card == id { atomHot = false; scheduleClose() } }
    /// Clicking the atom pins the card in its expanded stage, or folds it back.
    func toggleStage(_ id: String) {
        guard card == id else { return }
        setStage(stage == 1 ? 2 : 1)
    }

    // MARK: card side

    func hoverCard(_ h: Bool) {  cardHot = h; if h { closeWork?.cancel() } else { scheduleClose() } }
    func setStage(_ s: Int) {
        guard card != nil, s != stage else { return }
        let shrinking = s < stage
        stage = s
        if shrinking {      // the window follows the card down only once the spring has let go
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in if self?.stage == s { self?.place() } }
            scheduleClose()
        } else { place() }
        armClickAway()      // a click outside always dismisses, whatever the stage
    }
    func close() {
        guard open else { return }
        open = false; stage = 1; atomHot = false; cardHot = false
        holdOpen = false; panel?.keyable = false; panel?.resignKey()      // whatever was holding the card (a search, a drag) lets go with it
        closeWork?.cancel(); disarmClickAway(); stopWatch()
        let t = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil); self?.card = nil }
        teardown = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: t)
    }

    private func scheduleClose() {
        closeWork?.cancel()
        guard stage == 1 else { return }
        // Close only when the pointer really is outside the atom and the card. A Space change (or anything else that resets hover
        // tracking) reports "left" while the pointer has not moved; in that case look again shortly instead of closing.
        let w = DispatchWorkItem { [weak self] in
            guard let s = self, s.open, s.stage == 1, !s.holdOpen else { return }
            let m = NSEvent.mouseLocation
            if s.anchor.contains(m) || s.hold.contains(m) || (s.panel?.frame.contains(m) ?? false) { s.recheck() } else { s.close() }
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
    }
    private func recheck() {
        closeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scheduleClose() }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    // MARK: window

    /// The window is in real points; the card's size is a design size, scaled here, and its content lays out in design units.
    private func place() {
        guard let id = card else { return }
        let k = Real.k
        let design = PopCard.size(id, stage: stage)
        let size = CGSize(width: design.width * k, height: design.height * k), r = Real.cardRadius
        let f = Display.current.frame
        let frame: CGRect
        if chat {
            frame = chatFrame(size: design, in: f)
        } else if edge == .right || edge == .left {
            // beside the hug strip, flush against it (1 px overlap, one solid colour), r of room above and below for the coves
            let natural = anchor.maxY + 6 * k
            let lo = f.minY + (Config.shared.on(.bottom) ? Real.safeBottom : 10 * k) + r + size.height, hi = f.maxY - Real.safeTop - r
            let top = min(max(natural, lo), hi)          // too tall for the room: the top bar wins
            // the island floats only by what the margins add to the old fit-the-screen push (a tall card was always moved off its atom)
            let before = max(natural, f.minY + r + 4 * k + size.height)
            if floatY != before - top { floatY = before - top }
            if edge == .right {
                frame = CGRect(x: f.minX + Real.strip - 1, y: top - size.height - r, width: size.width, height: size.height + 2 * r)
                hold = CGRect(x: f.minX, y: frame.minY, width: Real.strip, height: frame.height)
            } else {
                frame = CGRect(x: f.maxX - Real.strip + 1 - size.width, y: top - size.height - r, width: size.width, height: size.height + 2 * r)
                hold = CGRect(x: f.maxX - Real.strip, y: frame.minY, width: Real.strip, height: frame.height)
            }
        } else {
            // the card hangs flush from the bar band (1 px overlap, one solid colour); the panel is r wider each side for the coves
            let x = min(max(anchor.midX - size.width / 2, f.minX + Config.shared.leftW + Real.edgeGap + r), f.maxX - Config.shared.rightW - Real.edgeGap - r - size.width)
            let y = edge == .below ? f.maxY - Display.current.topInset - Real.band + 1 - size.height : f.minY + Real.bottomIslandTop - 1      // a screen without a notch: the top bar sits under the menu bar
            frame = CGRect(x: x - r, y: y, width: size.width + 2 * r, height: size.height)
            hold = .zero
            if floatY != 0 { floatY = 0 }
        }
        if panel == nil {
            let h = NSHostingView(rootView: AnyView(ThemeRoot(content: PopRoot().environmentObject(store))))
            h.autoresizingMask = [.width, .height]
            h.sizingOptions = []      // riskell sets every window frame itself; the SwiftUI content's own size (in design units) must not set a minimum
            let p = PopPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.collectionBehavior = [.ignoresCycle]
            p.isReleasedWhenClosed = false
            p.contentView = h
            host = h; panel = p
            p.level = NSWindow.Level(rawValue: chat ? barBaseLevel + ChatCard.level : barBaseLevel)
            p.setFrame(frame, display: true)
            h.useDesignUnits()
            p.orderFrontRegardless()
            Sky.pin([p])
        } else {
            panel?.level = NSWindow.Level(rawValue: chat ? barBaseLevel + ChatCard.level : barBaseLevel)
            panel?.setFrame(frame, display: true)
            host?.useDesignUnits()
        }
    }

    /// The chat card's panel: it reaches `overlap` into the pill (above the bar's own panel, so it covers the pill's hairline across the join),
    /// then the neck, then the card. On a horizontal bar the card is centred on the hovered atom and kept on the screen (`ChatCard.fit`); on a strip it
    /// hangs from the island, which stays put unless the overlap would be too small (`ChatCard.stripFit`). The neck uses the stretch of the island's
    /// edge the card can reach. Along a strip the axis is measured down from the screen's top, as the shape draws it.
    /// The chat maths works in design units (ChatCard's constants are design values): the rectangles are divided by the factor on the way in
    /// and the frame and `hold` multiplied back out. `floatY` is real points, like `hold`.
    private func chatFrame(size: CGSize, in screenF: CGRect) -> CGRect {
        let k = Real.k, n = ChatCard.neck, o = ChatCard.overlap
        let isl = island.scaled(by: 1 / k), f = screenF.scaled(by: 1 / k), anc = anchor.scaled(by: 1 / k)
        let left = Config.shared.leftW / k, right = Config.shared.rightW / k
        let start: CGFloat, neck: ClosedRange<CGFloat>, frame: CGRect
        if ChatCard.horizontal(edge) {
            let W = size.width, H = o + n + size.height
            (start, neck) = ChatCard.fit(island: isl.minX...isl.maxX, length: W, want: anc.midX - W / 2,      // centred on the hovered atom, not the whole pill
                                         bounds: (f.minX + left + G.edgeGap)...(f.maxX - right - G.edgeGap))
            frame = CGRect(x: start, y: edge == .below ? isl.minY + o - H : isl.maxY - o, width: W, height: H)
            hold = .zero
            if floatY != 0 { floatY = 0 }
        } else {
            let Hc = size.height, T = o + n + size.width
            let bottom = f.maxY - f.minY - (Config.shared.on(.bottom) ? G.safeBottom : 10)
            let fit = ChatCard.stripFit(island: (f.maxY - isl.maxY)...(f.maxY - isl.minY), length: Hc, bounds: G.safeTop...bottom)
            (start, neck) = (fit.start, fit.neck)
            frame = CGRect(x: edge == .right ? isl.maxX - o : isl.minX + o - T, y: f.maxY - start - Hc, width: T, height: Hc)
            if floatY != fit.shift * k { floatY = fit.shift * k }                            // the island floats to its card (down is positive, as in the flush style)
            hold = isl.union(isl.offsetBy(dx: 0, dy: -fit.shift)).scaled(by: k)                 // the pointer may be on the island's resting place or on where it floated to
        }
        let geo = ChatGeo(neckLo: neck.lowerBound - start, neckHi: neck.upperBound - start)
        if geo != chatGeo { chatGeo = geo }
        return frame.scaled(by: k)
    }

    /// Is a screen point on the atom, the strip beside a floated rail, or the card itself (with a few px of slop)?
    private func onTarget(_ m: CGPoint) -> Bool {
        anchor.insetBy(dx: -4, dy: -4).contains(m) || hold.contains(m) || (panel?.frame.insetBy(dx: -4, dy: -4).contains(m) ?? false)
    }

    /// A click anywhere that is not the atom or the card dismisses the card, in every state: the global monitor sees other apps, the local one our own bars.
    private func armClickAway() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in DispatchQueue.main.async { self?.close() } }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            if let s = self, e.window !== s.panel, !s.onTarget(NSEvent.mouseLocation) { DispatchQueue.main.async { s.close() } }
            return e
        }) { monitors.append(l) }
    }

    /// The backstop. Hover events are edge-triggered and SwiftUI does not promise to deliver every one (a missed "pointer left" would leave a
    /// card out for good), so while a card is open the pointer's position is checked directly: off the atom and the card for about half a
    /// second closes it. A drag, a search or a pinned stage holds it open. Runs only while a card is out.
    private var watch: Timer?
    private var outside = 0
    private func startWatch() {
        guard watch == nil else { return }
        outside = 0
        watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.watchTick() }
        watch?.tolerance = 0.05
    }
    private func stopWatch() { watch?.invalidate(); watch = nil }
    private func watchTick() {
        guard open else { stopWatch(); return }
        if stage != 1 || holdOpen || NSEvent.pressedMouseButtons != 0 || onTarget(NSEvent.mouseLocation) { outside = 0; return }
        outside += 1
        if outside >= 2 { tlog("popout: closed by the watchdog"); close() }
    }
    private func disarmClickAway() { monitors.forEach(NSEvent.removeMonitor); monitors = [] }

    /// The card changed size by itself (a tile is being carried and a slot opens): follow it.
    func refit() { if open { objectWillChange.send(); place() } }

    /// A text field in the card needs the panel to be a key window while it is being typed in.
    func setKeyable(_ on: Bool) {
        panel?.keyable = on
        if on { panel?.makeKey() } else { panel?.resignKey() }
        holdOpen = on
    }

    /// Debug / snapshot: the panel's content view.
    var snapshotView: NSView? { host }
}

final class PopPanel: NSPanel {
    var keyable = false          // a card with a text field (the vitals search) lets the panel take keys, without activating the app
    override var canBecomeKey: Bool { keyable }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The card: solid, welded to the surface it hangs from (the bar band, or the hug strip). Square where it meets that surface with a
/// concave cove beside each of those corners, rounded away from it, an outline open at that side. It is revealed by clip (the content
/// is laid out once at full size and never reflows): in height from a bar, in width from the strip.
struct PopRoot: View {
    @ObservedObject var pop = Popout.shared
    var body: some View {
        if let id = pop.card, pop.chat {
            ChatPopRoot(pop: pop, id: id)
        } else if let id = pop.card {
            let size = PopCard.size(id, stage: pop.stage), r = G.cardRadius
            let spring = Animation.spring(duration: 0.30, bounce: 0.05)
            switch pop.edge {
            case .right:
                let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: r, topTrailingRadius: r)
                PopCard.content(id)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)      // top-aligned: a card whose content is taller than its stage-1 size (the date card, with its hidden month) must not be centred
                    .frame(width: pop.open ? size.width : 1, alignment: .leading)
                    .background(shape.fill(Pal.cardSolid))
                    .overlay(CardEdge(edge: .right, r: r).stroke(Pal.warmEdge, lineWidth: 1))
                    .clipShape(shape)
                    .onHover { pop.hoverCard($0) }
                    .padding(.vertical, r)
                    .overlay(alignment: .topLeading) { EarShape(corner: 2).fill(Pal.cardSolid).frame(width: r, height: r) }
                    .overlay(alignment: .bottomLeading) { EarShape(corner: 0).fill(Pal.cardSolid).frame(width: r, height: r) }
                    .opacity(pop.open ? 1 : 0)
                    .animation(spring, value: pop.open)
                    .animation(spring, value: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .left:
                let shape = UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: 0, topTrailingRadius: 0)
                PopCard.content(id)
                    .frame(width: size.width, height: size.height, alignment: .topTrailing)
                    .frame(width: pop.open ? size.width : 1, alignment: .trailing)
                    .background(shape.fill(Pal.cardSolid))
                    .overlay(CardEdge(edge: .left, r: r).stroke(Pal.warmEdge, lineWidth: 1))
                    .clipShape(shape)
                    .onHover { pop.hoverCard($0) }
                    .padding(.vertical, r)
                    .overlay(alignment: .topTrailing) { EarShape(corner: 3).fill(Pal.cardSolid).frame(width: r, height: r) }
                    .overlay(alignment: .bottomTrailing) { EarShape(corner: 1).fill(Pal.cardSolid).frame(width: r, height: r) }
                    .opacity(pop.open ? 1 : 0)
                    .animation(spring, value: pop.open)
                    .animation(spring, value: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            default:
                let below = pop.edge == .below
                let al: Alignment = below ? .top : .bottom
                let shape = UnevenRoundedRectangle(topLeadingRadius: below ? 0 : r, bottomLeadingRadius: below ? r : 0,
                                                   bottomTrailingRadius: below ? r : 0, topTrailingRadius: below ? 0 : r)
                PopCard.content(id)
                    .frame(width: size.width, height: size.height, alignment: al)
                    .frame(height: pop.open ? size.height : 1, alignment: al)
                    .background(shape.fill(Pal.cardSolid))
                    .overlay(CardEdge(edge: pop.edge, r: r).stroke(Pal.warmEdge, lineWidth: 1))
                    .clipShape(shape)
                    .onHover { pop.hoverCard($0) }
                    .padding(.horizontal, r)
                    .overlay(alignment: below ? .topLeading : .bottomLeading) { EarShape(corner: below ? 1 : 3).fill(Pal.cardSolid).frame(width: r, height: r) }
                    .overlay(alignment: below ? .topTrailing : .bottomTrailing) { EarShape(corner: below ? 0 : 2).fill(Pal.cardSolid).frame(width: r, height: r) }
                    .opacity(pop.open ? 1 : 0)
                    .animation(spring, value: pop.open)
                    .animation(spring, value: pop.stage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: al)    // the window may be taller than the card (it shrinks late): never recentre
            }
        }
    }
}

/// The outline of a welded card: down both sides and round the free end, nothing along the side it hangs from (it starts where the cove ends).
struct CardEdge: Shape {
    let edge: PopEdge, r: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if edge == .left { return CardEdge(edge: .right, r: r).path(in: rect).applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0)) }
        if edge == .right {
            guard rect.width > 2 * r + 2 else { return p }
            p.move(to: CGPoint(x: r, y: 0))
            p.addLine(to: CGPoint(x: rect.width - r, y: 0))
            p.addArc(center: CGPoint(x: rect.width - r, y: r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.width, y: rect.height - r))
            p.addArc(center: CGPoint(x: rect.width - r, y: rect.height - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: r, y: rect.height))
            return p
        }
        let below = edge == .below
        let y0 = below ? r : rect.height - r, y1 = below ? rect.height - r : r
        guard abs(y1 - y0) > 2 else { return p }
        p.move(to: CGPoint(x: 0, y: y0))
        p.addLine(to: CGPoint(x: 0, y: y1))
        let cy = below ? rect.height - r : r
        p.addArc(center: CGPoint(x: r, y: cy), radius: r, startAngle: .degrees(180), endAngle: .degrees(below ? 90 : 270), clockwise: below)
        p.addLine(to: CGPoint(x: rect.width - r, y: below ? rect.height : 0))
        p.addArc(center: CGPoint(x: rect.width - r, y: cy), radius: r, startAngle: .degrees(below ? 90 : 270), endAngle: .degrees(0), clockwise: below)
        p.addLine(to: CGPoint(x: rect.width, y: y0))
        return p
    }
}

enum PopCard {
    static func size(_ id: String, stage: Int) -> CGSize { Registry.cards[id]?.size(stage) ?? CGSize(width: 240, height: 120) }
    @ViewBuilder static func content(_ id: String) -> some View {
        if let c = Registry.cards[id] { c.content() }
    }
}
