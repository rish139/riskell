import AppKit
import RiskellKit

/// What is playing, from MediaRemote. macOS answers that private framework only for Apple-signed processes, so one
/// long-lived /usr/bin/perl loads libnowplaying.dylib (next to the executable) and prints a JSON line per change.
final class NowPlaying {
    private var proc: Process?
    private var buf = Data()
    private var last: ([String: Any], Date)?
    private var expiry: Timer?
    /// A paused entry older than this is a leftover (a closed tab keeps its last info), not a queue.
    private let pausedLife: TimeInterval = 15 * 60

    /// Shown only for an app that is playing, or one genuinely paused (rate 0) recently. MediaRemote keeps the last entry
    /// after a player goes away; such a ghost reports rate 1 while the app says it is not playing, or is simply old.
    private func evaluate() {
        expiry?.invalidate()
        guard let (j, at) = last, let b = j["bundle"] as? String, !b.isEmpty, j["title"] as? Bool == true else { store.set(media: nil); return }
        let playing = j["playing"] as? Bool ?? false
        if playing { store.set(media: MediaReading(bundle: b, playing: true)); return }
        let age = (j["age"] as? Double ?? 0) + Date().timeIntervalSince(at)
        if (j["rate"] as? Double ?? 0) != 0 || age > pausedLife { store.set(media: nil); return }
        store.set(media: MediaReading(bundle: b, playing: false))
        expiry = Timer.scheduledTimer(withTimeInterval: pausedLife - age + 1, repeats: false) { [weak self] _ in self?.evaluate() }
    }

    func start() {
        let dir = Bundle.main.executableURL!.deletingLastPathComponent()
        let lib = dir.appendingPathComponent("libnowplaying.dylib").path
        guard FileManager.default.fileExists(atPath: lib) else { print("nowplaying: \(lib) missing"); return }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use DynaLoader; my $l=DynaLoader::dl_load_file($ARGV[0],0) or die; my $s=DynaLoader::dl_find_symbol($l,'np_stream') or die; &{DynaLoader::dl_install_xsub('main::np',$s)};", lib]
        p.standardOutput = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.feed(d) }
        }
        do { try p.run(); proc = p } catch { print("nowplaying: \(error)") }
    }

    func stop() { proc?.terminate() }

    private func feed(_ d: Data) {
        buf.append(d)
        while let nl = buf.firstIndex(of: 10) {
            let line = buf.subdata(in: buf.startIndex..<nl); buf.removeSubrange(buf.startIndex...nl)
            guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            last = (j, Date()); evaluate()
        }
    }

    /// Play/pause: the toggle command goes through the same Apple-signed route.
    static func toggle() {
        let sym = "MRMediaRemoteSendCommand"
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let f = dlsym(h, sym) else { return }
        typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
        _ = unsafeBitCast(f, to: Send.self)(2, nil)   // kMRTogglePlayPause
    }
}
