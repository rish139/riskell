import Foundation
import Darwin

/// A key press, decoded from the bytes the terminal sends.
enum Key: Equatable {
    case up, down, left, right, enter, esc, tab, backspace, interrupt
    case char(String)
}

/// Everything the event loop waits for: keys, resizes and results posted by background work.
enum Message {
    case key(Key)
    case resize
    case buildLine(String)
    case buildDone(ok: Bool, detail: String)
    case geo(seq: Int, outcome: GeoOutcome)
    case job(JobEvent)
}

/// A self-pipe. Background threads and the SIGWINCH handler write one byte to wake the loop, which otherwise blocks
/// indefinitely on input: an idle installer uses no CPU.
enum Wake {
    static var readFD: Int32 = -1
    static var writeFD: Int32 = -1
    private static let lock = NSLock()
    private static var pending: [Message] = []

    static func setup() {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        readFD = fds[0]
        writeFD = fds[1]
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
    }

    /// Async-signal-safe: only a write(2).
    static func ping() {
        var b: UInt8 = 1
        _ = write(writeFD, &b, 1)
    }

    static func post(_ m: Message) {
        lock.lock()
        pending.append(m)
        lock.unlock()
        ping()
    }

    /// Drains the pipe and returns the queued messages in order.
    static func drain() -> [Message] {
        var buf = [UInt8](repeating: 0, count: 64)
        while read(readFD, &buf, buf.count) > 0 {}
        lock.lock()
        let out = pending
        pending = []
        lock.unlock()
        return out
    }
}

/// The terminal: raw mode, the alternate screen, cursor visibility, size, and a restore that runs on every exit path,
/// including SIGINT, SIGTERM and SIGHUP.
enum Term {
    static var saved = termios()
    static var active = false

    static func start() {
        Wake.setup()
        guard isatty(0) == 1 else { return }
        var t = termios()
        tcgetattr(0, &t)
        saved = t
        var raw = t
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
        active = true
        write("\u{1b}[?1049h\u{1b}[?25l")
        installSignals()
        atexit { Term.stop() }
    }

    /// Back to the normal screen and the saved line settings. Safe to call twice.
    static func stop() {
        guard active else { return }
        active = false
        write("\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l")
        var t = saved
        tcsetattr(0, TCSANOW, &t)
    }

    static func write(_ s: String) {
        FileHandle.standardOutput.write(s.data(using: .utf8) ?? Data())
    }

    /// Columns and rows of stdout; a sane default when it is not a terminal.
    static func size() -> (w: Int, h: Int) {
        var ws = winsize()
        if ioctl(1, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        let env = ProcessInfo.processInfo.environment
        return (Int(env["COLUMNS"] ?? "") ?? 100, Int(env["LINES"] ?? "") ?? 32)
    }

    private static func installSignals() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            var sa = sigaction()
            sa.__sigaction_u.__sa_handler = { _ in
                // Restore the terminal from the signal handler (tcsetattr and write are async-signal-safe), then leave.
                let seq = "\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l"
                _ = seq.withCString { Darwin.write(1, $0, strlen($0)) }
                var t = Term.saved
                tcsetattr(0, TCSANOW, &t)
                _exit(130)
            }
            sigemptyset(&sa.sa_mask)
            sa.sa_flags = 0
            sigaction(sig, &sa, nil)
        }
        var winch = sigaction()
        winch.__sigaction_u.__sa_handler = { _ in Wake.ping() }
        sigemptyset(&winch.sa_mask)
        winch.sa_flags = 0            // no SA_RESTART: a resize must interrupt the wait
        sigaction(SIGWINCH, &winch, nil)
    }

    /// Waits for input, a wake-up, or the timeout (milliseconds; -1 waits indefinitely). `closed` means stdin ended.
    static func wait(timeoutMs: Int32) -> (keys: [Key], woke: Bool, timedOut: Bool, closed: Bool) {
        var fds = [pollfd(fd: 0, events: Int16(POLLIN), revents: 0), pollfd(fd: Wake.readFD, events: Int16(POLLIN), revents: 0)]
        let n = poll(&fds, 2, timeoutMs)
        if n == 0 { return ([], false, true, false) }
        if n < 0 { return ([], false, false, false) }     // interrupted: the caller simply loops
        var keys: [Key] = []
        var closed = false
        if fds[0].revents != 0 {
            var buf = [UInt8](repeating: 0, count: 256)
            let got = read(0, &buf, buf.count)
            if got > 0 { keys = decode(Array(buf[0..<got])) } else if got == 0 { closed = true }
        }
        return (keys, fds[1].revents & Int16(POLLIN) != 0, false, closed)
    }

    /// Decodes a chunk of input: CSI arrows, a lone escape, control keys, and UTF-8 text.
    static func decode(_ bytes: [UInt8]) -> [Key] {
        var keys: [Key] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x1b:
                if i + 2 < bytes.count, bytes[i + 1] == 0x5b || bytes[i + 1] == 0x4f {
                    switch bytes[i + 2] {
                    case 0x41: keys.append(.up)
                    case 0x42: keys.append(.down)
                    case 0x43: keys.append(.right)
                    case 0x44: keys.append(.left)
                    default: break
                    }
                    i += 3
                    continue
                }
                keys.append(.esc)
            case 0x0d, 0x0a: keys.append(.enter)
            case 0x7f, 0x08: keys.append(.backspace)
            case 0x09: keys.append(.tab)
            case 0x03: keys.append(.interrupt)
            default:
                // A UTF-8 sequence: its length comes from the lead byte.
                let len = b < 0x80 ? 1 : (b >> 5 == 0x6 ? 2 : (b >> 4 == 0xe ? 3 : (b >> 3 == 0x1e ? 4 : 1)))
                let end = Swift.min(bytes.count, i + len)
                let s = String(decoding: bytes[i..<end], as: UTF8.self)
                if b >= 0x20 { keys.append(.char(s)) }
                i = end
                continue
            }
            i += 1
        }
        return keys
    }
}
