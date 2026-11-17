import Foundation

struct SpaceInfo: Identifiable, Equatable {
    let id: Int              // workspace number (OmniWM workspace number)
    var sid: UInt64 = 0      // SkyLight space id (what the system reports as the active space)
    var focused: Bool
    var visible: Bool
    var windows: Int
    var fullscreen: Bool
}

/// Everything the bars draw. Services write it on the main queue; each setter ignores an unchanged value so a redundant
/// event never republishes (and never re-renders).
struct MediaReading: Equatable { var bundle: String; var playing: Bool }
/// One window on the bar's display (the workspaces atom and its card).
struct WinInfo: Equatable, Identifiable { let id: Int; var pid: Int; var app: String; var title: String; var space: Int; var focused: Bool }

/// The rail's swipe state on its own: it changes every touch frame, and only the workspace rail draws it, so it must not republish the
/// whole Store (which would redraw every atom on the bar at the trackpad's rate).
final class RailModel: ObservableObject {
    @Published fileprivate(set) var swipe: Double = 0
    @Published fileprivate(set) var live = false
}

final class Store: ObservableObject {
    @Published private(set) var spaces: [SpaceInfo] = []
    /// How far the workspace capsule sits from the focused space, in slots (+ = towards later spaces): `pending` swipes that were
    /// committed on lift but not yet confirmed by macOS (it takes ~1 s, so back-to-back swipes stack up), plus the live finger travel.
    private(set) var swipe: Double = 0
    let rail = RailModel()
    private(set) var swipeLive = false        // fingers on the pad: follow them with no animation
    @Published private(set) var media: MediaReading? = nil
    @Published private(set) var batPct: Int? = nil       // nil: no battery
    @Published private(set) var onAC = false
    @Published private(set) var charging = false
    @Published private(set) var windows: [WinInfo] = []
    @Published private(set) var volume = 0               // %
    @Published private(set) var muted = false

    var trace: ((String) -> Void)?       // diagnostics hook (main.swift sets it to tlog)
    private var queue: [Int] = []          // committed-on-lift swipes macOS has not confirmed yet, oldest first (+1 / -1)
    var pending: Int { queue.reduce(0, +) }
    private var liveSlots = 0.0
    private func publishSwipe(live: Bool) {
        let v = Double(pending) + liveSlots
        if v != swipe { swipe = v; rail.swipe = v }
        if live != swipeLive { swipeLive = live; rail.live = live }
    }
    func swipeMove(slots: Double) { liveSlots = slots; publishSwipe(live: true) }                 // fingers down
    func swipeRelease(commit dir: Int) { liveSlots = 0; if dir != 0 { queue.append(dir) }; publishSwipe(live: false) }  // fingers up: +1/-1, or 0 to cancel
    func swipeClear() { liveSlots = 0; queue.removeAll(); publishSwipe(live: false) }
    var focusedIndex: Int? { spaces.firstIndex { $0.focused } }
    /// The one path for every change of the spaces list, so a change of FOCUS is always seen: a confirmed move uses up the oldest
    /// unconfirmed swipe (the capsule must not move twice); anything else (keyboard, a jump of several) clears them.
    func set(spaces v: [SpaceInfo]) {
        let old = focusedIndex
        if v != spaces { spaces = v }
        if let old, let new = focusedIndex, new != old {
            let d = new - old
            trace?("focus \(old + 1) -> \(new + 1), unconfirmed swipes before: \(queue)")
            if abs(d) == 1, queue.first == d { queue.removeFirst() } else { queue.removeAll() }
            publishSwipe(live: swipeLive)
        }
    }
    /// Mark a space focused before the window manager has confirmed it (a click, or the system's active Space). Returns false if unknown.
    @discardableResult
    func focusNow(sid: UInt64) -> Bool {
        guard let sp = spaces.first(where: { $0.sid == sid }) else { return false }
        return focusNow(space: sp.id)
    }
    @discardableResult
    func focusNow(space id: Int) -> Bool {
        guard spaces.contains(where: { $0.id == id }) else { return false }
        set(spaces: spaces.map { var s = $0; s.focused = ($0.id == id); s.visible = s.focused; return s })
        return true
    }
    func set(battery pct: Int?, onAC ac: Bool, charging ch: Bool) {
        if pct != batPct { batPct = pct }; if ac != onAC { onAC = ac }; if ch != charging { charging = ch }
    }
    func set(media m: MediaReading?) { if m != media { media = m } }
    func set(windows w: [WinInfo]) { if w != windows { windows = w } }
    func set(volume v: Int, muted m: Bool) { if v != volume { volume = v }; if m != muted { muted = m } }

    func dump() -> String {
        let sp = spaces.map { "\($0.id)\($0.focused ? "*" : "")(\($0.windows))" }.joined(separator: " ")
        return "spaces \(sp) | bat \(batPct.map(String.init) ?? "-")% ac=\(onAC) charging=\(charging) | vol \(volume)% muted=\(muted)"
    }
}
