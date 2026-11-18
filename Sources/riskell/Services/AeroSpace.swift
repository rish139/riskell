import AppKit
import RiskellKit
import RiskellWM

/// AeroSpace backend. EXPERIMENTAL and UNVERIFIED: written against AeroSpace's CLI and never run by the maintainer.
/// AeroSpace has no subscription API riskell can rely on, so the user adds two callbacks to their aerospace.toml that write the word
/// `aerospace` to riskell's own event socket (`~/.cache/riskell/ev.sock`, the same socket the debug and bar commands use). riskell never
/// edits that file. A burst of events coalesces into one refresh; nothing is polled. Everything that talks to AeroSpace runs on `io`,
/// never on the main thread, and each call is bounded to 3 s.
///
/// Callbacks for aerospace.toml (see docs/COMPATIBILITY.md):
///     exec-on-workspace-change = ['/bin/bash', '-c', 'printf aerospace | nc -U ~/.cache/riskell/ev.sock']
///     on-focus-changed = ['exec-and-forget', 'printf aerospace | nc -U ~/.cache/riskell/ev.sock']
/// Outer gaps (the bars' room) also live in aerospace.toml under [gaps]; start() logs the values to use.
final class AeroSpace: WindowManager {
    let name = "aerospace"
    let ownsSwipe = false           // AeroSpace does not own the swipe; riskell's Touch switches workspaces

    static let candidates = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    static var installed: Bool { candidates.contains { FileManager.default.isExecutableFile(atPath: $0) } }
    /// The word the aerospace.toml callbacks write to riskell's event socket.
    static let eventWord = "aerospace"

    // the wire types are RiskellWM's (AeroSpace.parse decodes one refresh without running the CLI)

    // MARK: state
    private let store: Store
    private let io = DispatchQueue(label: "riskell.aerospace")
    private var started = false                      // main
    private var scheduled = false                    // io: a refresh is already queued

    init(store: Store) { self.store = store }

    // MARK: lifecycle
    func start() {
        guard AeroSpace.installed else {
            print("aerospace: not installed (no binary at /opt/homebrew/bin/aerospace or /usr/local/bin/aerospace), workspaces stay empty")
            return
        }
        started = true
        print("wm: aerospace backend is experimental and unverified"); fflush(stdout)
        // the word the aerospace.toml callbacks write; the socket calls its handlers on main
        events.commands[AeroSpace.eventWord] = { [weak self] in self?.requestRefresh() }
        let c = Config.shared
        print("aerospace: riskell does not edit aerospace.toml; set under [gaps]: outer.left = \(Int(c.gapLeft.rounded())), outer.right = \(Int(c.gapRight.rounded())), outer.bottom = \(Int(c.gapBottom.rounded())), outer.top = \(Int(Config.gapTop.rounded()))")
        fflush(stdout)
        io.async { [weak self] in self?.refresh() }
    }

    func stop() {
        guard started else { return }
        started = false
        events.commands[AeroSpace.eventWord] = nil
    }

    /// Coalesced: a burst of callbacks (a fast run of focus changes) becomes one refresh 50 ms after the first.
    func requestRefresh() {
        io.async { [weak self] in
            guard let self, !self.scheduled else { return }
            self.scheduled = true
            self.io.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.scheduled = false
                self?.refresh()
            }
        }
    }

    // MARK: queries (io), then the Store on main
    private func refresh() {
        guard let wsData = AeroSpace.run(["list-workspaces", "--all", "--json"]),
              let wd = AeroSpace.run(["list-windows", "--all", "--json"]),
              let focusedWS = AeroSpace.lines(["list-workspaces", "--focused"]),
              let visibleWS = AeroSpace.lines(["list-workspaces", "--visible"]),
              // the focused window is optional: AeroSpace may print nothing when no window has focus
              let snapshot = RiskellWM.AeroSpace.parse(workspaces: wsData, windows: wd,
                                                       focusedWindow: AeroSpace.run(["list-windows", "--focused", "--json"]),
                                                       focusedWorkspace: focusedWS, visibleWorkspaces: visibleWS) else {
            print("aerospace: query failed (is AeroSpace running?)"); fflush(stdout); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started else { return }
            self.store.set(windows: snapshot.windows)
            guard !snapshot.spaces.isEmpty else { return }
            let old = self.store.focusedIndex
            self.store.set(spaces: snapshot.spaces)
            if old != self.store.focusedIndex { Touch.shared?.spaceChanged(from: old, to: self.store.focusedIndex) }
        }
    }

    // MARK: commands
    /// The Store first (the rail moves at once), then AeroSpace; the callback that follows confirms it.
    func focus(space: Int) {
        store.focusNow(space: space)
        io.async { [weak self] in
            AeroSpace.run(["workspace", String(space)])
            self?.requestRefresh()
        }
    }
    func focus(window id: Int) { io.async { AeroSpace.run(["focus", "--window-id", String(id)]) } }
    func close(window id: Int) { io.async { AeroSpace.run(["close", "--window-id", String(id)]) } }
    func move(window id: Int, toSpace space: Int) {
        io.async { [weak self] in
            AeroSpace.run(["move-node-to-workspace", "--window-id", String(id), String(space)])
            self?.requestRefresh()
        }
    }
    /// AeroSpace creates workspaces on demand, so the one after the last shown is simply named `count + 1`.
    func moveToNewSpace(window id: Int, after count: Int) {
        move(window: id, toSpace: count + 1)
    }

    // MARK: rail geometry
    /// AeroSpace's outer gaps are set in aerospace.toml [gaps], which riskell does not edit (start() logs the values).
    func reserve(_ config: Config) {}

    // MARK: processes
    private static let env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        // a GUI app inherits a short PATH; aerospace is usually under Homebrew
        e["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        return e
    }()

    /// One aerospace call, waited for. Callers are on `io`, never the main thread. nil on failure, or after 3 s (the process is then killed).
    @discardableResult
    static func run(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["aerospace"] + args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { return nil }
        try? out.fileHandleForWriting.close()       // only the child holds the write end, so the read below ends with the child
        let box = AeroDataBox(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + 3) == .success else {
            p.terminate(); _ = done.wait(timeout: .now() + 1)
            return nil
        }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? box.data : nil
    }

    /// The non-empty lines of a plain-text call (`list-workspaces --focused` prints names, not JSON).
    static func lines(_ args: [String]) -> [String]? {
        run(args).flatMap { RiskellWM.AeroSpace.lines($0) }
    }
}

/// Carries a result from the reader thread back to the caller (only read after the semaphore has been signalled).
private final class AeroDataBox { var data = Data() }
