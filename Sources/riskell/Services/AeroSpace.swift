import AppKit
import RiskellKit
import RiskellWM

/// AeroSpace backend, in-process over its socket (protocol in RiskellWM/AeroSpaceSocket.swift). One persistent connection holds a
/// subscription to AeroSpace's events; a second one carries the queries and the commands and is opened when first needed. Nothing is
/// polled and no process is started: an event (or an app launching, quitting or activating, which AeroSpace reports nothing for) asks for
/// a refresh, a burst of them coalesces into one (two queries), and nothing is published when the result did not change.
/// If AeroSpace goes away the subscription retries every 2 s until it is back (the only timer, and only while disconnected).
/// Everything that touches a socket runs on the private serial queue `io`; the Store is set on main.
final class AeroSpace: WindowManager {
    let name = "aerospace"
    let ownsSwipe = true            // AeroSpace has no swipe of its own, so nothing would switch on a prediction: Touch sends the switch itself

    static let candidates = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    static var path: String { RiskellWM.AeroSpace.socketPath(user: NSUserName()) }
    /// AeroSpace is up and its socket exists.
    static var available: Bool { FileManager.default.fileExists(atPath: path) }

    // MARK: state
    private let store: Store
    private let io = DispatchQueue(label: "riskell.aerospace")

    // main
    private var started = false
    private var state: RiskellWM.AeroSpace.State?        // the last refresh that was published
    private var focusedWindow: Int?
    private var intent: (space: Int, until: Double)?     // a switch riskell sent is the truth until AeroSpace reports it (up to 1 s)
    private var observers: [NSObjectProtocol] = []
    private var items: [RiskellWM.AeroSpace.Item] = []
    private var visibleSpaces: Set<Int> = []

    // io
    private var running = false, retrying = false, scheduled = false, warned = false
    private var sub: Connection?, cmd: Connection?
    private var reader = RiskellWM.AeroSpace.FrameReader()

    init(store: Store) { self.store = store }

    /// true while the subscription that carries the manager's events is up (for the health check, Services/AppStatus.swift)
    var subscribed: Bool { subscribedFlag }
    private var subscribedFlag = false                   // written on io, read for a status line only

    // MARK: lifecycle
    func start() {
        guard !started else { return }
        started = true
        let nc = NSWorkspace.shared.notificationCenter
        // AeroSpace emits nothing when a window opens or closes in the background, but the app owning it launches, quits or is activated
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.requestRefresh() })
        }
        io.async { [weak self] in self?.running = true; self?.connect() }
    }

    func stop() {
        guard started else { return }
        started = false
        let nc = NSWorkspace.shared.notificationCenter
        for o in observers { nc.removeObserver(o) }
        observers = []
        io.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.sub?.close(); self.cmd?.close(); self.sub = nil; self.cmd = nil
            self.subscribedFlag = false
        }
    }

    /// Coalesced: a burst of events becomes one refresh 40 ms after the first.
    func requestRefresh() { io.async { [weak self] in self?.schedule(after: 0.04) } }

    /// Queries now, for the overview as it opens.
    func refreshNow() { io.async { [weak self] in self?.refresh(force: true) } }

    private func schedule(after delay: Double) {
        guard running, !scheduled else { return }
        scheduled = true
        io.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.scheduled = false
            self?.refresh()
        }
    }

    // MARK: connections (io)
    private func connect() {
        guard running, sub == nil else { return }
        let l = Connection(queue: io)
        guard l.open(AeroSpace.path), l.send(RiskellWM.AeroSpace.request(RiskellWM.AeroSpace.subscribeArgs)) else {
            l.close(); retry(); return
        }
        reader = RiskellWM.AeroSpace.FrameReader()
        l.onBytes = { [weak self] bytes in self?.received(bytes) }
        l.onClose = { [weak self] in
            guard let self else { return }
            self.sub = nil; self.subscribedFlag = false
            self.cmd?.close(); self.cmd = nil
            if self.running { print("aerospace: connection closed"); fflush(stdout) }
            self.warned = true
            self.retry()
        }
        l.listen()
        sub = l
        subscribedFlag = true
        warned = false
        print("aerospace: subscribed"); fflush(stdout)
        DispatchQueue.main.async { Compat.shared.check() }      // AeroSpace (re)started: it may have been updated
        refresh(seed: true)
    }

    private func retry() {
        guard running, !retrying else { return }
        retrying = true
        io.asyncAfter(deadline: .now() + 2) { [weak self] in self?.retrying = false; self?.connect() }
    }

    /// One request on the command connection and its answer. The connection is opened on first use and reopened once when a write or a
    /// read on a long-idle one fails. nil when AeroSpace cannot be reached or answers with an error.
    @discardableResult
    private func run(_ args: [String]) -> RiskellWM.AeroSpace.Answer? {
        for _ in 0..<2 {
            if cmd == nil {
                let c = Connection(queue: io)
                guard c.open(AeroSpace.path) else { c.close(); return nil }
                cmd = c
            }
            if let frame = cmd?.call(RiskellWM.AeroSpace.request(args)), let a = RiskellWM.AeroSpace.parse(answer: frame) {
                if a.exitCode != 0 { print("aerospace: \(args.first ?? "") failed: \(a.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"); fflush(stdout) }
                return a.exitCode == 0 ? a : nil
            }
            cmd?.close(); cmd = nil
        }
        return nil
    }

    // MARK: events (io)
    private func received(_ bytes: Data) {
        for f in reader.feed(bytes) {
            guard let e = RiskellWM.AeroSpace.parse(event: f) else { continue }
            switch e {
            case .focusChanged(let id, _):
                DispatchQueue.main.async { [weak self] in self?.focusedWindow = id }
                schedule(after: 0.04)
            case .focusedWorkspaceChanged, .windowDetected, .focusedMonitorChanged:
                schedule(after: 0.04)
            case .other:
                break
            }
        }
        if reader.broken { sub?.close(); sub = nil; subscribedFlag = false; print("aerospace: unreadable stream, reconnecting"); fflush(stdout); retry() }
    }

    // MARK: refresh (io, then main)
    private func refresh(seed: Bool = false, force: Bool = false) {
        guard running else { return }
        guard let ws = run(RiskellWM.AeroSpace.workspaceQuery), let wd = run(RiskellWM.AeroSpace.windowQuery),
              let next = RiskellWM.AeroSpace.parse(workspaceRows: ws.stdout, windowRows: wd.stdout) else {
            if !warned { warned = true; print("aerospace: query failed (is AeroSpace running?)"); fflush(stdout) }
            return
        }
        // the queries do not say which window has focus; the events do, so only the first refresh asks
        let focused = seed ? run(RiskellWM.AeroSpace.focusedWindowQuery).flatMap { RiskellWM.AeroSpace.parse(focusedWindow: $0.stdout) } : nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started else { return }
            if seed { self.focusedWindow = focused }
            self.apply(next, force: force)
        }
    }

    private var lastFocus: Int??                          // main: the focused window of the last publish

    private func apply(_ next: RiskellWM.AeroSpace.State, force: Bool = false) {
        // nothing changed and no switch of riskell's own is waiting to be confirmed: publish nothing (a forced refresh, the overview
        // opening, still takes fresh frames: windows may have been resized since)
        if intent == nil, state == next, lastFocus == .some(focusedWindow) { if force { frames = computeFrames() }; return }
        state = next; lastFocus = .some(focusedWindow)
        items = next.items
        visibleSpaces = Set(next.spaces.filter(\.visible).map(\.id))
        frames = computeFrames()
        var wins = next.windows
        for i in wins.indices { wins[i].focused = wins[i].id == focusedWindow }
        store.set(windows: wins)
        guard !next.spaces.isEmpty else { return }
        var spaces = next.spaces
        // a switch riskell just sent is the truth until AeroSpace reports it: the queries of an earlier switch finish late and would
        // put the rail back on the old workspace, so a quick second swipe would start from the wrong place
        if let it = intent {
            if spaces.first(where: \.focused)?.id == it.space || CACurrentMediaTime() > it.until { intent = nil }
            else { for i in spaces.indices { spaces[i].focused = spaces[i].id == it.space; spaces[i].visible = spaces[i].focused } }
        }
        let old = store.focusedIndex
        store.set(spaces: spaces)
        if old != store.focusedIndex { Touch.shared?.spaceChanged(from: old, to: store.focusedIndex) }
    }

    // MARK: overview
    /// Read by the overview on every draw and hit-test, so it is a stored copy, taken (one window-server call) when the state changes
    /// and when the overview opens.
    private var frames: [Int: WinFrame] = [:]
    func windowFrames() -> [Int: WinFrame] { frames }

    private func computeFrames() -> [Int: WinFrame] {
        var rank: [Int: Int] = [:]
        let entries = items.map { it -> WindowBook.Entry in
            let r = rank[it.space, default: 0]; rank[it.space] = r + 1
            return WindowBook.Entry(id: it.id, workspace: it.space, floating: it.floating, rank: r)
        }
        return WindowBook.shared.frames(for: entries)
    }

    /// The windows on the workspaces that are showing: their frames are saved before a switch or a move parks them.
    private func rememberShown() { WindowBook.shared.remember(ids: Set(items.filter { visibleSpaces.contains($0.space) }.map(\.id))) }

    // MARK: commands
    /// The Store first (the rail moves at once), then AeroSpace; its event confirms it.
    func focus(space: Int) {
        intent = (space, CACurrentMediaTime() + 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.requestRefresh() }      // if AeroSpace never went there, the rail returns to the real workspace
        store.focusNow(space: space)
        rememberShown()
        io.async { [weak self] in self?.run(["workspace", String(space)]) }
    }
    func focus(window id: Int) {
        rememberShown()
        io.async { [weak self] in self?.run(["focus", "--window-id", String(id)]) }
    }
    func close(window id: Int) {
        io.async { [weak self] in
            self?.run(["close", "--window-id", String(id)])
            self?.schedule(after: 0.15)         // AeroSpace reports no event for a closed window
        }
    }
    func move(window id: Int, toSpace space: Int) {
        rememberShown()
        io.async { [weak self] in
            self?.run(["move-node-to-workspace", "--window-id", String(id), String(space)])
            self?.schedule(after: 0.04)
        }
    }
    /// AeroSpace creates workspaces on demand, so the one after the last shown is simply named `count + 1`.
    func moveToNewSpace(window id: Int, after count: Int) { move(window: id, toSpace: count + 1) }

    // MARK: rail geometry
    /// Outer gaps live in aerospace.toml [gaps]; AeroGaps keeps them in step with the bars.
    func reserve(_ config: Config) { AeroGaps.apply(config) }
    var gestureConflicts: [String] { [] }      // AeroSpace has no swipe or scroll gesture of its own; the gap drift is shown by Compat
}

/// A connected AeroSpace socket: the version handshake, then framed messages. Used for the event stream (`listen`, which hands bytes to
/// `onBytes` on its queue) or for requests (`call`, which blocks the queue for at most 3 s).
private final class Connection {
    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    var onBytes: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    /// Connects and exchanges versions. false when AeroSpace is not there or speaks another version.
    func open(_ path: String) -> Bool {
        guard let fd = Line.connect(path) else { return false }
        self.fd = fd
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard send(RiskellWM.AeroSpace.handshake), let theirs = read(count: 4), RiskellWM.AeroSpace.accepts(handshake: theirs) else {
            close(); return false
        }
        return true
    }

    /// The event stream: no timeout, read when the socket is readable.
    func listen() {
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let fd = self.fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &chunk, chunk.count)
            guard n > 0 else { let cb = self?.onClose; self?.close(); cb?(); return }
            self?.onBytes?(Data(chunk[0..<n]))
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        source = src
    }

    /// One request and the frame that answers it. nil on a closed or silent connection.
    func call(_ request: Data) -> Data? {
        guard send(request), let head = read(count: 4) else { return nil }
        let n = Int(RiskellWM.AeroSpace.readLE32(head, at: head.startIndex))
        guard n <= RiskellWM.AeroSpace.FrameReader.limit else { return nil }
        return read(count: n)
    }

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

    private func read(count: Int) -> Data? {
        guard fd >= 0 else { return nil }
        var out = Data(capacity: count)
        var chunk = [UInt8](repeating: 0, count: min(max(count, 1), 65536))
        while out.count < count {
            let n = Darwin.read(fd, &chunk, min(chunk.count, count - out.count))
            if n <= 0 { return nil }
            out.append(contentsOf: chunk[0..<n])
        }
        return out
    }

    func close() {
        onBytes = nil; onClose = nil
        if let s = source { s.cancel(); source = nil }      // the cancel handler closes the descriptor
        else if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}
