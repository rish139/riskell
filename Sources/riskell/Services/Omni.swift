import AppKit
import RiskellKit

/// OmniWM bridge, in-process over its IPC socket (one JSON object per line). One persistent subscription carries the WM's whole state on
/// every change (the workspaces, the windows, the focused window, the active workspace), so riskell never queries and never forks:
/// each event replaces its slice and the Store is set from the result. Commands go out on a second persistent connection.
/// If OmniWM goes away both connections retry every 2 s until it is back (the only timer, and only while disconnected).
final class Omni: WindowManager {
    let name = "omniwm"
    let ownsSwipe = true            // OmniWM's own workspace swipe is off in its settings (workspaceSwipeEnabled = false); Touch switches
    static let path = NSHomeDirectory() + "/Library/Application Support/com.barut.OmniWM/ipc.sock"
    static let protocolVersion = 22
    func reserve(_ config: Config) { Gaps.apply(config) }

    /// OmniWM's own swipe and scroll gestures act on the same touches riskell needs, so both must be off in its settings (the same check
    /// the version tracker makes, Compat.swift). A missing settings file says nothing.
    var gestureConflicts: [String] {
        guard let s = Compat.omniwmSettings() else { return [] }
        var out: [String] = []
        if s["gestures.workspaceSwipeEnabled"] != "false" { out.append("OmniWM 3-finger swipe") }
        if s["gestures.scrollEnabled"] != "false" { out.append("OmniWM scroll gestures") }
        return out
    }

    /// Workspaces the rail always shows (five); later ones appear while they hold windows or focus.
    static let alwaysShown = 5

    /// OmniWM is up and accepting connections (checked once at start).
    static var available: Bool {
        guard let fd = Line.connect(path) else { return false }
        Darwin.close(fd); return true
    }

    // MARK: wire types (only the fields riskell reads)
    private struct Disp: Decodable { let isMain: Bool? }
    private struct Workspace: Decodable {
        let number: Int; let isFocused: Bool?; let display: Disp?
    }
    private struct Window: Decodable {
        struct App: Decodable { let name: String? }
        struct WS: Decodable { let number: Int? }
        let id: String; let windowId: Int; let pid: Int?; let title: String?; let app: App?; let workspace: WS?
        struct Fr: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
        let isFocused: Bool?; let isScratchpad: Bool?; let display: Disp?
        let frame: Fr?; let hiddenReason: String?; let mode: String?; let focusRank: Int?
    }
    private struct Head: Decodable {
        struct R: Decodable { let kind: String }
        let kind: String; let ok: Bool?; let status: String?; let result: R?
    }
    private struct Event<P: Decodable>: Decodable { struct R: Decodable { let payload: P }; let result: R }
    private struct Workspaces: Decodable { let workspaces: [Workspace] }
    private struct Windows: Decodable { let windows: [Window] }
    private struct Active: Decodable { struct W: Decodable { let number: Int? }; let workspace: W? }
    private struct Focused: Decodable { let window: Window? }

    // MARK: state (main queue)
    private let store: Store
    private var workspaces: [Workspace] = []
    private var windows: [Window] = []
    private var active: Int?
    private var focusedWindow: Int?
    private var opaque: [Int: String] = [:]          // CGWindowID -> OmniWM's session id, which its window commands take
    /// Each window's frame (top-left points) as last seen on screen: OmniWM reports an inactive workspace's windows at their parked
    /// position, so the overview needs the place it had while it was showing. Not published (frames change on every resize).
    private var seen: [Int: CGRect] = [:]
    private var seenOn: [Int: Int] = [:]           // the workspace it was on when `seen` was taken
    private var frames: [Int: WinFrame] = [:]
    func windowFrames() -> [Int: WinFrame] { frames }

    private let io = DispatchQueue(label: "riskell.omni")
    private var sub: Line?, cmd: Line?
    private var running = false, retrying = false

    init(store: Store) { self.store = store }

    func start() { running = true; connect() }
    func stop() { running = false; sub?.close(); cmd?.close(); sub = nil; cmd = nil }
    func requestRefresh() {}                          // the subscription already pushes every change

    private func connect() {
        guard running, sub == nil else { return }
        let l = Line(queue: io)
        guard l.open(Omni.path), let req = request("subscribe", ["allChannels": false, "sendInitial": true,
              "channels": ["layout-changed", "windows-changed", "focus", "active-workspace"]]), l.send(req) else {
            l.close(); retry(); return
        }
        l.onLine = { [weak self] line in self?.received(line) }
        l.onClose = { [weak self] in DispatchQueue.main.async { self?.sub = nil; self?.cmd?.close(); self?.cmd = nil; print("omniwm: connection closed"); self?.retry() } }
        sub = l
        print("omniwm: subscribed")
        DispatchQueue.main.async { Compat.shared.check() }      // OmniWM (re)started: it may have been updated
    }

    private func retry() {
        guard running, !retrying else { return }
        retrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.retrying = false; self?.connect() }
    }

    /// Floating windows (System Settings, permission dialogs that OmniWM floats, ...) always stay above the tiled ones: OmniWM raises a window it
    /// focuses over them, so after a focus or workspace change, while a floating window is visible, OmniWM's own "raise all floating
    /// windows" runs once (debounced 0.12 s; its own effect on focus is ignored for 0.8 s so it cannot trigger itself).
    static var floatingOnTop = true
    private var raiseWork: DispatchWorkItem?
    private var lastRaise = 0.0
    private func keepFloatingOnTop() {
        guard Self.floatingOnTop, CACurrentMediaTime() - lastRaise > 0.8 else { return }
        raiseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let floats = self.windows.filter { $0.mode == "floating" && $0.hiddenReason == nil && !($0.isScratchpad ?? false) }
            guard !floats.isEmpty else { return }
            // never fight the user: a button held (drag, menu-bar menu), or the front app is not one OmniWM manages
            // (permission dialog, menu-bar extra, Spotlight): raising would activate the floating app and steal focus / the pointer
            guard NSEvent.pressedMouseButtons == 0,
                  let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  self.windows.contains(where: { $0.pid == Int(front) }) else { return }
            self.lastRaise = CACurrentMediaTime()
            self.send("command", ["name": "raise-all-floating-windows"])
        }
        raiseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    /// Called on the io queue: decode there, apply on main.
    private func received(_ line: Data) {
        let dec = JSONDecoder()
        guard let head = try? dec.decode(Head.self, from: line) else { return }
        if head.ok == false { print("omniwm: \(head.status ?? "error"): \(String(decoding: line.prefix(300), as: UTF8.self))"); return }
        guard head.kind == "event", let kind = head.result?.kind else { return }
        // a focus or workspace change is enough to trigger the raise, whatever its payload decodes to
        if kind == "focused-window" || kind == "active-workspace" { DispatchQueue.main.async { self.keepFloatingOnTop() } }
        switch kind {
        case "workspaces":
            guard let p = try? dec.decode(Event<Workspaces>.self, from: line).result.payload else { return }
            DispatchQueue.main.async { self.workspaces = p.workspaces; self.publish() }
        case "windows":
            guard let p = try? dec.decode(Event<Windows>.self, from: line).result.payload else { return }
            DispatchQueue.main.async { self.windows = p.windows; self.publish() }
        case "active-workspace":
            guard let p = try? dec.decode(Event<Active>.self, from: line).result.payload else { return }
            DispatchQueue.main.async { self.active = p.workspace?.number; self.publish() }
        case "focused-window":
            guard let p = try? dec.decode(Event<Focused>.self, from: line).result.payload else { return }
            DispatchQueue.main.async { self.focusedWindow = p.window?.windowId; self.publish() }
        default: break
        }
    }

    /// The Store from the current slices. The rail shows workspaces 1...N: N = the five that always existed, or more while a later one
    /// holds windows or focus. A focus change goes through `Store.set(spaces:)` (it confirms a pending swipe) and teaches Touch the direction.
    /// A window's frame counts as a place only while at least half of it is on the screen: OmniWM parks hidden windows past the edge.
    private static func mostlyOnScreen(_ r: CGRect) -> Bool {
        let s = CGRect(x: 0, y: 0, width: NSScreen.screens.first?.frame.width ?? 0, height: NSScreen.screens.first?.frame.height ?? 0)
        let i = s.intersection(r)
        return !i.isNull && i.width * i.height >= 0.5 * r.width * r.height
    }

    private func publish() {
        let main = workspaces.filter { $0.display?.isMain ?? true }
        var focus = active ?? main.first { $0.isFocused == true }?.number
        // a switch riskell just sent is the truth until OmniWM reports it (its reports of earlier switches lag ~0.3 s and would flick the rail back)
        if let it = intent {
            if focus == it.space || CACurrentMediaTime() > it.until { intent = nil } else { focus = it.space }
        }
        let wins = windows.filter { !($0.isScratchpad ?? false) && ($0.display?.isMain ?? true) && $0.workspace?.number != nil }
        opaque = Dictionary(wins.map { ($0.windowId, $0.id) }, uniquingKeysWith: { a, _ in a })
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        var fr: [Int: WinFrame] = [:]
        for w in wins {
            guard let f = w.frame else { continue }
            let r = CGRect(x: f.x, y: screenH - f.y - f.height, width: f.width, height: f.height)      // OmniWM: bottom-left origin
            let ws = w.workspace?.number ?? 0
            if w.hiddenReason == nil, Self.mostlyOnScreen(r) { seen[w.windowId] = r; seenOn[w.windowId] = ws }
            // a remembered place holds only while the window is still on that workspace at that size (a drop or a split elsewhere
            // changes them while it is parked); otherwise the overview lays it out from its size
            var known = seen[w.windowId].flatMap { Self.mostlyOnScreen($0) ? $0 : nil }      // never a parked (off-screen) place
            // (a floating window keeps its own place across workspaces; only a tiled one is re-laid out by a move)
            if let k = known, (seenOn[w.windowId] != ws && w.mode != "floating") || abs(k.width - r.width) > 2 || abs(k.height - r.height) > 2 { known = nil }
            fr[w.windowId] = WinFrame(rect: known ?? r, placed: known != nil, floating: w.mode == "floating", rank: w.focusRank ?? 99)
        }
        seen = seen.filter { fr[$0.key] != nil }; seenOn = seenOn.filter { fr[$0.key] != nil }
        frames = fr
        let info = wins.map { w in
            WinInfo(id: w.windowId, pid: w.pid ?? 0, app: w.app?.name ?? "", title: w.title ?? "", space: w.workspace!.number!,
                    focused: focusedWindow.map { $0 == w.windowId } ?? (w.isFocused ?? false))
        }
        var count: [Int: Int] = [:]
        for w in info { count[w.space, default: 0] += 1 }
        let shown = max(Omni.alwaysShown, count.keys.max() ?? 0, focus ?? 0)
        let spaces = main.filter { $0.number <= shown }.sorted { $0.number < $1.number }.map {
            SpaceInfo(id: $0.number, sid: 0, focused: $0.number == focus, visible: $0.number == focus, windows: count[$0.number] ?? 0, fullscreen: false)
        }
        store.set(windows: info)
        guard !spaces.isEmpty else { return }
        let old = store.focusedIndex
        store.set(spaces: spaces)
        if old != store.focusedIndex { print("omniwm: workspace \(focus ?? 0) confirmed (unconfirmed swipes \(store.pending))"); fflush(stdout); tlog("omniwm: workspace \(focus ?? 0)"); Touch.shared?.spaceChanged(from: old, to: store.focusedIndex) }
    }

    // MARK: commands (one line each on the command connection; replies are read only to log failures)
    private func request(_ kind: String, _ payload: [String: Any]) -> Data? {
        guard let token = try? String(contentsOfFile: Omni.path + ".secret", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            print("omniwm: no ipc secret"); return nil
        }
        let obj: [String: Any] = ["id": UUID().uuidString, "kind": kind, "payload": payload, "version": Omni.protocolVersion, "authorizationToken": token]
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        d.append(0x0a)
        return d
    }

    private func send(_ kind: String, _ payload: [String: Any]) {
        guard let req = request(kind, payload) else { return }
        if cmd == nil {
            let l = Line(queue: io)
            guard l.open(Omni.path) else { l.close(); print("omniwm: command connection failed"); return }
            l.onLine = { line in
                // "ignored" is a no-op (e.g. switching to the focused workspace), not a failure
                if let h = try? JSONDecoder().decode(Head.self, from: line), h.ok == false, h.status != "ignored" {
                    print("omniwm: command failed: \(String(decoding: line.prefix(300), as: UTF8.self))")
                }
            }
            l.onClose = { [weak self] in DispatchQueue.main.async { self?.cmd = nil } }
            cmd = l
        }
        if cmd?.send(req) != true { cmd?.close(); cmd = nil }
    }

    private var intent: (space: Int, until: Double)?
    func focus(space: Int) {
        intent = (space, CACurrentMediaTime() + 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.publish() }      // if OmniWM never went there, the rail returns to the real workspace
        store.focusNow(space: space)
        send("command", ["name": "switch-workspace", "arguments": ["workspaceNumber": space]])
    }
    /// Goes to the window's workspace and focuses it.
    func focus(window id: Int) { if let o = opaque[id] { send("window", ["name": "navigate", "windowId": o]) } }
    func close(window id: Int) { if let o = opaque[id] { send("window", ["name": "close", "windowId": o]) } }
    func move(window id: Int, toSpace space: Int) {
        if let o = opaque[id] { send("window", ["name": "move-to-workspace", "windowId": o, "workspaceTarget": ["kind": "raw-id", "value": String(space)]]) }
    }
    /// OmniWM's workspaces all exist already: "new" is simply the one after the last shown.
    func moveToNewSpace(window id: Int, after count: Int) { move(window: id, toSpace: count + 1) }
}

/// A connected unix stream socket that reads newline-delimited messages on `queue`.
final class Line {
    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var buffer = Data()
    var onLine: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    static func connect(_ path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); return nil }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) } }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) } }
        guard ok == 0 else { Darwin.close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    func open(_ path: String) -> Bool {
        guard let fd = Line.connect(path) else { return false }
        self.fd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        source = src
        return true
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &chunk, chunk.count)
        guard n > 0 else { let cb = onClose; close(); cb?(); return }
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { onLine?(Data(line)) }
        }
    }

    /// Small requests: a blocking write is fine (the socket is local and OmniWM reads promptly).
    func send(_ d: Data) -> Bool {
        guard fd >= 0 else { return false }
        return d.withUnsafeBytes { p -> Bool in
            var off = 0
            while off < d.count {
                let w = Darwin.write(fd, p.baseAddress! + off, d.count - off)
                if w <= 0 { return false }
                off += w
            }
            return true
        }
    }

    func close() {
        onLine = nil; onClose = nil
        source?.cancel(); source = nil; fd = -1
    }
}
