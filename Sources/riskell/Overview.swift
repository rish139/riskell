import AppKit
import Carbon.HIToolbox
import CoreImage
import Combine
import SwiftUI
import RiskellKit
import RiskellWM

/// Where a window sits on its workspace, as the backends parse it (RiskellWM, so a recorded payload carries frames too).
typealias WinFrame = RiskellWM.WinFrame

/// A snapshot of one of riskell's own bars, drawn inside every workspace preview.
struct BarShot: Identifiable { let id: Int; let image: NSImage; let rect: CGRect }

/// A window as the overview draws it: where, on which workspace.
/// `settled` is false when the place is predicted after a drop: the window has not been resized yet, so its live picture is the wrong shape there.
struct Placed { let win: WinInfo; let rect: CGRect; let floating: Bool; var settled = true }

/// Shape A: one row of every workspace at one scale, a narrow slot after it for a new workspace, the find field under it.
struct OverviewLayout {
    // design units, scaled to real points like the rest of the screen geometry (Scale.swift)
    static var gap: CGFloat { 32 * Real.k }
    static var slotW: CGFloat { 120 * Real.k }
    static var side: CGFloat { 48 * Real.k }
    static var lift: CGFloat { 60 * Real.k }
    let tiles: [CGRect]
    let slot: CGRect
    let scale: CGFloat

    init(count n: Int, screen: CGSize) {
        let n = max(n, 1)
        let c = Config.shared          // the row sits between the strips that are on
        let avail = screen.width - c.leftW - c.rightW - 2 * Self.side
        let w = max(80 * Real.k, (avail - Self.slotW - CGFloat(n) * Self.gap) / CGFloat(n))
        let h = w * screen.height / screen.width
        let y = screen.height / 2 - h / 2 - Self.lift
        let x0 = c.leftW + Self.side
        tiles = (0..<n).map { CGRect(x: x0 + CGFloat($0) * (w + Self.gap), y: y, width: w, height: h) }
        slot = CGRect(x: x0 + CGFloat(n) * (w + Self.gap), y: y, width: Self.slotW, height: h)
        scale = w / screen.width
    }

    /// The area tiled windows fill (the WM's gaps, see `Config.gap*`): 56 from the top; each side and the bottom give room to the bars that are on.
    static func workArea(_ screen: CGSize) -> CGRect {
        let c = Config.shared
        return CGRect(x: c.gapLeft, y: Config.gapTop, width: screen.width - c.gapLeft - c.gapRight, height: screen.height - Config.gapTop - c.gapBottom)
    }

    /// Windows whose position is unknown: the biggest first, each at the first free top-left corner (the area's, or right of / below a
    /// window already placed). For dwindle's halves and quarters that rebuilds the real layout; anything else still lands sensibly.
    static func place(_ items: [(WinInfo, CGSize, Bool)], around taken: [CGRect], in area: CGRect) -> [Placed] {
        var used = taken, out: [Placed] = []
        for (w, sz, floating) in items.sorted(by: { $0.1.width * $0.1.height > $1.1.width * $1.1.height }) {
            let size = CGSize(width: min(sz.width, area.width), height: min(sz.height, area.height))
            let corners = [area.origin] + used.flatMap { [CGPoint(x: $0.maxX + 7, y: $0.minY), CGPoint(x: $0.minX, y: $0.maxY + 7)] }
            let fits = corners.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.first { c in
                let r = CGRect(origin: c, size: size)
                return area.insetBy(dx: -2, dy: -2).contains(r) && !used.contains { $0.insetBy(dx: 1, dy: 1).intersects(r) }
            }
            let r = CGRect(origin: fits ?? area.origin, size: size)
            used.append(r)
            out.append(Placed(win: w, rect: r, floating: floating))      // a guessed place, but its real size: live is fine
        }
        return out
    }
}

/// riskell's overview. Closed, it is nothing: no panel on screen, no images, no timers. Opening (3-finger swipe up, or ctrl-alt-space)
/// snapshots the bars, captures the windows and morphs the current workspace from the full screen into its place in the row.
final class Overview: ObservableObject {
    static let shared = Overview()

    /// 0 = the desktop, 1 = the row. Set directly while fingers drive it, animated otherwise.
    @Published private(set) var progress: CGFloat = 0
    @Published private(set) var live = false
    /// The workspace whose tile morphs: the current one on open, the one you picked on close.
    @Published private(set) var origin = 1
    @Published var selected: Int? = nil
    /// Hover and drag change at the pointer's rate, so they live in their own object: only the overlay that draws them redraws, not
    /// every tile and capture.
    let pointer = OverviewPointer()
    var hoverWin: Int? {
        get { pointer.hoverWin }
        set { if pointer.hoverWin != newValue { pointer.hoverWin = newValue } }
    }
    var drag: Drag? {
        get { pointer.drag }
        set { pointer.drag = newValue }
    }
    @Published var query = ""
    @Published private(set) var thumbs: [Int: NSImage] = [:]
    @Published private(set) var bars: [BarShot] = []
    private(set) var wallpaper: NSImage?
    private var wallpaperStamp = ""      // the desktop picture's path and modification date: decoded again only when it changes
    /// main.swift: snapshots of the three bars (no Screen Recording needed for our own views).
    var snapshotBars: (() -> [BarShot])?
    private(set) var screen: CGSize

    /// A screen change (a monitor plugged in or out, a mode change): the overview learns the new size, and its panel, made for the old
    /// one, is dropped and made again the next time it opens. An overview that is open at that moment keeps its panel until it is closed.
    func displayChanged() {
        let new = Display.current.frame.size
        guard new != screen else { return }
        screen = new
        if !live, let p = panel { p.orderOut(nil); panel = nil }
    }

    private var panel: OverviewPanel?
    private var monitors: [Any] = []
    private var base: CGFloat = 0
    /// Small copies of the last captures, kept between openings so a reopen shows the last picture at once (then sharpens);
    /// pruned to the windows that still exist. The large captures of the current workspace (for the morph) are dropped on close.
    private var cache: [Int: NSImage] = [:]
    /// The real frames of the windows on the shown workspace, read from the window server 20 times a second while open. The WM's own
    /// reports go stale during its re-layout animations (a drop splits or re-joins); these follow the windows to where they really are.
    @Published private(set) var liveRects: [Int: CGRect] = [:]
    private var tracker: Timer?
    /// OmniWM lays out a hidden workspace only when it is shown (measured: after a move the windows keep their old sizes until then),
    /// so after a drop the overview lays the workspaces involved out as dwindle will: window id -> (its workspace, predicted frame).
    /// Kept across openings; a workspace's entries go when it is visited (the WM's own frames are real again then).
    @Published private(set) var pending: [Int: (space: Int, rect: CGRect)] = [:]
    /// The windows each predicted workspace holds once the move lands. When the WM confirms that set it is armed; after that any other
    /// change there (a window closed, opened, moved by keyboard) drops the workspace's predictions: they no longer describe it.
    private var expected: [Int: (ids: Set<Int>, armed: Bool)] = [:]
    private var windowWatch: AnyCancellable?
    /// Live video per window while the overview is open (each window's view observes only its own feed).
    private var held: [Int: NSImage] = [:]      // pictures that arrived mid-morph, shown when it lands
    private var moving = false
    private var feeds: [Int: LiveFeed] = [:]
    private var feedScale: [Int: CGFloat] = [:]
    private let video = LiveCapture()
    func feed(_ id: Int) -> LiveFeed {
        if let f = feeds[id] { return f }
        let f = LiveFeed(); feeds[id] = f; return f
    }

    private var focusWatch: AnyCancellable?

    init() {
        screen = Display.current.frame.size
        // a workspace being shown gets real frames from the WM: its predictions go, whether the overview is open or not
        focusWatch = store.$spaces.sink { [weak self] spaces in
            guard let self else { return }
            let shown = Set(spaces.filter(\.focused).map(\.id))
            if !self.pending.isEmpty, self.pending.contains(where: { shown.contains($0.value.space) }) { self.forget(shown) }
            // a swipe (or a key) changed the workspace under the open overview: it becomes the one the close morph grows from,
            // and its pictures are refreshed now that the WM has laid it out
            if self.live, !self.moving, let f = shown.first, f != self.origin { self.origin = f; self.refresh(space: f) }
        }
        windowWatch = store.$windows.sink { [weak self] wins in
            guard let self, !self.expected.isEmpty else { return }
            var stale = Set<Int>()
            for (n, e) in self.expected {
                let now = Set(wins.filter { $0.space == n }.map(\.id))
                if now == e.ids { self.expected[n]?.armed = true } else if e.armed { stale.insert(n) }
            }
            if !stale.isEmpty { self.forget(stale) }
        }
    }

    private func forget(_ spaces: Set<Int>) {
        pending = pending.filter { !spaces.contains($0.value.space) }
        for n in spaces { expected[n] = nil }
    }

    /// While three fingers are down (and a moment after) the panel rides above OmniWM's full-screen slide overlay, so a workspace swipe
    /// slides underneath it and the overview stays on screen the whole time.
    private var lifted = false
    func lift(_ on: Bool) {
        lifted = on
        panel?.level = NSWindow.Level(rawValue: on ? overviewLiftLevel : barBaseLevel - 1)
    }

    var isOpen: Bool { live && progress > 0.5 }
    /// Debug snapshots (the `overview-snap` socket command).
    var view: NSView? { panel?.contentView }
    func toggle() { isOpen ? close() : open() }
    func open() { prepare(); animate(to: 1) }

    /// Close; with `n`, the tile of workspace `n` grows back into the screen (the WM switches underneath).
    func close(to n: Int? = nil, quick: Bool = false) {
        guard live else { return }
        if let n { origin = n } else if let t = Overview.swipeTarget() { origin = t }      // grow from the tile a swipe ended on
        query = ""; selected = nil; hoverWin = nil
        animate(to: 0, quick: quick)
    }

    // MARK: gesture (Touch: three fingers moving vertically)

    func gestureBegan() {
        // The fingers own the overview from here. An earlier animation may still be ending (a fade, a morph, or their timed fallbacks): its
        // end is cancelled (they check the animation number), or it would tear down the overview this gesture is about to show.
        animationID += 1
        moving = false
        if live, progress == 0 { teardown() }                      // a panel left up at zero (a missed end) would make prepare() a no-op
        if live { showPanel() }
        base = isOpen ? 1 : 0; if base == 1 { stopVideo() }; prepare(); Touch.glog("overview prepared: live=\(live) panel=\(panel != nil) alpha=\(panel?.alphaValue ?? -1) visible=\(panel?.isVisible ?? false) moving=\(moving)")
    }
    func gestureMoved(_ dy: Float) {
        if !live { base = 0; prepare() }          // something else closed it under the fingers: the gesture shows it again
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { progress = min(1, max(0, base + CGFloat(dy) / 0.16)) }      // 0.16 pad heights of travel for the whole morph
    }
    /// The workspace swipe's rule: a quick swipe (under 0.6 s, 1.3 % of the pad) or a long one (past half the morph's travel) goes;
    /// anything else springs back.
    func gestureEnded(dy: Float, held: Double) {
        if !live, dy > 0 { base = 0; prepare() }
        let goes = (held < 0.6 && abs(dy) >= 0.013) || abs(dy) >= 0.08
        Touch.glog("overview gesture ended: goes=\(goes) dy=\(dy) base=\(base) -> \(goes ? (dy > 0 ? "open" : "close") : "spring back")")
        let target: CGFloat = goes ? (dy > 0 ? 1 : 0) : base
        if target == 0 { query = ""; selected = nil; hoverWin = nil }
        animate(to: target)
    }

    // MARK: actions

    func go(space n: Int) { WM.shared?.focus(space: n); close(to: n, quick: true) }
    func go(window w: WinInfo) { WM.shared?.focus(window: w.id); close(to: w.space, quick: true); centerCursor(on: w.id) }

    /// Puts the pointer in the middle of a window once it is really there: the workspace switch and the WM's slide take a moment, so the
    /// window server is asked every 60 ms until the window is on the screen and has stopped moving (or about 1.5 s have passed).
    func centerCursor(on id: Int, last: CGRect? = nil, tries: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, tries < 25 else { return }
            var rect: CGRect?
            if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
               let b = list.first?[kCGWindowBounds as String] as? NSDictionary { rect = CGRect(dictionaryRepresentation: b as CFDictionary) }
            let screen = CGRect(origin: .zero, size: self.screen)
            if let r = rect, !r.isEmpty, screen.intersection(r).width * screen.intersection(r).height >= 0.5 * r.width * r.height,
               let l = last, abs(l.minX - r.minX) < 1, abs(l.minY - r.minY) < 1, abs(l.width - r.width) < 1 {
                CGWarpMouseCursorPosition(CGPoint(x: r.midX, y: r.midY))
                return
            }
            self.centerCursor(on: id, last: rect, tries: tries + 1)
        }
    }
    func goNew() {
        let n = (store.spaces.last?.id ?? 0) + 1
        WM.shared?.focus(space: n); close(quick: true)
    }

    func matches(_ w: WinInfo) -> Bool? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? nil : (w.title + " " + w.app).lowercased().contains(q)
    }

    /// Keys while open: Esc clears the find field, then closes; arrows move the selection; Enter goes (the first match while finding);
    /// digits jump straight to a workspace while nothing is typed; any other character finds.
    func key(_ e: NSEvent) -> Bool {
        switch Int(e.keyCode) {
        case kVK_Escape: if !query.isEmpty { query = "" } else { close() }
        case kVK_Return, kVK_ANSI_KeypadEnter: enter()
        case kVK_LeftArrow: step(-1)
        case kVK_RightArrow: step(1)
        case kVK_Delete: if !query.isEmpty { query.removeLast() }
        default:
            guard e.modifierFlags.intersection([.command, .control]).isEmpty, let c = e.characters, !c.isEmpty,
                  c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            if query.isEmpty, let n = Int(c), store.spaces.contains(where: { $0.id == n }) { go(space: n); return true }
            query += c
        }
        return true
    }

    private func enter() {
        if !query.isEmpty {
            let order = store.spaces.map(\.id)
            if let hit = store.windows.filter({ matches($0) == true }).min(by: { (order.firstIndex(of: $0.space) ?? 99) < (order.firstIndex(of: $1.space) ?? 99) }) { go(window: hit) }
            return
        }
        go(space: selected ?? origin)
    }

    private func step(_ d: Int) {
        let ids = store.spaces.map(\.id)
        guard let i = ids.firstIndex(of: selected ?? origin) else { return }
        selected = ids[min(max(i + d, 0), ids.count - 1)]
    }

    /// Every window of workspace `n` with where to draw it: its last known frame, or a place worked out from its size; floating ones last.
    func placed(space n: Int, windows: [WinInfo]) -> [Placed] {
        let geo = WM.shared?.windowFrames() ?? [:]      // live: a drop shows in its new workspace at once
        let shown = store.spaces.first { $0.id == n }?.focused ?? false
        var known: [Placed] = [], unknown: [(WinInfo, CGSize, Bool)] = []
        for w in windows where w.space == n {
            let g = geo[w.id]
            if shown, let r = liveRects[w.id] { known.append(Placed(win: w, rect: r, floating: g?.floating ?? false)) }
            else if !shown, let p = pending[w.id], p.space == n { known.append(Placed(win: w, rect: p.rect, floating: g?.floating ?? false, settled: false)) }
            else if let g, g.placed { known.append(Placed(win: w, rect: g.rect, floating: g.floating)) }
            else if g?.floating == true, let sz = g?.rect.size {        // floating, place unknown: centred, as macOS opens it
                let a = OverviewLayout.workArea(screen)
                known.append(Placed(win: w, rect: CGRect(x: a.midX - sz.width / 2, y: a.midY - sz.height / 2, width: sz.width, height: sz.height), floating: true))
            }
            else { unknown.append((w, g?.rect.size ?? CGSize(width: 1100, height: 1367), false)) }
        }
        let all = known + OverviewLayout.place(unknown, around: known.filter { !$0.floating }.map(\.rect), in: OverviewLayout.workArea(screen))
        return all.filter { !$0.floating } + all.filter(\.floating)
    }

    // MARK: pointer
    // One transparent layer over the whole overview maps the pointer onto the tiles here. SwiftUI's own hover and hit areas ignore
    // the miniatures' scaling (they stay where a window would be at full size), so windows low in a column could not be reached.

    enum Hit { case window(WinInfo), tile(Int), slot, nothing }
    /// A window being carried: where the pointer is, where on the window it was picked up, and what it would land on.
    struct Drag { let win: WinInfo; var at: CGPoint; let grab: CGSize; var target: Int?; var toNew: Bool }

    var layout: OverviewLayout { OverviewLayout(count: store.spaces.count, screen: screen) }

    func hit(_ pt: CGPoint) -> Hit {
        let L = layout
        for (i, sp) in store.spaces.enumerated() where i < L.tiles.count && L.tiles[i].contains(pt) {
            let t = L.tiles[i], k = L.scale
            let local = CGPoint(x: (pt.x - t.minX) / k, y: (pt.y - t.minY) / k)
            if let w = placed(space: sp.id, windows: store.windows).last(where: { $0.rect.contains(local) }) { return .window(w.win) }   // topmost first
            return .tile(sp.id)
        }
        return L.slot.contains(pt) ? .slot : .nothing
    }

    /// A window's rect on screen, inside its tile.
    func screenRect(of id: Int) -> CGRect? {
        let L = layout
        guard let w = store.windows.first(where: { $0.id == id }), let i = store.spaces.firstIndex(where: { $0.id == w.space }), i < L.tiles.count,
              let item = placed(space: w.space, windows: store.windows).first(where: { $0.win.id == id }) else { return nil }
        let t = L.tiles[i], k = L.scale
        return CGRect(x: t.minX + item.rect.minX * k, y: t.minY + item.rect.minY * k, width: item.rect.width * k, height: item.rect.height * k)
    }

    func pointerMoved(_ pt: CGPoint?) {
        guard drag == nil else { return }
        var id: Int? = nil
        if let pt, case .window(let w) = hit(pt) { id = w.id }
        if hoverWin != id { hoverWin = id }
    }

    /// A press that travels 6 pt from a window picks it up; then it follows the pointer and the tile under it is the target.
    var dragEvents = 0, slowestDrag = 0.0      // debug (overview-state)
    func pointerDragged(start: CGPoint, at pt: CGPoint) {
        let t0 = CACurrentMediaTime(); dragEvents += 1
        defer { slowestDrag = max(slowestDrag, CACurrentMediaTime() - t0) }
        if drag == nil {
            guard hypot(pt.x - start.x, pt.y - start.y) > 6, case .window(let w) = hit(start), let r = screenRect(of: w.id) else { return }
            drag = Drag(win: w, at: pt, grab: CGSize(width: start.x - r.minX, height: start.y - r.minY), target: nil, toNew: false)
            hoverWin = nil
        }
        var target: Int? = nil, toNew = false
        switch hit(pt) {
        case .window(let w): target = w.space
        case .tile(let n): target = n
        case .slot: toNew = true
        case .nothing: break
        }
        drag?.at = pt; drag?.target = target; drag?.toNew = toNew
    }

    /// Release: a carried window moves to the workspace under it (the overview stays open, so you see it land); a plain click goes.
    func pointerUp(start: CGPoint, at pt: CGPoint) {
        if let d = drag {
            drag = nil
            if d.toNew {
                drag = d; predictMove(d.win, to: store.spaces.count + 1); drag = nil
                WM.shared?.moveToNewSpace(window: d.win.id, after: store.spaces.count)
            } else if let t = d.target, t != d.win.space {
                drag = d; predictMove(d.win, to: t); drag = nil         // predictions read the carried window's state
                WM.shared?.move(window: d.win.id, toSpace: t)
            }
            return
        }
        switch hit(start) {
        case .window(let w): go(window: w)
        case .tile(let n): go(space: n)
        case .slot: goNew()
        case .nothing: close()
        }
    }

    /// Where dwindle should put a window dropped on workspace `n`: half of that workspace's most recently focused tiled window, split
    /// across its longer side (the newcomer right of it or below it), or the whole work area when the workspace is empty.
    func dropRect(into n: Int) -> CGRect { insertion(into: n).new }

    /// dwindle's insertion on workspace `n`: the most recently focused tiled window is split across its longer side, keeping the first
    /// half; the newcomer takes the second (right of it or below it). An empty workspace gives it the whole work area. A floating
    /// window keeps its own place and size.
    func insertion(into n: Int) -> (new: CGRect, anchor: Int?, kept: CGRect?) {
        let geo = WM.shared?.windowFrames() ?? [:]
        if let d = drag, geo[d.win.id]?.floating == true,
           let r = placed(space: d.win.space, windows: store.windows).first(where: { $0.win.id == d.win.id })?.rect { return (r, nil, nil) }
        let tiled = placed(space: n, windows: store.windows).filter { !$0.floating && $0.win.id != drag?.win.id }
        guard let anchor = tiled.min(by: { (geo[$0.win.id]?.rank ?? 99) < (geo[$1.win.id]?.rank ?? 99) }) else { return (OverviewLayout.workArea(screen), nil, nil) }
        let r = anchor.rect, g: CGFloat = 3.5
        if r.width >= r.height {
            return (CGRect(x: r.midX + g, y: r.minY, width: r.width / 2 - g, height: r.height), anchor.win.id,
                    CGRect(x: r.minX, y: r.minY, width: r.width / 2 - g, height: r.height))
        }
        return (CGRect(x: r.minX, y: r.midY + g, width: r.width, height: r.height / 2 - g), anchor.win.id,
                CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2 - g))
    }

    /// dwindle's removal on workspace `n`: the windows on one side of the gap that span exactly its edge (its sibling: one window, or a
    /// split of several) grow over it. Sides are tried left, top, right, bottom.
    private func removal(of id: Int, from n: Int) -> [Int: CGRect] {
        let items = placed(space: n, windows: store.windows).filter { !$0.floating }
        guard let gone = items.first(where: { $0.win.id == id })?.rect else { return [:] }
        let rest = items.filter { $0.win.id != id }, tol: CGFloat = 3, gap: CGFloat = 12
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tol }
        // side: windows touching the gap there, all within its span, together covering it end to end
        func side(_ touches: (CGRect) -> Bool, _ inSpan: (CGRect) -> Bool, _ lo: (CGRect) -> CGFloat, _ hi: (CGRect) -> CGFloat,
                  _ spanLo: CGFloat, _ spanHi: CGFloat, _ grow: (CGRect) -> CGRect) -> [Int: CGRect]? {
            let g = rest.filter { touches($0.rect) && inSpan($0.rect) }
            guard !g.isEmpty, near(g.map { lo($0.rect) }.min()!, spanLo), near(g.map { hi($0.rect) }.max()!, spanHi) else { return nil }
            return Dictionary(uniqueKeysWithValues: g.map { ($0.win.id, grow($0.rect)) })
        }
        let r = gone
        return side({ $0.maxX <= r.minX && r.minX - $0.maxX < gap }, { $0.minY >= r.minY - tol && $0.maxY <= r.maxY + tol }, { $0.minY }, { $0.maxY }, r.minY, r.maxY,
                    { CGRect(x: $0.minX, y: $0.minY, width: r.maxX - $0.minX, height: $0.height) })            // left neighbours grow right
            ?? side({ $0.maxY <= r.minY && r.minY - $0.maxY < gap }, { $0.minX >= r.minX - tol && $0.maxX <= r.maxX + tol }, { $0.minX }, { $0.maxX }, r.minX, r.maxX,
                    { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: r.maxY - $0.minY) })           // above grow down
            ?? side({ $0.minX >= r.maxX && $0.minX - r.maxX < gap }, { $0.minY >= r.minY - tol && $0.maxY <= r.maxY + tol }, { $0.minY }, { $0.maxY }, r.minY, r.maxY,
                    { CGRect(x: r.minX, y: $0.minY, width: $0.maxX - r.minX, height: $0.height) })            // right grow left
            ?? side({ $0.minY >= r.maxY && $0.minY - r.maxY < gap }, { $0.minX >= r.minX - tol && $0.maxX <= r.maxX + tol }, { $0.minX }, { $0.maxX }, r.minX, r.maxX,
                    { CGRect(x: $0.minX, y: r.minY, width: $0.width, height: $0.maxY - r.minY) })             // below grow up
            ?? [:]
    }

    /// Before a move: predict both hidden workspaces' layouts (a shown one gets the WM's real frames within a moment).
    private func predictMove(_ w: WinInfo, to t: Int) {
        let shown = Set(store.spaces.filter(\.focused).map(\.id))
        var next = pending.filter { $0.key != w.id }
        if !shown.contains(w.space) { for (id, r) in removal(of: w.id, from: w.space) { next[id] = (w.space, r) } }
        let ins = insertion(into: t)
        if !shown.contains(t) {
            next[w.id] = (t, ins.new)
            if let a = ins.anchor, let k = ins.kept { next[a] = (t, k) }
        }
        let on = { (n: Int) in Set(store.windows.filter { $0.space == n }.map(\.id)) }
        expected[w.space] = (on(w.space).subtracting([w.id]), false)
        expected[t] = (on(t).union([w.id]), false)
        pending = next
    }

    // MARK: life cycle

    private func prepare() {
        guard !live else { return }
        origin = store.spaces.first { $0.focused }?.id ?? store.spaces.first?.id ?? 1
        bars = snapshotBars?() ?? []
        Overview.refreshWallpaper(&wallpaper, stamp: &wallpaperStamp)
        let p = panel ?? makePanel()
        panel = p
        p.alphaValue = 1; p.ignoresMouseEvents = false
        p.orderFrontRegardless()
        p.makeKey()
        let ids = Set(store.windows.map(\.id))
        cache = cache.filter { ids.contains($0.key) }
        thumbs = cache
        live = true
        arm()
        capture(sharp: true)
        track()
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.track() }
        RunLoop.main.add(t, forMode: .common)          // .common: it keeps running while a drag is tracking the mouse
        tracker = t
    }

    /// The shown workspace's windows as the window server has them now (no permission needed for bounds; ~1 ms).
    private func track() {
        let shown = Set(store.spaces.filter(\.focused).map(\.id))
        let ids = Set(store.windows.filter { shown.contains($0.space) }.map(\.id))
        var r: [Int: CGRect] = [:]
        if !ids.isEmpty, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard let id = w[kCGWindowNumber as String] as? Int, ids.contains(id), let b = w[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
                r[id] = rect
            }
        }
        guard r != liveRects else { return }
        liveRects = r
        for (id, rect) in r { video.resize(id, to: rect.size) }
    }

    /// Open: every window streams at 24 fps, about twice its tile's size (the current workspace's sharper: the close morph grows it).
    private func startVideo() {
        guard live, Capture.allowed else { return }
        let small = min(1, layout.scale * 2.4)
        var want: [Int: CGFloat] = [:]
        for w in store.windows { want[w.id] = w.space == origin ? max(small, 0.6) : small }
        feedScale = want
        video.start(want, fps: 24) { [weak self] id, img in
            guard let self, self.live, !self.moving else { return }      // a frame that lands while the tiles move would redraw them for nothing
            self.feed(id).image = img
        }
    }

    /// Closing (or a swipe down begins): the video stops; the last frames become the small copies kept for the next opening.
    private func stopVideo() {
        let small = min(1, layout.scale * 2.4)
        let last = feeds.compactMap { id, f in f.image.map { (id, $0, feedScale[id] ?? small) } }
        video.stop()
        // the small copies are made off the main thread (a closing morph needs every frame it can get)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let made = last.map { ($0.0, $0.2 > small ? Overview.scaled($0.1, by: small / $0.2) : NSImage(cgImage: $0.1, size: .zero)) }
            DispatchQueue.main.async { for (id, img) in made { self?.cache[id] = img } }
        }
    }

    /// Each animation gets a number; whichever of the two finishers (SwiftUI's completion, or the timed fallback) comes first runs the
    /// end of it, once. SwiftUI does not always call the completion (measured: not after a click that also changed the origin), and a
    /// missed one would leave the panel on the screen over the windows.
    private var animationID = 0
    /// Fully visible and clickable again; also cancels a fade that is running (an animated set to 1 replaces it).
    private func showPanel() {
        guard let p = panel else { return }
        p.ignoresMouseEvents = false
        NSAnimationContext.runAnimationGroup { c in c.duration = 0; p.animator().alphaValue = 1 }
        p.alphaValue = 1
    }

    /// `quick`: you chose something and the WM is already switching underneath, so the morph is short.
    private func animate(to t: CGFloat, quick: Bool = false) {
        if t < 1 { stopVideo() }
        moving = true
        animationID += 1
        let id = animationID
        if t == 1 { showPanel() }                                  // opening always ends with a visible panel, whatever came before
        if t == 0, quick, let p = panel { fadeOut(p, id); return }
        withAnimation(.spring(duration: quick ? 0.22 : 0.34, bounce: quick ? 0 : 0.04), completionCriteria: .logicallyComplete) { progress = t } completion: { [weak self] in
            self?.finish(t, id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (quick ? 0.4 : 0.6)) { [weak self] in self?.finish(t, id) }
    }

    /// Choosing something: the WM is already switching underneath, so the overview just fades away (a window-server fade of the panel, no
    /// SwiftUI work per frame) and the real window shows at once, as it does when a card closes. No zoom into a soft capture.
    private func fadeOut(_ p: NSPanel, _ id: Int) {
        p.ignoresMouseEvents = true
        let end: () -> Void = { [weak self] in
            guard let self, id == self.animationID, self.moving else { return }
            var tr = Transaction(); tr.disablesAnimations = true
            withTransaction(tr) { self.progress = 0 }          // the panel is already clear: nothing to see
            self.finish(0, id)
        }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12; c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 0
        }, completionHandler: end)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: end)
    }

    private func finish(_ t: CGFloat, _ id: Int) {
        guard id == animationID, moving else { return }       // a newer animation owns the end now, or this one already ended
        moving = false
        if !held.isEmpty { for (k, img) in held { thumbs[k] = img }; held = [:] }
        if t == 1, progress == 1 { startVideo() }
        if t == 0, progress == 0 { teardown() }
    }

    private func teardown() {
        panel?.alphaValue = 0          // gone at once; the window itself is taken off the screen a turn later
        live = false
        tracker?.invalidate(); tracker = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        // the panel is already off the screen; the state is cleared on the next turn so the last frame of the morph is not held up by it
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.live else { return }
            self.panel?.orderOut(nil)
            self.panel?.alphaValue = 1
            self.stopVideo()
            self.liveRects = [:]
            self.thumbs = [:]; self.bars = []; self.hoverWin = nil; self.drag = nil
            self.feeds = [:]; self.stills = [:]; self.held = [:]; self.moving = false
        }
    }

    /// Every window at about twice its tile size; with `sharp`, the current workspace's at half Retina instead (they fill the screen at
    /// the start of the morph). Each arrival also refreshes the small copy kept for the next opening.
    private func capture(sharp: Bool) {
        guard live else { return }
        guard Capture.allowed else { Capture.askOnce(); return }
        let small = min(1, OverviewLayout(count: store.spaces.count, screen: screen).scale * 2.4)
        var want: [Int: CGFloat] = [:]
        for w in store.windows { want[w.id] = sharp && w.space == origin ? 1.0 : small }
        Capture.windows(want) { [weak self] id, img in
            guard let self, self.live else { return }
            let k = want[id] ?? small
            self.cache[id] = k > small ? Overview.scaled(img, by: small / k) : NSImage(cgImage: img, size: .zero)
            let shot = NSImage(cgImage: img, size: .zero)
            // while the morph runs only the morphing workspace's pictures are drawn at once; the rest wait for it to land (a publish
            // redraws every tile, and the tiles are still moving)
            if self.moving, store.windows.first(where: { $0.id == id })?.space != self.origin { self.held[id] = shot } else { self.thumbs[id] = shot }
        }
    }

    /// The workspace the rail is heading for: the focus plus unconfirmed and live swipe travel, rounded to a slot.
    static func swipeTarget() -> Int? {
        guard let f = store.focusedIndex, !store.spaces.isEmpty else { return nil }
        let i = min(max(Int((Double(f) + store.rail.swipe).rounded()), 0), store.spaces.count - 1)
        return store.spaces[i].id
    }

    /// Fresh small pictures of one workspace's windows (it was just shown, so its windows have their real layout).
    private func refresh(space n: Int) {
        guard Capture.allowed else { return }
        let small = min(1, layout.scale * 2.4)
        var want: [Int: CGFloat] = [:]
        for w in store.windows where w.space == n { want[w.id] = small }
        Capture.windows(want) { [weak self] id, img in
            guard let self, self.live else { return }
            let shot = NSImage(cgImage: img, size: .zero)
            self.cache[id] = shot
            if self.feeds[id]?.image == nil { self.thumbs[id] = shot }
        }
    }

    /// The pending card's backdrop: the window's last picture blurred once (Core Image), not on every frame.
    private var stills: [Int: NSImage] = [:]
    private let ci = CIContext(options: [.cacheIntermediates: false])
    func still(_ id: Int) -> NSImage? {
        if let s = stills[id] { return s }
        let src = feeds[id]?.image ?? (cache[id] ?? thumbs[id]).flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard let src else { return nil }
        let img = CIImage(cgImage: src)
        guard let f = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: img.clampedToExtent(), kCIInputRadiusKey: 14]),
              let out = f.outputImage?.cropped(to: img.extent), let cg = ci.createCGImage(out, from: img.extent) else { return nil }
        let s = NSImage(cgImage: cg, size: .zero)
        stills[id] = s
        return s
    }

    private static func scaled(_ img: CGImage, by f: CGFloat) -> NSImage {
        let w = max(2, Int(CGFloat(img.width) * f)), h = max(2, Int(CGFloat(img.height) * f))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage(cgImage: img, size: .zero) }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().map { NSImage(cgImage: $0, size: .zero) } ?? NSImage(cgImage: img, size: .zero)
    }

    /// Middle-click closes the window under the pointer.
    private func arm() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] e in
            if e.buttonNumber == 2, let self, let id = self.hoverWin { WM.shared?.close(window: id); return nil }
            return e
        } as Any)
    }

    private func makePanel() -> OverviewPanel {
        let f = Display.current.frame
        let p = OverviewPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = NSWindow.Level(rawValue: lifted ? overviewLiftLevel : barBaseLevel - 1)      // over every window, under the bars (they stay in place around it)
        p.collectionBehavior = [.ignoresCycle]
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.contentView = NSHostingView(rootView: AnyView(ThemeRoot(content: OverviewView().environmentObject(store))))
        p.setFrame(f, display: false)
        Sky.pin([p])
        return p
    }

    /// Decodes the picture again only when its file or its modification date changed since the last opening.
    static func refreshWallpaper(_ img: inout NSImage?, stamp: inout String) {
        guard let scr = NSScreen.main, let url = ProcessInfo.processInfo.environment["RISKELL_WALLPAPER"].map({ URL(fileURLWithPath: $0) }) ?? NSWorkspace.shared.desktopImageURL(for: scr) else { return }
        let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let s = "\(url.path)|\(m)"
        if img == nil || s != stamp { img = loadWallpaper(); stamp = s }
    }

    /// The desktop picture, decoded at half size (tiles are small; the morph's first frames are mostly windows).
    static func loadWallpaper() -> NSImage? {
        // RISKELL_WALLPAPER (a test hook for screenshots) stands in for the desktop picture, so a picture of the overview shows no one's own
        let override = ProcessInfo.processInfo.environment["RISKELL_WALLPAPER"].map { URL(fileURLWithPath: $0) }
        guard let scr = NSScreen.main, let url = override ?? NSWorkspace.shared.desktopImageURL(for: scr), let src = NSImage(contentsOf: url) else { return nil }
        let size = CGSize(width: scr.frame.width / 2, height: scr.frame.height / 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = max(size.width / src.size.width, size.height / src.size.height)          // aspect fill
        let d = CGSize(width: src.size.width * s, height: src.size.height * s)
        src.draw(in: CGRect(x: (size.width - d.width) / 2, y: (size.height - d.height) / 2, width: d.width, height: d.height))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: size); img.addRepresentation(rep)
        return img
    }
}

final class LiveFeed: ObservableObject {
    @Published var image: CGImage?
}

final class OverviewPointer: ObservableObject {
    @Published var hoverWin: Int? = nil
    @Published var drag: Overview.Drag? = nil
}

final class OverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }      // the keyboard, without activating riskell
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func keyDown(with e: NSEvent) { if !Overview.shared.key(e) { super.keyDown(with: e) } }
}

/// Debug (the `overview-bench` socket command): records the display link's ticks while the overview opens and closes once and logs the
/// frame gaps. The link fires on the main thread, so a gap well over the frame time is a hitch of the main thread (layout, image work).
final class FrameProbe: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private static var current: FrameProbe?
    @objc private func tick(_ l: CADisplayLink) { stamps.append(l.timestamp) }

    static func bench() {
        guard let screen = NSScreen.main else { return }
        let p = FrameProbe(); current = p
        p.link = screen.displayLink(target: p, selector: #selector(tick(_:)))
        p.link?.add(to: .main, forMode: .common)
        func report(_ name: String) {
            let s = p.stamps; p.stamps = []
            guard s.count > 2 else { print("bench \(name): no frames"); fflush(stdout); return }
            let gaps = zip(s.dropFirst(), s).map { ($0 - $1) * 1000 }
            let nominal = gaps.sorted()[gaps.count / 2]
            let t0 = s[0]
            let where_ = zip(s.dropFirst(), s).filter { ($0 - $1) * 1000 > 12 }.map { String(format: "%.0f@%.0f", ($0 - $1) * 1000, ($1 - t0) * 1000) }.joined(separator: " ")
            print("bench \(name) gaps (ms@t): \(where_)")
            print(String(format: "bench %@: %d frames, median %.1f ms, worst %.1f ms, %d gaps over 1.5x", name, s.count, nominal, gaps.max() ?? 0, gaps.filter { $0 > nominal * 1.5 }.count)); fflush(stdout)
        }
        Overview.shared.open()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            report("open")
            Overview.shared.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { report("close"); p.link?.invalidate(); current = nil }
        }
    }
}
