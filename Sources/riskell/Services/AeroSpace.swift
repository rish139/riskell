import AppKit
import RiskellKit
import RiskellWM

/// AeroSpace backend, in-process over its socket (protocol in RiskellWM/AeroSpaceSocket.swift). One persistent connection holds a
/// subscription to AeroSpace's events; a second one carries the queries and the commands and is opened when first needed. Nothing is
/// polled and no process is started: an event asks for a refresh only when the rows of the last query cannot already tell what it says
/// (RiskellWM/AeroSpaceRows.swift makes that call), a burst of them coalesces into one (the queries of a refresh ride in one request), and
/// nothing is published when the result did not change.
/// If AeroSpace goes away the subscription retries every 2 s until it is back (the only timer, and only while disconnected).
/// Everything that touches a socket runs on the private serial queue `io`; the Store is set on main.
final class AeroSpace: WindowManager {
    let name = "aerospace"
    let ownsSwipe = true            // AeroSpace has no swipe of its own, so nothing would switch on a prediction: Touch sends the switch itself

    static let candidates = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    /// The socket to talk to: AeroSpace's own, or the one `RISKELL_AEROSPACE_SOCKET` names (a fake server, for tests).
    static var path: String {
        let env = ProcessInfo.processInfo.environment["RISKELL_AEROSPACE_SOCKET"] ?? ""
        return env.isEmpty ? RiskellWM.AeroSpace.socketPath(user: NSUserName()) : env
    }
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
    private var rows: RiskellWM.AeroSpace.Rows?          // the rows of the last query: all the bar shows is parsed from them
    private var stale = false                            // a binding may have changed what the rows cannot say; nothing is applied until the next answer
    private var bindings: RiskellWM.AeroSpace.Bindings?  // every mode's bindings, read with the first refresh of a connection
    private var focused: Int?                            // the focused window, for the hooks (main keeps its own copy for the bar)
    private var hooks: [any ManagerHook] = []             // what the running behaviours asked for; set from main, read here
    private var landscape: [Int: Bool] = [:]              // monitor id to its screen being wider than tall; built on main, read here
    private var deferred: [ArrivedEvent] = []             // events handed to the hooks only after the rows were asked for again
    private var appliedMode: String?                       // the binding mode riskell put the manager in; nil while it has left it alone
    private var modeWarned = false

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
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.requestRefresh() })
        }
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.io.async { [weak self] in self?.change(.activation) }
        })
        readScreens()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                                queue: .main) { [weak self] _ in self?.readScreens() })
        io.async { [weak self] in self?.running = true; self?.connect() }
    }

    func stop() {
        guard started else { return }
        started = false
        let nc = NSWorkspace.shared.notificationCenter
        for o in observers { nc.removeObserver(o) }
        observers = []
        // back to the plain keys before anything closes, and now: the process exits straight after `stop`, so a queued block would never run
        io.sync { [weak self] in
            guard let self, self.appliedMode != nil, self.sub != nil || self.cmd != nil else { return }
            self.run(["mode", "main"], quiet: true)
            self.appliedMode = nil
        }
        io.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.hooks = []
            self.deferred = []
            self.sub?.close(); self.cmd?.close(); self.sub = nil; self.cmd = nil
            self.subscribedFlag = false
        }
    }

    /// Coalesced: a burst of events becomes one refresh 40 ms after the first.
    func requestRefresh() { io.async { [weak self] in self?.schedule(after: 0.04) } }

    /// Queries now, for the overview as it opens.
    func refreshNow() { io.async { [weak self] in self?.refresh(force: true) } }

    /// The running behaviours that add to the manager's requests. The list is copied over to the queue the backend reads it on, and the
    /// behaviours are only ever called there.
    func setHooks(_ hooks: [any ManagerHook]) {
        let copy = hooks
        io.async { [weak self] in self?.hooks = copy; self?.syncMode() }
    }

    /// Screens are read on main; the map goes over to the queue that reads it, so nothing crosses queues by itself.
    private func readScreens() {
        let map = Self.landscapeByMonitor()
        io.async { [weak self] in self?.landscape = map }
    }

    /// AeroSpace numbers the monitors by their place among the screens sorted by their top-left corner, so the same sort of
    /// NSScreen.screens says which screen a row's monitor id names, and whether it is wider than it is tall.
    static func landscapeByMonitor() -> [Int: Bool] {
        let screens = NSScreen.screens
        guard let main = screens.first(where: { $0.frame.minX == 0 && $0.frame.minY == 0 }) ?? screens.first else { return [:] }
        return RiskellWM.AeroSpace.landscape(frames: screens.map(\.frame), mainHeight: main.frame.height)
    }

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
        syncMode(force: true)       // the manager may have restarted since, into `main`
    }

    /// Puts the manager in the binding mode the running behaviours' keys are bound in (or back in `main` when none wants one), so that the
    /// plain keys of `main` are what is there whenever riskell is not. A mode the manager does not have is reported once.
    private func syncMode(force: Bool = false) {
        guard running, let mode = RiskellWM.AeroSpace.modeStep(wanted: hooks.compactMap(\.bindingMode).first, applied: appliedMode, force: force) else { return }
        if run(["mode", mode], quiet: true) != nil {
            appliedMode = mode == "main" ? nil : mode
        } else if !modeWarned {
            modeWarned = true
            print("aerospace: could not enter the binding mode \(mode) (is it in aerospace.toml?)"); fflush(stdout)
        }
    }

    private func retry() {
        guard running, !retrying else { return }
        retrying = true
        io.asyncAfter(deadline: .now() + 2) { [weak self] in self?.retrying = false; self?.connect() }
    }

    /// One request on the command connection and its answer. The connection is opened on first use and reopened once when a write or a
    /// read on a long-idle one fails. nil when AeroSpace cannot be reached or answers with an error. `window` is the request's target
    /// window, which AeroSpace hands to the commands that take no `--window-id` (its `test`). `quiet` keeps a failed command out of the
    /// log: a hook's script can answer non-zero because there is nothing to do, and that is not an error.
    @discardableResult
    private func run(_ args: [String], window: Int? = nil, quiet: Bool = false) -> RiskellWM.AeroSpace.Answer? {
        for _ in 0..<2 {
            if cmd == nil {
                let c = Connection(queue: io)
                guard c.open(AeroSpace.path) else { c.close(); return nil }
                cmd = c
            }
            if let frame = cmd?.call(RiskellWM.AeroSpace.request(args, window: window)), let a = RiskellWM.AeroSpace.parse(answer: frame) {
                if a.exitCode != 0, !quiet { print("aerospace: \(args.first ?? "") failed: \(a.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"); fflush(stdout) }
                return a.exitCode == 0 ? a : nil
            }
            cmd?.close(); cmd = nil
        }
        return nil
    }

    // MARK: events (io)
    /// One event as the hooks see it, and what the backend itself makes of it.
    private struct ArrivedEvent {
        let fields: RiskellWM.AeroSpace.EventFields
        let change: RiskellWM.AeroSpace.Event?
    }

    private func received(_ bytes: Data) {
        for f in reader.feed(bytes) {
            guard let fields = RiskellWM.AeroSpace.parse(eventFields: f) else { continue }
            let change = RiskellWM.AeroSpace.parse(event: f)
            // the hooks' state and the bar follow the focus at once, whether or not a hook answers this event
            if case .focusChanged(let id, _)? = change {
                focused = id
                DispatchQueue.main.async { [weak self] in self?.focusedWindow = id }
            }
            let event = ArrivedEvent(fields: fields, change: change)
            // the rows are older than the event (a binding riskell does not understand may have changed what they cannot say): ask for
            // them first, and hand the event to the hooks with the fresh answer
            if stale, hooksWant(ManagerEvent(name: fields.name, fields: fields.fields)) {
                deferred.append(event)
                schedule(after: 0.04)
                continue
            }
            handle(event)
        }
        if reader.broken { sub?.close(); sub = nil; subscribedFlag = false; print("aerospace: unreadable stream, reconnecting"); fflush(stdout); retry() }
    }

    /// Gives an event to the hooks, and handles it the way the backend always has when they return nothing. `justRefreshed` says the rows
    /// were asked for after this event arrived, so a change whose only answer is a refresh needs nothing more.
    private func handle(_ event: ArrivedEvent, justRefreshed: Bool = false) {
        if runHooks(ManagerEvent(name: event.fields.name, fields: event.fields.fields)) { return }
        switch event.change {
            case .focusChanged(let id, let workspace)?:
                change(.focus(windowId: id, workspace: workspace))
            case .focusedWorkspaceChanged(let workspace, _)?:
                change(.focusedWorkspace(workspace))
            case .bindingTriggered(let mode, let binding)?:
                change(.binding(mode: mode, binding: binding))
            case .windowDetected?, .focusedMonitorChanged?:
                if !justRefreshed { change(.refresh) }
            case .other?, nil:
                break
        }
    }

    /// Answers an event with no request when the rows already say what it reports, and with one when they do not.
    private func change(_ change: RiskellWM.AeroSpace.Change) {
        switch RiskellWM.AeroSpace.decide(change, rows: rows, bindings: bindings, stale: stale) {
        case .apply(let next):
            // a window can close without AeroSpace saying so (Cmd-W, an app closing its own window): the window server is the only word
            guard !WindowBook.anyGone(Set(next.windows.map(\.windowId))) else { stale = true; schedule(after: 0.04); return }
            publish(next)
        case .refresh:
            schedule(after: 0.04)
        case .staleRefresh:
            stale = true
            schedule(after: 0.04)
        case .readBindings:
            stale = true
            schedule(after: 0.04)
            readBindings()
        }
    }

    /// The binding table again, for a binding the last one did not explain (a binding added or changed in the config).
    private func readBindings() {
        guard let answer = run(RiskellWM.AeroSpace.bindingTableQuery),
              let table = RiskellWM.AeroSpace.parse(bindings: answer.stdout) else { return }
        bindings = table
    }

    // MARK: refresh (io, then main)
    /// One request: the commands (if any), then the queries that read back what they left. The first refresh of a connection also asks
    /// for the focused window and the binding table, which no event reports.
    private func refresh(_ commands: [[String]] = [], seed: Bool = false, force: Bool = false) {
        guard running else { return }
        let queries = [RiskellWM.AeroSpace.workspaceQuery, RiskellWM.AeroSpace.windowQuery]
        let ask = seed ? [RiskellWM.AeroSpace.bindingTableQuery, RiskellWM.AeroSpace.focusedWindowQuery] + queries : queries
        guard let answer = run(RiskellWM.AeroSpace.evalArgs(commands + ask)),
              let next = RiskellWM.AeroSpace.parse(refresh: answer.stdout, seed: seed) else {
            if !warned { warned = true; print("aerospace: query failed (is AeroSpace running?)"); fflush(stdout) }
            return
        }
        let before = rows
        rows = next.rows
        stale = false
        if seed {
            bindings = next.bindings
            // the queries do not say which window has focus; the events do, so only the first refresh asks
            focused = next.focusedWindow
            let focus = next.focusedWindow
            DispatchQueue.main.async { [weak self] in self?.focusedWindow = focus }
        }
        publish(next.rows, force: force)
        arrivals(from: before)
        let due = deferred
        deferred = []
        for event in due { handle(event, justRefreshed: true) }
    }

    // MARK: hooks (io)
    /// True when a running behaviour wants this event (by AeroSpace's name).
    private func hooksWant(_ name: String) -> Bool { hooks.contains { $0.events.contains(name) } }
    /// True when a running behaviour wants this very event: it lists its name and, among the many variants of a frequent one (a key binding), it
    /// wants this one. A key that no hook cares about then costs nothing, not even a refresh of the rows.
    private func hooksWant(_ event: ManagerEvent) -> Bool { hooks.contains { $0.events.contains(event.name) && $0.wants(event) } }

    /// Calls the hooks that want `event`, and sends what they return at once (not on the next coalesced refresh): one `eval` per window
    /// they act on, the queries at the end of the last one. true when they sent something, so the event needs nothing more from the
    /// backend's own handling. A hook that returns nothing changes nothing, and the event is handled as it always was.
    private func runHooks(_ event: ManagerEvent) -> Bool {
        // a hook that acts on a few of the many key bindings says so here, before anything is asked of the window server
        let wanting = hooks.filter { $0.events.contains(event.name) && $0.wants(event) }
        guard !wanting.isEmpty, let rows else { return false }
        // one window-server call answers both questions: which windows are gone, and where the ones that show are (only for a hook that asked)
        let seen = WindowBook.look(at: Set(rows.windows.map(\.windowId)), frames: wanting.contains { $0.needsFrames(for: event) })
        let state = RiskellWM.AeroSpace.managerState(rows: rows, focusedWindow: focused, landscape: landscape,
                                                      gone: seen.gone, frames: seen.frames)
        let commands = wanting.flatMap { $0.commands(for: event, in: state) }
        guard !commands.isEmpty else { return false }
        send(commands, first: nil)
        return true
    }

    /// The hook commands in the requests they travel in, riskell's own `first` command in front. Only the last request carries the
    /// queries and only its answer is read, applied like any refresh; an earlier one is sent for its effect alone. `expected` is the one
    /// arrival riskell caused itself, which it announced to the hooks before sending.
    private func send(_ commands: [ManagerCommand], first: [String]?, expecting expected: (window: Int, workspace: String)? = nil) {
        let queries = [RiskellWM.AeroSpace.workspaceQuery, RiskellWM.AeroSpace.windowQuery]
        let requests = RiskellWM.AeroSpace.hookRequests(commands, queries: queries, first: first)
        for (i, request) in requests.enumerated() {
            guard let answer = run(request.args, window: request.window, quiet: i < requests.count - 1) else { continue }
            if i == requests.count - 1 { refreshed(answer.stdout, expecting: expected) }
        }
    }

    /// A query answer that came with a command riskell or a hook sent: the rows and the bar, and one arrival riskell itself caused. No
    /// arrival pass otherwise: an answer to a hook's request shows what the hook just did, and comparing it would let one hook round start
    /// another.
    private func refreshed(_ stdout: String, expecting expected: (window: Int, workspace: String)?) {
        guard let next = RiskellWM.AeroSpace.parse(refresh: stdout, seed: false) else { return }
        let before = rows
        rows = next.rows
        stale = false
        publish(next.rows)
        if let expected { arrivals(from: before, ignoring: expected) }
    }

    /// The windows this answer shows as having arrived, handed to the hooks that asked for that event. They are sent at once, so the
    /// manager lays the windows out once for both the arrival and the queries that read it.
    private func arrivals(from before: RiskellWM.AeroSpace.Rows?, ignoring expected: (window: Int, workspace: String)? = nil) {
        guard let before, let after = rows, hooksWant(ManagerEvent.windowArrived) else { return }
        for event in RiskellWM.AeroSpace.arrivals(from: before, to: after, ignoring: expected) { _ = runHooks(event) }
    }

    /// The bar shows the parse of `rows`, whether they came from a query or were edited by an event.
    private func publish(_ rows: RiskellWM.AeroSpace.Rows, force: Bool = false) {
        let next = RiskellWM.AeroSpace.parse(rows: rows)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started else { return }
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
    /// One request: the command, then the queries that say what it left.
    private func command(_ args: [String]) { io.async { [weak self] in self?.refresh([args]) } }

    /// The Store first (the rail moves at once), then AeroSpace; its answer confirms it.
    func focus(space: Int) {
        let until = CACurrentMediaTime() + 1.0
        intent = (space, until)
        // If AeroSpace never went there, the rail returns to the real workspace. Only while this switch is still unconfirmed: once an
        // answer confirmed it, or another switch replaced it, the timer has nothing to ask.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, let it = self.intent, it.space == space, it.until == until else { return }
            self.requestRefresh()
        }
        store.focusNow(space: space)
        rememberShown()
        command(["workspace", String(space)])
    }
    func focus(window id: Int) {
        rememberShown()
        command(["focus", "--window-id", String(id)])
    }
    func close(window id: Int) {
        io.async { [weak self] in
            self?.run(["close", "--window-id", String(id)])
            self?.schedule(after: 0.15)         // AeroSpace reports no event for a closed window
        }
    }
    func move(window id: Int, toSpace space: Int) {
        rememberShown()
        io.async { [weak self] in self?.moveNow(window: id, toSpace: space) }
    }

    /// The move, with the hooks' answer to the arrival in the same `eval`: the window arrives on the target workspace as far as they are
    /// concerned, so they can join it there. The rows are left as they are until the answer says what the move did: if AeroSpace refused
    /// it (a native-fullscreen window, say), nothing claims the window arrived, and the one arrival the answer may still show for the move
    /// is dropped because the hooks were already told about it. The state they see counts the window on neither workspace, because it is
    /// on neither for as long as the move runs.
    private func moveNow(window id: Int, toSpace space: Int) {
        let move = ["move-node-to-workspace", "--window-id", String(id), String(space)]
        var commands: [ManagerCommand] = []
        var expected: (window: Int, workspace: String)?
        if let rows, hooksWant(ManagerEvent.windowArrived) {
            let state = RiskellWM.AeroSpace.without(id, in: RiskellWM.AeroSpace.managerState(
                rows: rows, focusedWindow: focused, landscape: landscape,
                gone: WindowBook.gone(Set(rows.windows.map(\.windowId)))))
            let event = ManagerEvent(name: ManagerEvent.windowArrived, fields: ["windowId": String(id), "workspace": String(space)])
            commands = hooks.filter { $0.events.contains(ManagerEvent.windowArrived) }.flatMap { $0.commands(for: event, in: state) }
            expected = (id, String(space))
        }
        send(commands, first: move, expecting: expected)
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
