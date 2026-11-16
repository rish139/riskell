import Foundation
import SwiftUI
import RiskellKit

/// Script pills: an atom defined in config.json by a shell command, no Swift. The command prints either one plain line of text (further
/// lines fill the hover card) or one line of JSON `{"text":"up","icon":"lock.fill","tone":"ok","value":0.7,"lines":["…"]}`.
/// `tone` is ok / warn / crit / accent / dim; `value` (0...1) draws a gauge; `icon` is an SF Symbol name.
///
///     "pills": [ { "id": "vpn", "name": "VPN", "run": "~/bin/vpn-status", "every": 10, "click": "open -a Tunnelblick" } ]
///
/// A pill's command runs only while the pill is on a bar that is showing, off the main thread, one run at a time, killed after 10 s;
/// a failed run keeps the last reading and dims it. Nothing is polled faster than every 2 s. `watch` (a file path) re-runs the command when
/// that file changes; with `watch` and no `every` a pill is purely event-driven. The commands are the user's own, from their own config.
///
/// `stream` instead of `run`: one long-running command whose every line is a reading (see PillStream). A pill has `run` or `stream`, not both.
struct PillSpec: Codable, Equatable {
    var id: String
    var name: String?
    var run: String?
    var stream: String?
    var every: Double?
    var watch: String?
    var click: String?
    /// How many of the pill's own `value`s riskell remembers for a sparkline, 8...120 (clamped). Absent: no history.
    var history: Int?
}

/// A pill's reading is the kit's `Reading`; its one text form is parsed here (the JSON a command prints is a Reading in text).
typealias PillReading = Reading
typealias PillValue = Metric

extension Reading {
    /// nil: nothing usable on stdout.
    static func parse(_ out: String) -> PillReading? {
        let rows = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = rows.first else { return nil }
        func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
        // a JSON string or number as text, nil for anything else
        func str(_ x: Any?) -> String? { (x as? String) ?? (x as? NSNumber).map { "\($0)" } }
        if first.hasPrefix("{") {
            guard let j = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any] else { return nil }
            let text = str(j["text"]) ?? ""
            let value = (j["value"] as? NSNumber).map { min(1, max(0, $0.doubleValue)) }
            let lines = ((j["lines"] as? [Any]) ?? []).prefix(16).map { clip("\($0)", 80) }
            let values = ((j["values"] as? [[String: Any]]) ?? []).prefix(3).map { v in
                Metric(label: clip(str(v["label"]) ?? "", 12), text: clip(str(v["text"]) ?? "", 10), unit: str(v["unit"]).map { clip($0, 4) },
                          tone: (v["tone"] as? String).map(Tone.init(name:)), value: (v["value"] as? NSNumber).map { min(1, max(0, $0.doubleValue)) })
            }
            let spark = ((j["spark"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }.suffix(120)
            // the grid gets what the card has left of the 16 rows after `lines`, 8 rows at most
            let room = min(8, max(0, 16 - lines.count))
            let grid = ((j["grid"] as? [Any]) ?? []).compactMap { row -> [String]? in
                guard let cells = row as? [Any], let label = cells.first else { return nil }
                return [clip(str(label) ?? "", 28), clip(cells.count > 1 ? (str(cells[1]) ?? "") : "", 28)]
            }.prefix(room)
            return Reading(text: clip(text, 24), icon: j["icon"] as? String, tone: (j["tone"] as? String).map(Tone.init(name:)), value: value, lines: lines,
                               values: values, spark: Array(spark), grid: Array(grid))
        }
        return Reading(text: clip(first, 24), lines: rows.dropFirst().prefix(16).map { clip($0, 80) })
    }
}

/// What every reading-drawn atom keeps (a pill's, an extension's): the reading, whether it is stale, and a history for a sparkline.
final class PillModel: ObservableObject {
    @Published var reading: PillReading?
    @Published var stale = false
    /// The last `value`s, newest last, when a history is wanted. Not published: `sparkTick` changes at most once a second.
    var history: [Double] = []
    @Published var sparkTick = 0
    /// When the last good reading arrived; the card shows its age when it opens (no timer).
    var updated: Date?
    private var lastSample = Date.distantPast

    /// A good reading: shown, and the atom is no longer stale. A reading that draws the same as the one shown (see `drawn`) is not published.
    /// `history` is how many values to remember for a sparkline (nil: none).
    func apply(_ r: PillReading, history h: Int?) {
        if reading.map({ $0.drawn != r.drawn }) ?? true { reading = r }
        if stale { stale = false }
        updated = Date()
        if let h, let v = r.value {
            // the history takes one sample a second at most, whatever the line rate; the sparkline is redrawn when it takes one
            let now = Date()
            if now.timeIntervalSince(lastSample) >= 1 {
                lastSample = now
                let n = min(120, max(8, h))
                history.append(v)
                if history.count > n { history.removeFirst(history.count - n) }
                sparkTick &+= 1
            }
        }
    }
}

/// What a reading-drawn atom needs from whatever feeds it: a pill's runner, or an extension's.
protocol ReadingSource: AnyObject {
    var model: PillModel { get }
    var title: String { get }
    /// The popout card's id.
    var cardID: String { get }
    var keepsHistory: Bool { get }
    func attach()
    func detach()
    func click()
}

final class PillRunner: ReadingSource {
    let spec: PillSpec
    let model = PillModel()
    private var refs = 0
    private var timer: DispatchSourceTimer?
    private var watch: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var running = false
    private var stream: PillStream?      // the process of a `stream` pill, while it is on a bar
    private let q = DispatchQueue(label: "riskell.pill", qos: .utility)

    init(_ spec: PillSpec) { self.spec = spec }
    var title: String { spec.name ?? spec.id }
    var cardID: String { "pill." + spec.id }
    var keepsHistory: Bool { spec.history != nil }

    /// The atom appeared on a bar / left it: the command runs only between the first and the last.
    func attach() { refs += 1; if refs == 1 { start() } }
    func detach() { refs = max(0, refs - 1); if refs == 0 { stop() } }

    private func start() {
        if let cmd = spec.stream {
            let s = PillStream(id: spec.id, cmd: cmd, history: spec.history != nil, onReading: { [weak self] in self?.apply($0) }, onDown: { [weak self] in self?.model.stale = true })
            stream = s; s.start(); return
        }
        runNow()
        if spec.every != nil || spec.watch == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            let every = max(2, spec.every ?? 30)
            t.schedule(deadline: .now() + every, repeating: every, leeway: .milliseconds(Int(every * 100)))
            t.setEventHandler { [weak self] in self?.runNow() }
            t.resume(); timer = t
        }
        if spec.watch != nil { arm() }
    }
    private func stop() {
        timer?.cancel(); timer = nil; watch?.cancel(); watch = nil; debounce?.cancel()
        stream?.stop(); stream = nil
    }

    fileprivate func apply(_ r: PillReading) { model.apply(r, history: spec.history) }

    private func arm() {
        watch?.cancel(); watch = nil
        guard refs > 0, let path = spec.watch.map(Pills.expand) else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.arm() }; return }      // not there yet
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.debounce?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.runNow(); self?.arm() }
            self.debounce = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume(); watch = src
    }

    func runNow() {
        guard let run = spec.run, !running else { return }
        running = true
        q.async {
            let out = Pills.shell(run)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
                if let out, let r = PillReading.parse(out) { self.apply(r) }
                else if !self.model.stale { self.model.stale = true }
            }
        }
    }

    func click() {
        guard let c = spec.click else { return }
        q.async { [weak self] in
            _ = Pills.shell(c)
            DispatchQueue.main.async { self?.runNow() }      // a stream pill has no run: its next line brings the change
        }
    }
}

/// The `stream` command of a pill: one long-running process, no polling, no timer while it runs. Every line it prints is a reading (the same
/// parse as a run's output, one line at a time; lines over 8 KB are dropped). Lines are read on the process's reader queue; the newest one is
/// handed to the main thread at most 10 times a second, so a fast stream costs at most that many redraws. When the process exits it is
/// restarted after 1, 2, 4 ... s (at most 30 s apart); a run of 60 s or more starts the backoff again. `stop()` kills it and its children.
final class PillStream {
    private let id: String, cmd: String
    private let history: Bool                         // the spec has a history: its readings are rich
    private let onReading: (PillReading) -> Void      // main thread
    private let onDown: () -> Void                    // main thread: the process went away; the pill is stale until a line comes
    private var proc: Process?
    private var alive = false
    private var failures = 0, started = Date.distantPast
    private var restart: DispatchWorkItem?
    private var lastSent = Date.distantPast           // main thread only
    private let lock = NSLock()
    private var latest: PillReading?, scheduled = false      // guarded by lock
    private var gap = 0.1                                    // seconds between deliveries: 0.25 for a rich pill (4 a second)

    init(id: String, cmd: String, history: Bool, onReading: @escaping (PillReading) -> Void, onDown: @escaping () -> Void) {
        self.id = id; self.cmd = cmd; self.history = history; self.onReading = onReading; self.onDown = onDown
    }

    /// Main thread.
    func start() { alive = true; failures = 0; launch() }

    /// Main thread: the process is killed with its children, and nothing is restarted.
    func stop() {
        alive = false
        restart?.cancel(); restart = nil
        guard let p = proc else { return }
        proc = nil
        PillStream.live.remove(p.processIdentifier)
        Pills.killChildren(p.processIdentifier)
        p.terminate()      // the termination handler then finds nothing to do
    }

    /// The stream processes running now (main thread). A process that is silent would otherwise outlive riskell: it only notices a closed
    /// pipe when it next writes. So when riskell exits (atexit), every one of them is killed with its children.
    static var live = Set<Int32>()
    private static var exitHook = false
    static func killAllAtExit() { for pid in live { Pills.killChildren(pid); kill(pid, SIGKILL) } }

    /// Main thread.
    private func launch() {
        guard alive else { return }
        let p = Pills.process(cmd)
        let pipe = Pipe(); p.standardOutput = pipe
        let rd = pipe.fileHandleForReading
        var buf = Data(), skipping = false      // only the reader queue touches these
        let limit = 8192
        rd.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }      // end of output
            buf.append(d)
            while let nl = buf.firstIndex(of: 10) {
                let line = buf[buf.startIndex..<nl]
                if !skipping, line.count <= limit, let r = PillReading.parse(String(decoding: line, as: UTF8.self)) { self?.deliver(r) }
                skipping = false
                buf.removeSubrange(buf.startIndex...nl)
            }
            if buf.count > limit { buf.removeAll(); skipping = true }      // a line over the cap: dropped up to its newline
        }
        p.terminationHandler = { [weak self] p in DispatchQueue.main.async { self?.exited(p) } }
        started = Date()
        do { try p.run() } catch {
            rd.readabilityHandler = nil
            print("pills: \(id) stream did not start"); fflush(stdout)
            down(); return
        }
        proc = p
        PillStream.live.insert(p.processIdentifier)
        if !PillStream.exitHook { PillStream.exitHook = true; atexit { PillStream.killAllAtExit() } }
    }

    /// Main thread: the process ended on its own (not by `stop`).
    private func exited(_ p: Process) {
        p.terminationHandler = nil      // breaks the handler's reference to the process
        guard alive, p === proc else { return }
        proc = nil
        PillStream.live.remove(p.processIdentifier)
        print("pills: \(id) stream exited"); fflush(stdout)
        down()
    }

    /// Main thread: stale now, and the next start after the backoff (1, 2, 4 ... s, at most 30 s).
    private func down() {
        onDown()
        if Date().timeIntervalSince(started) >= 60 { failures = 0 }
        let delay = min(30, pow(2, Double(failures)))
        failures += 1
        print("pills: \(id) restarting in \(Int(delay)) s"); fflush(stdout)
        let w = DispatchWorkItem { [weak self] in self?.launch() }
        restart = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Reader queue: keep the newest reading; one main-thread hop is pending at a time.
    private func deliver(_ r: PillReading) {
        // a rich reading (values, a spark, or a history) is delivered at most 4 times a second, a plain one 10 times
        let rich = !r.values.isEmpty || !r.spark.isEmpty || history
        lock.lock(); latest = r; gap = rich ? 0.25 : 0.1; let hop = !scheduled; scheduled = true; lock.unlock()
        if hop { DispatchQueue.main.async { [weak self] in self?.schedule() } }
    }

    /// Main thread: the newest reading goes out no sooner than `gap` after the previous one.
    private func schedule() {
        lock.lock(); let g = gap; lock.unlock()
        let wait = max(0, g - Date().timeIntervalSince(lastSent))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock(); let r = latest; latest = nil; scheduled = false; lock.unlock()
        lastSent = Date()
        if alive, let r { onReading(r) }
    }
}

enum Pills {
    /// The valid pills (config.json plus the drop-in files), in order. A pill needs a plain id (letters, digits, - _) that is unique and a command.
    private(set) static var all: [PillRunner] = make(AppConfig.shared.pills ?? [], reusing: [])

    /// A runner whose spec did not change is kept (its reading and its attachments with it); a new or changed spec gets a new runner.
    private static func make(_ specs: [PillSpec], reusing old: [PillRunner]) -> [PillRunner] {
        var seen = Set<String>(), out: [PillRunner] = []
        for p in specs {
            guard !p.id.isEmpty, p.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), seen.insert(p.id).inserted else {
                print("pills: ignoring \"\(p.id)\" (needs a unique plain id)"); continue
            }
            guard (p.run ?? "").isEmpty != (p.stream ?? "").isEmpty else {
                print("pills: ignoring \"\(p.id)\" (needs exactly one of run or stream)"); continue
            }
            out.append(old.first { $0.spec == p } ?? PillRunner(p))
        }
        return out
    }
    /// true when the set of runners changed (the registry must be rebuilt).
    static func update(_ specs: [PillSpec]) -> Bool {
        let new = make(specs, reusing: all)
        guard new.map({ ObjectIdentifier($0) }) != all.map({ ObjectIdentifier($0) }) else { return false }
        all = new; return true
    }

    static func expand(_ path: String) -> String { path.replacingOccurrences(of: "~", with: NSHomeDirectory(), options: .anchored) }

    /// Runs `cmd` with /bin/sh, at most 10 s and `limit` bytes of output (8 KB unless a caller needs more); nil when it fails, times out or
    /// cannot start. On a timeout the shell's children are killed too (they would otherwise keep the output pipe open), and the call returns
    /// at the deadline either way.
    /// The /bin/sh process for `cmd`, not started: `~/` expanded, PATH widened, no input or error output.
    static func process(_ cmd: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd.replacingOccurrences(of: "~/", with: NSHomeDirectory() + "/", options: .anchored)]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")      // a launch agent starts with a bare PATH
        p.environment = env
        p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Kills the direct children of the process `pid` (the shell's commands): they would otherwise outlive it.
    static func killChildren(_ pid: Int32) {
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-KILL", "-P", String(pid)]
        try? k.run(); k.waitUntilExit()
    }

    static func shell(_ cmd: String, limit: Int = 8192) -> String? {
        let p = process(cmd)
        let pipe = Pipe(); p.standardOutput = pipe
        let done = DispatchSemaphore(value: 0), lock = NSLock()
        var buf = Data()
        let rd = pipe.fileHandleForReading
        rd.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            lock.lock(); if buf.count < limit { buf.append(d) }; lock.unlock()
        }
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else { rd.readabilityHandler = nil; return nil }
        var ok = true
        if done.wait(timeout: .now() + 10) == .timedOut {
            ok = false
            killChildren(p.processIdentifier)
            p.terminate()
            _ = done.wait(timeout: .now() + 1)
        }
        rd.readabilityHandler = nil
        // what the process wrote last may not have been delivered yet: take what is in the pipe without waiting for it to close
        let fd = rd.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            lock.lock(); if buf.count < limit { buf.append(contentsOf: chunk[0..<n]) }; lock.unlock()
        }
        guard ok, !p.isRunning, p.terminationStatus == 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buf.prefix(limit), as: UTF8.self)
    }
}
