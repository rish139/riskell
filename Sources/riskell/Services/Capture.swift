import AppKit
import ScreenCaptureKit
import CoreMedia
import VideoToolbox
import RiskellKit

/// Window images for the overview, from ScreenCaptureKit (needs Screen Recording once; the stable riskell-dev signature keeps it).
/// Runs only while the overview opens: nothing is captured, cached or watched otherwise.
enum Capture {
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }
    private static var asked = false
    static func askOnce() {
        guard !asked else { return }
        asked = true
        _ = CGRequestScreenCaptureAccess()
        print("capture: asked for Screen Recording (the overview shows app icons until it is granted)")
    }

    /// Debug: the whole main display as it is on screen (riskell's own windows included) to a PNG at half Retina.
    static func display(to path: String) {
        Task.detached {
            guard let content = try? await SCShareableContent.current, let d = content.displays.first else { return }
            let cfg = SCStreamConfiguration(); cfg.width = d.width; cfg.height = d.height; cfg.showsCursor = false
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) else { return }
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Captures each window in `want` (CGWindowID -> pixels per point; parked off-screen windows included) concurrently and hands every
    /// image to `done` on the main queue as it arrives.
    static func windows(_ want: [Int: CGFloat], _ done: @escaping (Int, CGImage) -> Void) {
        guard !want.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
                print("capture: no shareable content (Screen Recording?)"); return
            }
            let targets = content.windows.filter { want[Int($0.windowID)] != nil }
            var count = 0
            await withTaskGroup(of: (Int, CGImage?).self) { group in
                for w in targets {
                    let k = want[Int(w.windowID)] ?? 0.4
                    group.addTask {
                        let cfg = SCStreamConfiguration()
                        cfg.width = max(2, Int(w.frame.width * k))
                        cfg.height = max(2, Int(w.frame.height * k))
                        cfg.scalesToFit = true
                        cfg.preservesAspectRatio = true
                        cfg.showsCursor = false
                        cfg.ignoreShadowsSingleWindow = true
                        let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
                        return (Int(w.windowID), img)
                    }
                }
                for await (id, img) in group {
                    guard let img else { continue }
                    count += 1
                    await MainActor.run { done(id, img) }
                }
            }
            tlog(String(format: "capture: %d of %d windows in %.0f ms", count, want.count, Date().timeIntervalSince(t0) * 1000))
        }
    }
}

/// Live window video for the open overview: one small ScreenCaptureKit stream per window, frames handed over as CGImages.
/// Started when the overview has opened, stopped when it starts to close; nothing runs otherwise.
final class LiveCapture: NSObject, SCStreamOutput {
    private var streams: [SCStream] = []
    private let queue = DispatchQueue(label: "riskell.live", qos: .userInteractive)
    private var onFrame: ((Int, CGImage) -> Void)?
    private var ids: [ObjectIdentifier: Int] = [:]
    private var byWindow: [Int: (stream: SCStream, k: CGFloat, size: CGSize, fps: Int)] = [:]
    private var busy: Set<Int> = []
    private var held: [Int: CVPixelBuffer] = [:]   // main queue: the buffer behind each window's frame on screen           // a frame still on its way to the main queue: drop newer ones until it lands

    /// `want`: CGWindowID -> pixels per point. `fps` frames per second at most (a window that does not change sends none).
    func start(_ want: [Int: CGFloat], fps: Int, onFrame: @escaping (Int, CGImage) -> Void) {
        stop()
        queue.async { self.onFrame = onFrame }      // after the queued stop, in order
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            for w in content.windows {
                guard let self, let k = want[Int(w.windowID)] else { continue }
                let cfg = SCStreamConfiguration()
                cfg.width = max(2, Int(w.frame.width * k)); cfg.height = max(2, Int(w.frame.height * k))
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                cfg.queueDepth = 3
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.showsCursor = false
                cfg.ignoreShadowsSingleWindow = true
                let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg, delegate: nil)
                do {
                    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    try await s.startCapture()
                    self.queue.sync {
                        self.ids[ObjectIdentifier(s)] = Int(w.windowID); self.streams.append(s)
                        self.byWindow[Int(w.windowID)] = (s, k, w.frame.size, fps)
                    }
                } catch { print("live: \(w.windowID) did not start: \(error.localizedDescription)") }
            }
        }
    }

    /// A window changed size (the WM re-laid it out): its stream follows, so the picture keeps the window's shape instead of being cropped.
    func resize(_ id: Int, to size: CGSize) {
        queue.async { [weak self] in
            guard let self, let e = self.byWindow[id], abs(e.size.width - size.width) > 4 || abs(e.size.height - size.height) > 4 else { return }
            let cfg = SCStreamConfiguration()
            cfg.width = max(2, Int(size.width * e.k)); cfg.height = max(2, Int(size.height * e.k))
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(e.fps))
            cfg.queueDepth = 3
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            self.byWindow[id]?.size = size
            e.stream.updateConfiguration(cfg) { err in if let err { print("live: resize \(id): \(err.localizedDescription)") } }
        }
    }

    func stop() {
        held = [:]
        // async: a frame may be mid-conversion on the queue, and the main thread (a closing morph) must not wait for it
        queue.async {
            for s in self.streams { s.stopCapture { _ in } }
            self.streams = []; self.ids = [:]; self.busy = []; self.onFrame = nil; self.byWindow = [:]
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let id = ids[ObjectIdentifier(stream)], !busy.contains(id), let pb = sb.imageBuffer,
              let cb = onFrame else { return }
        if let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = info[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { return }   // idle/blank: keep the last frame
        // no copy: the image wraps the frame's buffer, and that buffer is held until the next frame of this window is on screen, so
        // ScreenCaptureKit cannot reuse it while it is shown (it has others in its pool: queueDepth 3, one held per window)
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
        guard let cg else { return }
        busy.insert(id)
        DispatchQueue.main.async { [weak self] in
            cb(id, cg)
            self?.held[id] = pb
            self?.queue.async { self?.busy.remove(id) }
        }
    }
}
