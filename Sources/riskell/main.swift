import AppKit
import Carbon.HIToolbox
import SwiftUI
import Combine
import RiskellKit
import WeatherExt
import SystemExt

// riskell: the bars. usage: riskell [--snap DIR] [--stay SECONDS] [--dump]
//   --trace     log timestamped space-change sources (window manager, NSWorkspace, SkyLight events)
//   (no flags)  run until killed          --dump  print what the providers read, then exit (no windows)
//   --snap DIR  write left/top/bottom.png --stay N  quit after N seconds

setvbuf(stdout, nil, _IOLBF, 0)      // the log file gets each line as it is printed
var sigSources: [DispatchSourceSignal] = []
let t0 = DispatchTime.now().uptimeNanoseconds
var tracing = false
func tlog(_ s: String) { if tracing { print(String(format: "[+%6.0f ms] ", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) + s); fflush(stdout) } }
let args = Array(CommandLine.arguments.dropFirst())
// the kit reads these: the theme in force, the corner radius, the popout host and the feeds (before anything draws or is checked)
Theme.current = Theme.loadInitial()
G.corner = { Spacing.current.corner }
KitHost.popout = PopoutBridge.shared
KitHost.app = AppBridge.shared
KitHost.feeds = FeedBridge.shared
InstanceLock.selfTest(args)      // --lock-test hold|try <file>: the lock logic alone
if args.contains("--check-fit") { CheckFit.run() }      // the wings on each fake display, PASS / FAIL, exit 1 on FAIL (WingFit.swift)
if args.contains("--key-test") { exit(SettingsPanel.keyTest() ? 0 : 1) }      // the editor's close keys, PASS / FAIL per case, then exit
if args.contains("--check-panel") { exit(SettingsPanel.checkPanel() ? 0 : 1) }      // the editor panel's real size and place at each scale and screen, then exit
if args.contains("--list-atoms") {      // JSON: each built-in atom with its card and the services its placement starts (listings/ is checked against this)
    let rows = Registry.builtinIDs.compactMap { id in Registry.byID[id].map { ["id": id, "name": $0.name, "card": $0.card?.id ?? "", "services": Needs.services(for: id)] as [String: Any] } }
    print(String(decoding: (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])) ?? Data(), as: UTF8.self)); exit(0)
}
if args.contains("--ext-selftest") { ExtSelfTest.run() }      // the preferences card's writes and the live rebuild (needs RISKELL_CONFIG at a scratch config)
if args.contains("--weather-selftest") { WeatherExt.WeatherSelfTest.run() }      // the fast forecast parser against the first version, on synthetic data
if args.contains("--list-themes") { print(Theme.listJSON()); exit(0) }      // JSON of every scheme with its resolved tokens (the installer previews them)
if args.contains("--check-themes") { if args.contains("tokens") { Theme.dumpTokens() } else { Theme.check() }; exit(0) }      // contrast of every scheme against its floors, then exit
if GestureConflicts.runCommand(args) { exit(0) }      // --gestures-fix / --gestures-restore (--yes writes): the consented trackpad and Dock writes, then exit
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
InstanceLock.acquireOrExit(args)      // one riskell runs the bars; a second full instance would fight it over the window manager's gaps, the socket and the trackpad

let store = Store()
let events = EventSocket()
store.trace = { tlog($0) }
// the window manager, chosen by config (OmniWM reconnects every 2 s while its socket is not there yet)
let wm: WindowManager = WM.make(store: store)
WM.shared = wm
let sys = Sys(store: store)
let spaceWatch = SpaceWatch(store: store, wm: wm)
let nowPlaying = NowPlaying()
tracing = args.contains("--trace")
Compat.fake = args.contains("--fake-compat")

/// Below the menu bar's level AppKit pushes a window down out of the menu bar's strip; the bars must sit exactly where they are put.
final class BarPanel: NSPanel {
    /// The settings panel takes keys while it is open (a non-activating panel can, without activating the app), so Esc and q close it.
    var takesKeys = false
    override var canBecomeKey: Bool { takesKeys }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func keyDown(with event: NSEvent) {
        if takesKeys, SettingsPanel.closesEditor(keyCode: event.keyCode, modifiers: event.modifierFlags) { SettingsPanel.shared.close(); return }
        super.keyDown(with: event)
    }
}

/// The bars' level: above windows, below the menu bar (app menus, Control Center and popovers open over the bars). Popouts share it;
/// the top bar sits 3 above. Full-screen Spaces hide the bars explicitly (SpaceWatch).
let barBaseLevel = Int(CGWindowLevelForKey(.mainMenuWindow)) - 1
/// While three fingers are on the trackpad the bars are lifted above OmniWM's full-screen slide overlay (layer 1000, the screen-saver
/// level), so its workspace slide passes UNDER them; they drop back shortly after the fingers lift (`liftBars`).
let overviewLiftLevel = Int(CGWindowLevelForKey(.screenSaverWindow)) + 1      // the open overview rides above the slide overlay too, under the bars
let barLiftLevel = overviewLiftLevel + 1

func panel(_ frame: CGRect, _ view: NSView, above: Int = 1) -> NSPanel {
    let w = BarPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
    w.level = NSWindow.Level(rawValue: barBaseLevel + 1 - above)   // above: 1 = the base; the top bar passes -2 (base + 3)
    w.collectionBehavior = [.ignoresCycle]          // not .canJoinAllSpaces / .fullScreenAuxiliary: the private space does the pinning
    w.isReleasedWhenClosed = false
    w.contentView = view
    w.setFrame(frame, display: true)
    if !(view is HugStrip) { view.useDesignUnits() }      // the bar's content lays out in design units over the real-size window (Scale.swift); a strip's container draws in real points and its host inside is scaled itself
    w.orderFrontRegardless()
    return w
}

func hosting<V: View>(_ v: V) -> NSHostingView<AnyView> {
    let h = NSHostingView(rootView: AnyView(ThemeRoot(content: v.environmentObject(store))))
    h.sizingOptions = []      // riskell sets every window frame itself; the content's own size (design units) must not constrain the window
    return h
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

events.start()

Clock.shared.start()
print("window manager:", wm.name)
wm.start()
Extensions.apply(AppConfig.shared)      // the optional extensions: gestures start only when config.json says "gestures": "riskell"
if !args.contains("--dump") { Compat.shared.start() }
ConfigWatcher.shared.start()
// The built-in services run only while an atom that needs them is placed on a bar that is on (Services/Needs.swift).
Needs.register("sys", start: sys.start, stop: sys.stop)      // the battery, the volume and the microphone
Needs.begin()
if tracing { Sky.trace(1300...1460) { t in tlog("SkyLight event \(t)") } }

func shutdown() { nowPlaying.stop(); wm.stop(); events.stop(); Extensions.stopAll() }

if args.contains("--dump") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        print(store.dump()); print("services:", Needs.active.joined(separator: " ")); print("tray:", Config.shared.tray.joined(separator: " ")); if args.contains("--smc") { print(SystemDiagnostics.smc()) }; shutdown(); exit(0)
    }
    app.run()
}

let display = Display.current      // the bars' screen (Display.swift): the real one, or RISKELL_FAKE_DISPLAY
var f = display.frame      // var: a screen change re-reads it (relayout below)
print("screen", f.size, "notch", display.notchH, "scale", Scale.factor)
if CheckFit.child { print("fitcheck display scale=\(Scale.factor) notchH=\(display.notchH) band=\(Real.band)"); fflush(stdout) }

let strip = HugStrip(), rightStrip = HugStrip(right: true)
let leftHost = hosting(VBar(bar: .left)), rightHost = hosting(VBar(bar: .right))
leftHost.frame = CGRect(x: 0, y: 0, width: Real.strip, height: f.height)
rightHost.frame = CGRect(x: Real.r, y: 0, width: Real.strip, height: f.height)      // the right panel keeps Real.r of fillet room on its inside
leftHost.useDesignUnits(); rightHost.useDesignUnits()
strip.addSubview(leftHost); rightStrip.addSubview(rightHost)
let notchEdges = display.barNotch      // the notch, or a stand-in centre gap on a screen without one (Display.barNotch)
Config.shared.screenMinX = f.minX; Config.shared.notchAbs = notchEdges
let topHost = hosting(HBar(bar: .top, bandH: G.band, shiftY: G.topShift, notchAbs: notchEdges))      // the band is a design height
let bottomHost = hosting(HBar(bar: .bottom, bandH: G.band))

// tiled windows stay clear of the bars through OmniWM's own gaps, which riskell keeps in step with the bars that are on (Services/Gaps.swift)

let left = panel(CGRect(x: f.minX, y: f.minY, width: Real.strip + Real.r, height: f.height), strip)
let right = panel(CGRect(x: f.maxX - Real.strip - Real.r, y: f.minY, width: Real.strip + Real.r, height: f.height), rightStrip)
// macOS 27: MenuBarAgent keeps a transparent layer-25 window over the whole top strip that eats the pointer; the top bar sits above it too (above: -2 -> base + 3)
let top = panel(CGRect(x: f.minX, y: f.maxY - display.topInset - Real.band - Real.r, width: f.width, height: Real.band + Real.r), topHost, above: -2)
let bottom = panel(CGRect(x: f.minX, y: f.minY, width: f.width, height: Real.band + Real.r), bottomHost)
var inFullscreen = false
/// Fits the panels to the bars that are on: the top and bottom bars run between the strips, a bar that is off is invisible and takes no mouse.
func applyGeometry() {
    let c = Config.shared, lw = c.leftW, rw = c.rightW
    top.setFrame(CGRect(x: f.minX + lw, y: f.maxY - Display.current.topInset - Real.band - Real.r, width: f.width - lw - rw, height: Real.band + Real.r), display: true)
    top.contentView?.useDesignUnits()
    bottom.setFrame(CGRect(x: f.minX + lw, y: f.minY, width: f.width - lw - rw, height: Real.band + Real.r), display: true)
    bottom.contentView?.useDesignUnits()
    for (k, w) in [(BarKey.left, left), (.right, right), (.bottom, bottom)] {
        let show = c.on(k) && !inFullscreen
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; w.animator().alphaValue = show ? 1 : 0 }
        w.ignoresMouseEvents = !show
        BarActivity.shared.update(k, shown: show)
    }
    BarActivity.shared.update(.top, shown: !inFullscreen)
}
applyGeometry()
let writeGaps = !args.contains("--no-reserve") && !args.contains("--dump")      // a second instance (snapshots) must never touch OmniWM's gaps
Config.shared.onGeometry = { applyGeometry(); if writeGaps { wm.reserve(Config.shared) } }
if writeGaps { wm.reserve(Config.shared) }

/// A screen change (a monitor plugged in or out, a resolution or mode change): rebuild `Display.current` and re-fit everything that reads it.
/// Runs once, 0.3 s after the last change (the kernel posts the notification; nothing polls).
func relayout() {
    Display.refresh()
    f = Display.current.frame
    Overview.shared.displayChanged()
    Config.shared.screenMinX = f.minX; Config.shared.notchAbs = Display.current.barNotch
    leftHost.frame = CGRect(x: 0, y: 0, width: Real.strip, height: f.height)
    rightHost.frame = CGRect(x: Real.r, y: 0, width: Real.strip, height: f.height)
    leftHost.useDesignUnits(); rightHost.useDesignUnits()
    left.setFrame(CGRect(x: f.minX, y: f.minY, width: Real.strip + Real.r, height: f.height), display: true)
    right.setFrame(CGRect(x: f.maxX - Real.strip - Real.r, y: f.minY, width: Real.strip + Real.r, height: f.height), display: true)
    topHost.rootView = AnyView(ThemeRoot(content: HBar(bar: .top, bandH: G.band, shiftY: G.topShift, notchAbs: Display.current.barNotch).environmentObject(store)))
    applyGeometry()
    if writeGaps { wm.reserve(Config.shared) }
    ThemeState.shared.epoch += 1      // every hosting root rebuilds and re-reads the design values (Theme.swift)
    NotificationCenter.default.post(name: ThemeState.didChange, object: nil)
}
var screenWork: DispatchWorkItem?
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
    screenWork?.cancel()
    let w = DispatchWorkItem { relayout() }
    screenWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
}

if args.contains("--fake-media") { store.set(media: MediaReading(bundle: "app.zen-browser.zen", playing: args.contains("--fake-playing"))) } else { nowPlaying.start() }
print("pinned in private space:", Sky.pin([left, right, top, bottom]))
Config.shared.windows = [.left: left, .right: right, .top: top, .bottom: bottom]
let hugWatch = Publishers.CombineLatest3(Config.shared.$hug, Popout.shared.$open, Popout.shared.$chat).sink { strip.hug = ($0[.left] ?? true) || ($1 && !$2); rightStrip.hug = ($0[.right] ?? true) || ($1 && !$2) }      // the strip is an NSView, not SwiftUI; a flush card fills it in, a chat card leaves it alone
HotKey.register(key: kVK_ANSI_Comma, mods: controlKey | optionKey) { SettingsPanel.shared.toggle() }     // ctrl-alt-, : bar settings + edit mode
EditBackdrop.shared.start()      // the veil over the screen while editing (Sources/riskell/EditBackdrop.swift)
if args.contains("--edit") { Config.shared.editing = true }      // snapshots: edit mode on
if args.contains("--edit-test") {      // debug: the drop rules, driven through plan/apply with pointer positions taken from measured frames
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        let c = Config.shared
        func pt(_ b: BarKey, _ x: CGFloat, _ y: CGFloat) -> CGPoint { let w = c.windows[b]!.frame; return CGPoint(x: w.minX + x, y: w.maxY - y) }
        let fr = c.frames[.top] ?? [:]
        print("edit-test frames top:", fr.keys.sorted())
        if let bat = fr["atom:ext:bat"], let clk = fr["atom:ext:clock"], let isl = fr["isl:status"] {
            let before = c.plan("ext:clock", mouse: pt(.top, bat.minX + 2, bat.midY))
            print("edit-test clock -> before bat:", before.map { "\($0.0)" } ?? "nil", "island", isl)
            if let (d, _) = before { c.apply("ext:clock", d) }
            print("edit-test top end:", c.spec(.top).end.map { $0.atoms })
            _ = clk
        }
        let empty = c.plan("ext:bat", mouse: pt(.top, 900, 28)); print("edit-test bat to empty middle:", empty.map { "\($0.0)" } ?? "nil")
        if let (d, _) = empty { c.apply("ext:bat", d) }
        print("edit-test top:", c.spec(.top).start.map { $0.atoms }, c.spec(.top).end.map { $0.atoms })
        print("edit-test clock on left (illegal):", c.plan("ext:clock", mouse: pt(.left, 26, 400)) == nil ? "refused" : "ALLOWED")
        fflush(stdout)
    }
}
for b in [BarKey.left, .right, .bottom] {      // debug: printf bar-left-off | nc -U ~/.cache/riskell/ev.sock (an off bar must be empty)
    events.commands["bar-\(b.rawValue)-on"] = { Config.shared.setOn(b, true) }
    events.commands["bar-\(b.rawValue)-off"] = { Config.shared.setOn(b, false) }
}
events.commands["settings"] = { SettingsPanel.shared.toggle() }
events.commands["wm"] = { wm.requestRefresh() }      // a script says the manager's state changed (the command backend re-reads it at once)
// The top bar rides above MenuBarAgent's layer-25 window (it eats hover below that). Touching the top screen edge reveals the auto-hidden
// menu bar, so the bar steps down under it until the pointer leaves the menu bar's strip.
var barLevel = top.level      // the top bar's level away from the menu bar's strip (higher while lifted for a swipe)
let underMenu = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
func menuEdge(_ e: NSEvent?) {
    let y = NSEvent.mouseLocation.y
    if y >= f.maxY - 1.5 { if top.level != underMenu { top.level = underMenu } }
    else if y < f.maxY - 49 { let want = pipOver.contains(top) && !barsLifted ? pipLevel : barLevel; if top.level != want { top.level = want } }
}
/// A Picture-in-Picture window (layer 19) sits under the bars (layer 23+). A bar it overlaps drops to just under it, so the PiP floats over
/// the bar there; bars it does not touch stay where they are (the top bar must stay above MenuBarAgent's layer-25 window for hover).
let pipLevel = NSWindow.Level(rawValue: 18)
var pipOver = Set<NSPanel>()
/// Not a poll: a window-server query for the whole window list costs a round trip, so it runs only when a PiP window can have appeared or moved.
/// A user action starts it (an app activating, the Space changing, any click: a PiP window is opened by clicking something), it then looks every
/// 0.3 s for 2 s and for as long as a PiP window exists (to follow it as it is dragged), and otherwise only every 5 s as a safety net.
var pipWork: DispatchWorkItem?
var pipBurstUntil = Date.distantPast
func pipKick() { pipBurstUntil = Date().addingTimeInterval(2); pipSchedule(after: 0.05) }
func pipSchedule(after d: TimeInterval) {
    pipWork?.cancel()
    let w = DispatchWorkItem { let found = pipScan(); pipSchedule(after: found || Date() < pipBurstUntil ? 0.3 : 5) }
    pipWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: w)
}
/// Returns whether any PiP window is on screen.
@discardableResult func pipScan() -> Bool {
    var rects: [CGRect] = []
    for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [] {
        guard (w[kCGWindowLayer as String] as? Int ?? 0) > 3, (w[kCGWindowLayer as String] as? Int ?? 0) < barBaseLevel,
              (w[kCGWindowName as String] as? String ?? "").localizedCaseInsensitiveContains("Picture in Picture"),
              let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { continue }
        rects.append(CGRect(x: r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height))     // top-left origin -> Cocoa
    }
    let now = Set([left, right, top, bottom].filter { p in rects.contains { $0.intersects(p.frame) } })
    guard now != pipOver else { return !rects.isEmpty }
    pipOver = now
    print("pip: bars under a Picture in Picture window: \(now.map { $0 === left ? "left" : $0 === right ? "right" : $0 === top ? "top" : "bottom" }.sorted())"); fflush(stdout)
    for p in [left, right, bottom] where !barsLifted { let want = pipOver.contains(p) ? pipLevel : NSWindow.Level(rawValue: barBaseLevel); if p.level != want { p.level = want } }
    menuEdge(nil)
    return !rects.isEmpty
}
pipSchedule(after: 0.1)
if ProcessInfo.processInfo.environment["RISKELL_TEST_PIP"] != nil {      // test: a window named like a PiP window over the bottom bar for 6 s, opened with no user action
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        let w = NSWindow(contentRect: CGRect(x: f.maxX - 500, y: f.minY + 4, width: 300, height: 170), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Picture in Picture"; w.level = NSWindow.Level(rawValue: 19); w.orderFrontRegardless()
        print("pip-test: window opened"); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { w.orderOut(nil); print("pip-test: window closed"); fflush(stdout) }
    }
}
NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in pipKick() }
for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
    NSWorkspace.shared.notificationCenter.addObserver(forName: n, object: nil, queue: .main) { _ in pipKick() }
}
NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { menuEdge($0) }
NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { menuEdge($0); return $0 }
/// Lift the bars over OmniWM's slide overlay while three fingers are down, and put them back under the menu bar's level after.
var barsLifted = false
func liftBars(_ on: Bool) {
    guard on != barsLifted else { return }
    barsLifted = on
    let base = on ? barLiftLevel : barBaseLevel
    left.level = NSWindow.Level(rawValue: base); right.level = NSWindow.Level(rawValue: base); bottom.level = NSWindow.Level(rawValue: base)
    barLevel = NSWindow.Level(rawValue: base + 3)
    top.level = barLevel
    if !on { pipOver = []; pipScan() }
    menuEdge(nil)                // pointer on the menu bar's strip: the top bar goes back under it
    tlog("bars \(on ? "lifted" : "lowered")")
}

/// The overview draws riskell's own bars inside every workspace preview: snapshots of the three bar views (our windows: no Screen Recording).
func barImage(_ v: NSView) -> NSImage? {
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
    v.cacheDisplay(in: v.bounds, to: rep)
    let img = NSImage(size: v.bounds.size); img.addRepresentation(rep)
    return img
}
Overview.shared.snapshotBars = {
    let views: [(NSView, NSWindow)] = [(strip, left), (rightStrip, right), (topHost, top), (bottomHost, bottom)].filter { Config.shared.windows[$0.1 === left ? .left : $0.1 === right ? .right : $0.1 === top ? .top : .bottom] != nil && Config.shared.on($0.1 === left ? .left : $0.1 === right ? .right : $0.1 === top ? .top : .bottom) }
    return views.enumerated().compactMap { i, pair in
        guard let img = barImage(pair.0) else { return nil }
        let fr = pair.1.frame
        return BarShot(id: i, image: img, rect: CGRect(x: fr.minX - f.minX, y: f.maxY - fr.maxY, width: fr.width, height: fr.height))
    }
}
HotKey.register(key: kVK_Space, mods: controlKey | optionKey) { Overview.shared.toggle() }     // ctrl-alt-space
events.commands["overview"] = { Overview.shared.toggle() }
for n in 1...9 { events.commands["workspace-\(n)"] = { WM.shared?.focus(space: n) } }      // printf workspace-3 | nc -U ~/.cache/riskell/ev.sock: switch to workspace 3 (docs/GESTURES.md)
events.commands["screen-snap"] = { Capture.display(to: NSHomeDirectory() + "/.cache/riskell/overview-screen.png") }   // debug: the real screen
events.commands["overview-state"] = { let o = Overview.shared; print("overview-state: alpha=\(o.view?.window?.alphaValue ?? -1) level=\(o.view?.window?.level.rawValue ?? -1) live=\(o.live) origin=\(o.origin) target=\(Overview.swipeTarget().map(String.init) ?? "-") p=\(o.progress) hover=\(o.hoverWin.map(String.init) ?? "-") drag=\(o.drag.map { "\($0.win.app) at \(Int($0.at.x)),\(Int($0.at.y)) target=\($0.target.map(String.init) ?? "-") new=\($0.toNew)" } ?? "-") dragEvents=\(o.dragEvents) slowest=\(String(format: "%.1f", o.slowestDrag * 1000)) ms") }
events.commands["overview-lift"] = { liftBars(true); Overview.shared.lift(true) }      // debug: what three fingers down does
events.commands["center-focused"] = { if let w = store.windows.first(where: { $0.focused }) { Overview.shared.centerCursor(on: w.id); print("center-focused: \(w.app) id \(w.id)"); fflush(stdout) } }      // debug
events.commands["gesture-up"] = {      // debug: the overview's swipe-up gesture through the real entry points (began / moved / ended), no fingers
    let o = Overview.shared; o.gestureBegan()
    for i in 1...6 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i)) { o.gestureMoved(Float(i) * 0.02) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { o.gestureEnded(dy: 0.12, held: 0.25) }
}
events.commands["touch-reattach"] = { Touch.shared?.attach() }      // debug (only while gestures are on)
events.commands["floating-top"] = { Omni.floatingOnTop.toggle(); print("floating-top: \(Omni.floatingOnTop)"); fflush(stdout) }      // debug
events.commands["window-order"] = {      // debug: normal windows of the main display, front to back
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    let names = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.map { "\($0[kCGWindowOwnerName as String] as? String ?? "?")" }
    print("window-order (front first): \(names.joined(separator: " > "))"); fflush(stdout)
}
events.commands["compat"] = { print(Compat.shared.report); fflush(stdout) }      // debug: running vs verified versions and settings
events.commands["touch-state"] = { print("touch-state: \(Touch.state) | \(ScrollGuard.state)"); fflush(stdout) }      // debug
events.commands["scroll-guard"] = { print("scroll-guard: \(ScrollGuard.state)"); fflush(stdout) }      // debug
var focusLatencyWatch: AnyCancellable?
events.commands["focus-latency"] = {      // debug: ms from WM.focus(window:) to the store seeing that workspace focused, for a window on another workspace
    let cur = store.spaces.first { $0.focused }?.id
    guard let w = store.windows.first(where: { $0.space != cur && $0.app == "Arc" }) else { print("focus-latency: no window on another workspace"); fflush(stdout); return }
    let t0 = CACurrentMediaTime()
    focusLatencyWatch = store.$spaces.sink { sp in
        if sp.first(where: { $0.focused })?.id == w.space { print(String(format: "focus-latency: %.0f ms to workspace %d", (CACurrentMediaTime() - t0) * 1000, w.space)); fflush(stdout); focusLatencyWatch = nil }
    }
    WM.shared?.focus(window: w.id)
}
events.commands["focus-other"] = { let cur = store.spaces.first { $0.focused }?.id; if let w = store.windows.first(where: { $0.space != cur && $0.app == "Arc" }) { print("focus-other: \(w.app) ws \(w.space) id \(w.id)"); fflush(stdout); WM.shared?.focus(window: w.id) } else { print("focus-other: no window"); fflush(stdout) } }      // debug
events.commands["overview-click-other"] = {      // debug: open the overview and click (the logic, not a mouse event) a window of another workspace
    let o = Overview.shared; o.open()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        let cur = store.spaces.first { $0.focused }?.id
        guard let w = store.windows.first(where: { $0.space != cur && $0.app == "Arc" }), let r = o.screenRect(of: w.id) else { print("click-other: no window/rect"); fflush(stdout); return }
        let c = CGPoint(x: r.midX, y: r.midY)
        var hitDesc = "?"; switch o.hit(c) { case .window(let h): hitDesc = "window \(h.app) ws \(h.space)"; case .tile(let n): hitDesc = "tile \(n)"; case .slot: hitDesc = "slot"; case .nothing: hitDesc = "nothing" }
        print("click-other: target \(w.app) ws \(w.space) at \(Int(c.x)),\(Int(c.y)) hit=\(hitDesc)"); fflush(stdout)
        o.pointerUp(start: c, at: c)
    }
}
events.commands["overview-drop"] = { liftBars(false); Overview.shared.lift(false) }
events.commands["overview-bench"] = { FrameProbe.bench() }      // debug: open and close once, log the main thread's frame gaps
events.commands["overview-snap"] = {      // debug: the overview's own view to ~/.cache/riskell/overview.png
    let o = Overview.shared
    print("overview: live=\(o.live) progress=\(o.progress) capture=\(Capture.allowed) thumbs=\(o.thumbs.count) bars=\(o.bars.count) wallpaper=\(o.wallpaper != nil)")
    for sp in store.spaces { print("  ws \(sp.id): \(o.placed(space: sp.id, windows: store.windows).map { "\($0.win.app)@\(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height))" })") }
    // RISKELL_SNAP_DIR sends both pictures to a scratch folder (a test instance must not write into the user's cache)
    let dir = ProcessInfo.processInfo.environment["RISKELL_SNAP_DIR"] ?? NSHomeDirectory() + "/.cache/riskell"
    Capture.display(to: dir + "/overview-screen.png")
    if let v = Overview.shared.view, let img = barImage(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/overview.png"))
    }
}
spaceWatch.onFullscreen = { fs in
    inFullscreen = fs
    for (k, w) in [(BarKey.left, left), (.right, right), (.top, top), (.bottom, bottom)] {
        let show = !fs && Config.shared.on(k)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; w.animator().alphaValue = show ? 1 : 0 }
        w.ignoresMouseEvents = !show
        BarActivity.shared.update(k, shown: show)
    }
    tlog("fullscreen space: \(fs)")
}
spaceWatch.start()
func snap(_ v: NSView, _ name: String, _ dir: String) {
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
if let dir = opt("--snap") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { snap(strip, "left", dir); snap(rightStrip, "right", dir); snap(topHost, "top", dir); snap(bottomHost, "bottom", dir); print(store.dump()) }
}

if let hot = ProcessInfo.processInfo.environment["RISKELL_FORCE_HOT"], let dir = opt("--snap"), opt("--pop") == nil {      // test: hover <hot> through the real path, then snapshot its card and the lit bars
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(hot.split(separator: ",").count)) {
        if let v = Popout.shared.snapshotView { snap(v, "pop-\(hot.split(separator: ",").last ?? "")", dir); print("pop-frame", hot, v.window?.frame ?? .zero, "floatY", Popout.shared.floatY, "screen", f); fflush(stdout) }
        snap(strip, "left-lit", dir); snap(topHost, "top-lit", dir); snap(bottomHost, "bottom-lit", dir)
    }
}
if args.contains("--settings"), let dir = opt("--snap") {      // --settings --snap DIR: open the layout editor and snapshot its panel
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SettingsPanel.shared.open() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { if let v = SettingsPanel.shared.snapshotView { snap(v, "settings", dir) } }
}

if let spec = opt("--pop"), let dir = opt("--snap") {      // --pop date[:2] --snap DIR: open that card (at that stage) and snapshot it
    let parts = spec.split(separator: ":"), stage = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let rail = parts[0] == "workspaces" || parts[0] == "fan", lower = parts[0] == "vitals", lowerRight = parts[0] == "weather", topLeft = parts[0] == "usage"
        if args.contains("--pop-hop") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Popout.shared.hover("bat", anchor: CGRect(x: f.maxX - 420, y: f.maxY - 46, width: 120, height: 36), edge: .below) } }      // test: hop to another atom with no "left" event
        defer { if !args.contains("--pop-free") { Popout.shared.holdOpen = true } }      // a snapshot keeps its card out; --pop-free lets the watchdog act (a test)
        let forced = opt("--pop-edge").flatMap { ["below": PopEdge.below, "above": .above, "right": .right, "left": .left][$0] }      // --pop-edge below|above|right: that card from a bar on that side
        if let e = forced {
            let a: CGRect = e == .right ? CGRect(x: f.minX, y: f.maxY - Real.sideMargin - 250, width: Real.strip, height: 250) : e == .left ? CGRect(x: f.maxX - Real.strip, y: f.maxY - Real.sideMargin - 250, width: Real.strip, height: 250) : e == .below ? CGRect(x: f.maxX - 200, y: f.maxY - 46, width: 90, height: 36) : CGRect(x: f.maxX - 260, y: f.minY + 9, width: 220, height: 36)
            // --pop-anchor x,y,w,h and --pop-island x,y,w,h (screen points, origin bottom-left): open the card from those rectangles, so a chat card can be placed under a real pill
            func rect(_ name: String) -> CGRect? { opt(name).flatMap { s in let v = s.split(separator: ",").compactMap { Double($0) }; return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil } }
            Popout.shared.hover(String(parts[0]), anchor: rect("--pop-anchor") ?? a, edge: e, island: rect("--pop-island"))
        } else {
        Popout.shared.hover(String(parts[0]), anchor: rail ? (parts[0] == "fan" ? CGRect(x: f.minX, y: f.minY + Real.sideMargin, width: Real.strip, height: 150) : CGRect(x: f.minX, y: f.maxY - Real.sideMargin - 250, width: Real.strip, height: 250)) : lower ? CGRect(x: f.midX - 300, y: f.minY + 9, width: 600, height: 36) : lowerRight ? CGRect(x: f.maxX - 260, y: f.minY + 9, width: 220, height: 36) : topLeft ? CGRect(x: f.minX + G.strip + G.sideMargin, y: f.maxY - 46, width: 190, height: 36) : CGRect(x: f.maxX - 200, y: f.maxY - 46, width: 90, height: 36), edge: rail ? .right : (lower || lowerRight) ? .above : .below)
        }
        if parts[0] != "net" && stage == 2 { Popout.shared.setStage(2) }      // the network card reads its tab from `--pop net:<n>` itself
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if let v = Popout.shared.snapshotView { print("pop-frame", parts[0], v.window?.frame ?? .zero, "floatY", Popout.shared.floatY, "screen", f); fflush(stdout)
             snap(v, "pop-\(parts[0])-\(stage)", dir) }; snap(topHost, "top-lit", dir); snap(strip, "left-lit", dir); snap(rightStrip, "right-lit", dir); snap(bottomHost, "bottom-lit", dir) }
    }
}

for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { shutdown(); exit(0) }
    s.resume()
    sigSources.append(s)
}
if let n = opt("--stay").flatMap(Double.init) { DispatchQueue.main.asyncAfter(deadline: .now() + n) { shutdown(); NSApp.terminate(nil) } }
_ = (left, right, top, bottom)
app.run()

