import CoreGraphics
import SwiftUI
import RiskellKit

/// Each island's natural width, by island id (design units). Read by HBar only when an island draws; nothing is measured at rest.
struct WingWidthKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// One island of a wing: its natural width (design units, its layout width with its margins), its priority (lower is dropped first) and
/// whether it may be dropped at all (the version pill may not).
struct WingItem: Equatable {
    let id: String
    let width: CGFloat
    let priority: Int
    let droppable: Bool
}

/// The fit of one wing: a uniform shrink, the ids that stay (the others are hidden, not removed) and the width the kept items take once scaled.
struct WingFit: Equatable {
    var scale: CGFloat
    var kept: Set<String>
    var dropped: [String]
    var width: CGFloat
    /// The room given and the width all items would take unshrunk (for the --check-fit table).
    var available: CGFloat = 0
    var natural: CGFloat = 0
    /// Still wider than the room at the smallest scale, with nothing droppable left: the one case that does not fit.
    var overflow: Bool
}

/// The rule that keeps the top bar's wings beside the notch. Pure: the same numbers always give the same fit.
enum WingRule {
    /// A wing never shrinks below this (design units are scaled uniformly).
    static let floor: CGFloat = 0.80

    /// Shrink first; once a wing is too wide even at the floor, hide the lowest-priority droppable item and try again (ties: the one
    /// farther from the notch goes first, which is the later item of a start wing and the earlier item of an end wing).
    static func fit(available: CGFloat, items: [WingItem], gap: CGFloat) -> WingFit {
        var kept = items
        var dropped: [String] = []
        func total(_ xs: [WingItem]) -> CGFloat { xs.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, xs.count - 1)) }
        func scale(_ xs: [WingItem]) -> CGFloat { min(1, available / max(1, total(xs))) }
        while scale(kept) < floor, let i = lowest(kept) {
            dropped.append(kept[i].id)
            kept.remove(at: i)
        }
        let s = scale(kept)
        let overflow = s < floor
        let shown = overflow ? floor : s
        return WingFit(scale: shown, kept: Set(kept.map(\.id)), dropped: dropped, width: total(kept) * shown, available: available,
                       natural: total(items), overflow: overflow)
    }

    /// The droppable item to hide next: the lowest priority; among equals, the one with the highest index.
    private static func lowest(_ xs: [WingItem]) -> Int? {
        xs.indices.filter { xs[$0].droppable }.min { a, b in
            xs[a].priority != xs[b].priority ? xs[a].priority < xs[b].priority : a > b
        }
    }
}

/// `riskell --check-fit`: runs one second instance per fake display (RISKELL_FAKE_DISPLAY, the owner's layout through RISKELL_LAYOUT) with
/// its own snapshot window, reads what the top bar's wings measured and prints a table. Exits 1 on any FAIL. A child reports its wings
/// through `report` (only when RISKELL_CHECK_FIT is set, so nothing prints in normal runs).
enum CheckFit {
    static let child = ProcessInfo.processInfo.environment["RISKELL_CHECK_FIT"] != nil
    private static var last = ""

    /// Called from HBar's body (a child only): one line per wing whenever its fit changes.
    static func report(_ f: WingFit?, _ side: String, _ bar: BarKey) {
        guard child, bar == .top, let f else { return }
        let line = "fitcheck wing=\(side) available=\(f.available) natural=\(f.natural) width=\(f.width) scale=\(f.scale) "
            + "kept=\(f.kept.sorted().joined(separator: ",")) dropped=\(f.dropped.joined(separator: ",")) overflow=\(f.overflow)"
        if line != last { last = line; print(line); fflush(stdout) }
    }

    /// The displays of the check: (name, spec) as RISKELL_FAKE_DISPLAY takes them.
    static let displays: [(String, String)] = [
        ("14in scaled", "2268x1473:notch=48,278"),
        ("14in stock", "1512x982:notch=32,185"),
        ("13in Air", "1470x956:notch=32,185"),
        ("16in stock", "1728x1117:notch=32,200"),
        ("16in scaled*", "2056x1329:notch=38,235"),      // * not a measured mode: a plausible value
        ("1080p external", "1920x1080:menubar=24"),
        ("ultrawide", "3440x1440:menubar=24"),
    ]

    static func run() -> Never {
        guard let layout = ProcessInfo.processInfo.environment["RISKELL_LAYOUT"] else {
            print("--check-fit needs RISKELL_LAYOUT=<a copy of layout.json>"); exit(2)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("riskell-check-fit-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
        var failed = false
        print("display          side     scale  notch  band   avail    natural  shrink   dropped                result")
        for (name, spec) in displays {
            let out = dir.appendingPathComponent("\(spec.replacingOccurrences(of: ":", with: "_")).txt")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let p = Process()
            p.executableURL = exe
            p.arguments = ["--no-usage", "--no-reserve", "--fake-usage", "--snap", dir.path, "--stay", "4"]
            var env = ProcessInfo.processInfo.environment
            env["RISKELL_FAKE_DISPLAY"] = spec; env["RISKELL_CHECK_FIT"] = "1"; env["RISKELL_LAYOUT"] = layout
            p.environment = env
            if let h = try? FileHandle(forWritingTo: out) { p.standardOutput = h }
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
            p.waitUntilExit(); timer.cancel()
            let lines = ((try? String(contentsOf: out, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            var kv: [String: [String: String]] = [:]      // "display" / "start" / "end" -> fields
            for l in lines where l.hasPrefix("fitcheck ") {
                var fields: [String: String] = [:]
                for part in l.dropFirst("fitcheck ".count).split(separator: " ") {
                    let p2 = part.split(separator: "=", maxSplits: 1).map(String.init)
                    if p2.count == 2 { fields[p2[0]] = p2[1] }
                }
                if let w = fields["wing"] { kv[w] = fields } else { kv["display"] = fields }
            }
            let d = kv["display"] ?? [:]
            let notchH = Double(d["notchH"] ?? "") ?? 0, band = Double(d["band"] ?? "") ?? 0, scale = d["scale"] ?? "?"
            var bandOK = true
            if notchH > 0 { bandOK = abs(band - notchH) < 0.5 }
            for side in ["start", "end"] {
                guard let w = kv[side] else {
                    if notchH > 0 { failed = true; print("\(name) \(side): not measured FAIL") }
                    continue
                }
                let avail = Double(w["available"] ?? "") ?? 0, natural = Double(w["natural"] ?? "") ?? 0, width = Double(w["width"] ?? "") ?? 0
                let ok = w["overflow"] == "false" && width <= avail + 0.5
                let dropped = (w["dropped"] ?? "").isEmpty ? "-" : (w["dropped"] ?? "")
                let shrink = w["scale"] ?? "?"
                print("\(name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(side.padding(toLength: 8, withPad: " ", startingAt: 0))"
                    + " \(scale.prefix(5).padding(toLength: 6, withPad: " ", startingAt: 0)) \(String(format: "%-6.0f", notchH)) \(String(format: "%-6.1f", band))"
                    + " \(String(format: "%-8.1f", avail)) \(String(format: "%-8.1f", natural)) \(shrink.prefix(6).padding(toLength: 8, withPad: " ", startingAt: 0))"
                    + " \(dropped.padding(toLength: 22, withPad: " ", startingAt: 0)) \(ok ? "PASS" : "FAIL")")
                if !ok { failed = true }
            }
            if !bandOK { failed = true; print("\(name): band \(band) != notch \(notchH) FAIL") }
            if notchH == 0 && kv["start"] == nil && kv["end"] == nil { print("\(name): no notch, no wings to fit (PASS)") }
        }
        try? FileManager.default.removeItem(at: dir)
        print(failed ? "RESULT: FAIL" : "RESULT: PASS")
        exit(failed ? 1 : 0)
    }
}
