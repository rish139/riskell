import Foundation
import RiskellKit

/// Generic command backend: any window manager, or a plain script, drives the rail through the user's own commands in config.json
/// (`"wm": "command"`, `"wmCommand": {…}`, docs/WM-COMMAND.md). No Swift per manager. `state` prints one line of JSON; the actions run
/// the user's commands with the numbers substituted. Reads are event-driven: on start, on a macOS Space change, after each action, when a
/// script writes `wm` to the event socket, and on a timer only when `every` is set (2 s at least). Every command runs on one serial queue,
/// so one runs at a time and a read never races an action. Results reach the Store on main, and the Store publishes only what changed.
final class CommandWM: WindowManager {
    let name = "command"
    let ownsSwipe = false           // the user's manager may own its gesture; riskell's Touch switches the rail

    /// What `state` printed, as the Store wants it.
    struct Snapshot: Equatable {
        var spaces: [SpaceInfo]
        var windows: [WinInfo]

        private struct Wire: Decodable {
            struct Space: Decodable { let id: Int; let focused: Bool?; let windows: Int? }
            struct Win: Decodable { let id: Int; let pid: Int?; let app: String?; let title: String?; let space: Int?; let focused: Bool? }
            let spaces: [Space]?
            let windows: [Win]?
        }

        /// The first line of `text` as the state JSON; nil when it is not one (the caller keeps the last good state).
        static func parse(_ text: String) -> Snapshot? {
            guard let line = text.split(whereSeparator: \.isNewline).first,
                  let w = try? JSONDecoder().decode(Wire.self, from: Data(line.utf8)) else { return nil }
            let wins = (w.windows ?? []).map {
                WinInfo(id: $0.id, pid: $0.pid ?? 0, app: $0.app ?? "", title: $0.title ?? "", space: $0.space ?? 0, focused: $0.focused ?? false)
            }
            let spaces = (w.spaces ?? []).map { s -> SpaceInfo in
                let focused = s.focused ?? false
                let count = s.windows ?? wins.filter { $0.space == s.id }.count
                return SpaceInfo(id: s.id, focused: focused, visible: focused, windows: count, fullscreen: false)
            }
            return Snapshot(spaces: spaces, windows: wins)
        }
    }

    private let store: Store
    private let io = DispatchQueue(label: "riskell.command-wm")   // serial: every user command runs here, one at a time
    private var cfg: AppConfig.WMCommand?          // main
    private var timer: DispatchSourceTimer?        // main; only with `every`
    private var scheduled = false                  // main: a read is waiting out its 50 ms
    private var running = false                    // main
    private var shown: Snapshot?                   // main: the last good state
    private var failing = false                    // main: the last read failed (logged once, not per read)

    init(store: Store) { self.store = store }

    // MARK: lifecycle
    func start() {
        running = true
        cfg = AppConfig.shared.wmCommand
        if cfg?.state?.isEmpty != false { print("wm: command backend waiting for wmCommand.state in config.json (docs/WM-COMMAND.md)"); fflush(stdout) }
        else { print("wm: command backend (user scripts)"); fflush(stdout) }
        arm()
        requestRefresh()
    }

    func stop() {
        running = false
        timer?.cancel(); timer = nil
    }

    /// config.json's `wmCommand` changed: the commands and the timer change, nothing restarts.
    func reconfigure() {
        cfg = AppConfig.shared.wmCommand
        arm()
        requestRefresh()
    }

    /// Coalesced: a burst of requests (a Space change and a script's word at once) becomes one read 50 ms later.
    func requestRefresh() {
        guard running, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.read()
        }
    }

    // MARK: actions (the Store first where the rail can move at once; the next read confirms)
    func focus(space: Int) {
        store.focusNow(space: space)
        act(cfg?.focusSpace, space: space)
    }
    func focus(window id: Int) { act(cfg?.focusWindow, window: id) }
    func close(window id: Int) { act(cfg?.closeWindow, window: id) }
    func move(window id: Int, toSpace space: Int) { act(cfg?.moveWindow, window: id, space: space) }
    /// The number after the last one the rail shows; the user's `moveWindow` decides whether that workspace is created.
    func moveToNewSpace(window id: Int, after count: Int) { act(cfg?.moveWindow, window: id, space: count + 1) }

    /// Runs one action command with its numbers substituted (integers only, so nothing can be injected), then asks for a fresh state.
    /// An absent action is a no-op.
    private func act(_ template: String?, window: Int? = nil, space: Int? = nil) {
        guard running, var cmd = template, !cmd.isEmpty else { return }
        if let space { cmd = cmd.replacingOccurrences(of: "{space}", with: String(space)) }
        if let window { cmd = cmd.replacingOccurrences(of: "{window}", with: String(window)) }
        io.async { [weak self] in
            if Pills.shell(cmd) == nil { print("wm: command failed: \(cmd)"); fflush(stdout) }
            DispatchQueue.main.async { self?.requestRefresh() }
        }
    }

    // MARK: reads (io, then the Store on main)
    private func read() {
        guard running, let state = cfg?.state, !state.isEmpty else { return }
        io.async { [weak self] in
            let snap = Pills.shell(state, limit: 1 << 20).flatMap(Snapshot.parse)
            DispatchQueue.main.async { self?.apply(snap) }
        }
    }

    private func apply(_ snap: Snapshot?) {
        guard let snap else {
            if !failing { failing = true; print("wm: command state failed or is not one line of JSON, keeping the last state"); fflush(stdout) }
            return
        }
        failing = false
        if snap != shown {
            shown = snap
            print("wm: command state: \(snap.spaces.count) spaces, \(snap.windows.count) windows"); fflush(stdout)
        }
        // set every time: the Store ignores an unchanged value, and a focus shown optimistically by focus(space:) is corrected here
        let old = store.focusedIndex
        store.set(windows: snap.windows)
        store.set(spaces: snap.spaces)
        if old != store.focusedIndex { Touch.shared?.spaceChanged(from: old, to: store.focusedIndex) }
    }

    /// The timer that re-reads the state, only when `every` is set (never faster than every 2 s).
    private func arm() {
        timer?.cancel(); timer = nil
        guard running, let every = cfg?.every, every > 0, cfg?.state?.isEmpty == false else { return }
        let s = max(2, every)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + s, repeating: s, leeway: .milliseconds(Int(s * 100)))
        t.setEventHandler { [weak self] in self?.requestRefresh() }
        t.resume(); timer = t
    }
}
