import AppKit
import RiskellKit
import RiskellWM

/// yabai backend. EXPERIMENTAL and UNVERIFIED: written against yabai's CLI and never run by the maintainer.
/// Reads happen on events only (no polling): yabai signals write a word to riskell's own unix stream socket through `nc -U`, and a burst
/// of events coalesces into one `query` round. Everything that talks to yabai runs on `io`, never on the main thread; each call is
/// bounded to 3 s. Signals are registered under riskell's own labels and removed in stop(). The scripting addition is not needed
/// for anything used here (queries, focus, move, close, padding).
final class Yabai: WindowManager {
    let name = "yabai"
    let ownsSwipe = false           // yabai does not own the swipe; riskell's Touch switches workspaces

    static let candidates = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]
    static var installed: Bool { candidates.contains { FileManager.default.isExecutableFile(atPath: $0) } }
    static let events = ["space_changed", "space_created", "space_destroyed", "display_changed", "window_created", "window_destroyed",
                         "window_moved", "window_focused", "window_minimized", "window_deminimized", "application_front_switched"]
    static var socketPath: String { NSHomeDirectory() + "/.cache/riskell/yabai.sock" }

    // the wire types are RiskellWM's (Yabai.parse decodes the three streams without running yabai)

    // MARK: state
    private let store: Store
    private let io = DispatchQueue(label: "riskell.yabai")
    private var started = false                      // main
    private var frames: [Int: WinFrame] = [:]        // main: read by the overview
    private var listener: DispatchSourceRead?       // io
    private var scheduled = false                   // io: a query is already queued
    private var applied: [String: Int] = [:]        // io: padding values yabai has, so unchanged values are not sent again

    init(store: Store) { self.store = store }

    // MARK: lifecycle
    func start() {
        guard Yabai.installed else {
            print("yabai: not installed (no binary at /opt/homebrew/bin/yabai or /usr/local/bin/yabai), workspaces stay empty")
            return
        }
        started = true
        print("wm: yabai backend is experimental and unverified"); fflush(stdout)
        io.async { [weak self] in
            self?.openListener()
            self?.registerSignals()
            self?.query()
        }
    }

    func stop() {
        guard started else { return }
        started = false
        unlink(Yabai.socketPath)
        io.async { [weak self] in self?.closeListener() }
        // launched without waiting: the removals must not hold up the exit, and a missed one is only a stale riskell_* label
        for ev in Yabai.events { Yabai.spawn(["-m", "signal", "--remove", Yabai.label(ev)]) }
    }

    func requestRefresh() {
        io.async { [weak self] in
            guard let self, !self.scheduled else { return }
            self.scheduled = true
            self.io.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.scheduled = false
                self?.query()
            }
        }
    }

    // MARK: signals and the event socket (io)
    private static func label(_ ev: String) -> String { "riskell_\(ev)" }

    private func registerSignals() {
        for ev in Yabai.events {
            Yabai.run(["-m", "signal", "--remove", Yabai.label(ev)])
            let action = "/usr/bin/printf %s \(ev) | /usr/bin/nc -U -w1 '\(Yabai.socketPath)'"
            Yabai.run(["-m", "signal", "--add", "event=\(ev)", "label=\(Yabai.label(ev))", "action=\(action)"])
        }
    }

    private func openListener() {
        let path = Yabai.socketPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        guard path.utf8.count < 104 else { print("yabai: socket path too long"); return }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("yabai: socket failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) } }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd); unlink(path); print("yabai: socket bind failed"); return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        src.setEventHandler { [weak self] in
            let c = Darwin.accept(fd, nil, nil)
            guard c >= 0 else { return }
            var tv = timeval(tv_sec: 0, tv_usec: 200_000)           // a silent client must not stall the queue
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buf = [UInt8](repeating: 0, count: 64)
            _ = Darwin.recv(c, &buf, buf.count, 0)                    // the word is not needed: any event means "look again"
            Darwin.close(c)
            self?.requestRefresh()
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        listener = src
    }

    private func closeListener() {
        listener?.cancel(); listener = nil
        unlink(Yabai.socketPath)
    }

    // MARK: queries (io), then the Store on main
    private func query() {
        guard let dd = Yabai.run(["-m", "query", "--displays"]),
              let sd = Yabai.run(["-m", "query", "--spaces"]),
              let wd = Yabai.run(["-m", "query", "--windows"]),
              let snapshot = RiskellWM.Yabai.parse(displays: dd, spaces: sd, windows: wd) else {
            print("yabai: query failed (is yabai running?)"); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frames = snapshot.frames
            self.store.set(windows: snapshot.windows)
            guard !snapshot.spaces.isEmpty else { return }
            let old = self.store.focusedIndex
            self.store.set(spaces: snapshot.spaces)
            if old != self.store.focusedIndex { Touch.shared?.spaceChanged(from: old, to: self.store.focusedIndex) }
        }
    }

    // MARK: commands
    /// The Store first (the rail moves at once), then yabai; the signal that follows confirms it.
    func focus(space: Int) {
        store.focusNow(space: space)
        io.async { [weak self] in
            Yabai.run(["-m", "space", "--focus", String(space)])
            self?.requestRefresh()
        }
    }
    func focus(window id: Int) { io.async { Yabai.run(["-m", "window", "--focus", String(id)]) } }
    func close(window id: Int) { io.async { Yabai.run(["-m", "window", String(id), "--close"]) } }
    func move(window id: Int, toSpace space: Int) {
        io.async { [weak self] in
            Yabai.run(["-m", "window", String(id), "--space", String(space)])
            self?.requestRefresh()
        }
    }
    /// A new space (yabai appends it), then the window into it: its index is the one after the last shown.
    func moveToNewSpace(window id: Int, after count: Int) {
        io.async { [weak self] in
            Yabai.run(["-m", "space", "--create"])
            Yabai.run(["-m", "window", String(id), "--space", String(count + 1)])
            self?.requestRefresh()
        }
    }

    func windowFrames() -> [Int: WinFrame] { frames }

    // MARK: outer padding (the same numbers Gaps gives OmniWM)
    /// Sets yabai's outer padding from the bars that are on. The values are read on the caller's thread (main) and sent on `io`; only a
    /// value that differs from the last one sent is written.
    func reserve(_ config: Config) {
        let want: [(String, Int)] = [("left_padding", Int(config.gapLeft.rounded())), ("right_padding", Int(config.gapRight.rounded())),
                                     ("bottom_padding", Int(config.gapBottom.rounded())), ("top_padding", Int(Config.gapTop.rounded()))]
        io.async { [weak self] in
            guard let self else { return }
            for (key, v) in want where self.applied[key] != v {
                if Yabai.run(["-m", "config", key, String(v)]) != nil { self.applied[key] = v }
            }
        }
    }

    // MARK: processes
    private static let env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        // a GUI app inherits a short PATH; yabai is usually under Homebrew
        e["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        return e
    }()
    private static var orphans: [Process] = []      // kept alive until the process exits (see stop())

    /// One yabai call, waited for. Callers are on `io`, never the main thread. nil on failure, or after 3 s (the process is then killed).
    @discardableResult
    static func run(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["yabai"] + args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { return nil }
        try? out.fileHandleForWriting.close()       // only the child holds the write end, so the read below ends with the child
        let box = DataBox(), done = DispatchSemaphore(value: 0)
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

    /// Launches one yabai call and does not wait for it.
    static func spawn(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["yabai"] + args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        orphans.append(p)
    }
}

/// Carries a result from the reader thread back to the caller (only read after the semaphore has been signalled).
private final class DataBox { var data = Data() }
