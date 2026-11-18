import Foundation
import RiskellKit

/// A unix stream socket other processes (scripts, hotkey tools) write a word to: `printf %s name | nc -U -w1 <path>`.
/// (macOS nc cannot do datagram + unix, hence a stream; the connection is closed after one word, which also ends nc.)
final class EventSocket {
    let path: String
    var onEvent: ((String) -> Void)?
    /// Words that answer back: the reply is written to the caller before the connection closes (`riskell-setup --doctor` asks for the
    /// state only this process knows).
    var replies: [String: () -> String] = [:]
    /// Words that run something in riskell itself (`printf overview | nc -U ~/.cache/riskell/ev.sock`); anything else goes to `onEvent`.
    var commands: [String: () -> Void] = [:]
    private var source: DispatchSourceRead?

    init() {
        let dir = NSHomeDirectory() + "/.cache/riskell"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // RISKELL_EVENT_SOCKET points a test instance at its own socket (as RISKELL_CONFIG does for the config)
        // A second instance (snapshots, --dump, --no-reserve) must never take over the running bar's socket: it gets one of its own.
        let secondary = !Set(CommandLine.arguments).isDisjoint(with: ["--snap", "--dump", "--no-reserve"])
        path = ProcessInfo.processInfo.environment["RISKELL_EVENT_SOCKET"] ?? (secondary ? NSTemporaryDirectory() + "riskell-ev-\(getpid()).sock" : dir + "/ev.sock")
    }

    func start() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("socket: failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard ok == 0 else { print("socket: bind failed", String(cString: strerror(errno))); close(fd); return }
        guard listen(fd, 16) == 0 else { print("socket: listen failed"); close(fd); return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            var tv = timeval(tv_sec: 0, tv_usec: 200_000)            // a silent client must not stall the main queue
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))   // the caller may hang up before the reply
            var buf = [UInt8](repeating: 0, count: 256)
            let n = recv(c, &buf, buf.count, 0)
            if n > 0 {
                let word = String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if let ask = self?.replies[word] {
                    EventSocket.reply(ask(), to: c)
                    close(c)
                    return
                }
                close(c)
                if let c = self?.commands[word] { c() } else { self?.onEvent?(word) }
                return
            }
            close(c)
        }
        src.setCancelHandler { close(fd); unlink(self.path) }
        src.resume()
        source = src
    }

    func stop() { source?.cancel(); source = nil; unlink(path) }

    /// Sends one answer to the caller, retrying a partial write. A caller that hung up gets nothing: the socket is SO_NOSIGPIPE and a
    /// failed write is not an error here.
    private static func reply(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n <= 0 { return }
            sent += n
        }
    }
}
