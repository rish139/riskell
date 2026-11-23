import AppKit
import RiskellKit

extension AppConfig {
    /// `aerospace.gaps` in config.json: "riskell" (default) keeps the four gaps.outer lines of aerospace.toml equal to the room the bars
    /// take; "manual" never writes the file and only reports what to set. The key is read from the raw file (it is not a stored property).
    static var aerospaceGapsMode: String {
        guard let d = try? Data(contentsOf: url),
              let raw = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let section = raw["aerospace"] as? [String: Any],
              let mode = section["gaps"] as? String else { return "riskell" }
        return mode
    }
}

/// Keeps AeroSpace's gaps.outer.* in step with the bars that are on. AeroSpace measures from the screen's visible frame, which starts
/// below the menu bar and beside a shown Dock, so each value is riskell's gap minus that side's inset. Only those four `key = number`
/// lines are touched (comments and everything else stay byte-identical), and only when they differ; the first change keeps a backup.
enum AeroGaps {
    private static let sides = ["left", "right", "top", "bottom"]

    /// The values AeroSpace needs, by side.
    private static func wanted(_ c: Config) -> [String: Int] {
        var inset = (left: 0.0, right: 0.0, top: 0.0, bottom: 0.0)
        if let s = NSScreen.main {
            inset = (s.visibleFrame.minX - s.frame.minX, s.frame.maxX - s.visibleFrame.maxX,
                     s.frame.maxY - s.visibleFrame.maxY, s.visibleFrame.minY - s.frame.minY)
        }
        func v(_ gap: CGFloat, _ i: Double) -> Int { max(0, Int((Double(gap) - i).rounded())) }
        return ["left": v(c.gapLeft, inset.left), "right": v(c.gapRight, inset.right),
                "top": v(Config.gapTop, inset.top), "bottom": v(c.gapBottom, inset.bottom)]
    }

    /// The one config file AeroSpace reads; nil (logged) when there is none or both exist.
    private static func file() -> String? {
        let fm = FileManager.default
        let a = NSHomeDirectory() + "/.config/aerospace/aerospace.toml", b = NSHomeDirectory() + "/.aerospace.toml"
        switch (fm.fileExists(atPath: a), fm.fileExists(atPath: b)) {
        case (true, false): return a
        case (false, true): return b
        case (true, true): log("both \(a) and \(b) exist, gaps left alone")
        case (false, false): log("no aerospace.toml found, gaps left alone")
        }
        return nil
    }

    /// `gaps.outer.<side> = <number>` with optional leading space and trailing comment: (prefix up to the number, number, rest of the line).
    private static func parse(_ line: Substring) -> (side: String, head: Substring, value: Double, tail: Substring)? {
        guard let m = line.firstMatch(of: #/^(\s*gaps\.outer\.(left|right|top|bottom)\s*=\s*)(-?[0-9]+(?:\.[0-9]+)?)(\s*(?:#.*)?)$/#) else { return nil }
        guard let v = Double(m.3) else { return nil }
        return (String(m.2), m.1, v, m.4)
    }

    static func apply(_ config: Config) {
        let want = wanted(config)
        let hint = sides.map { "outer.\($0) = \(want[$0] ?? 0)" }.joined(separator: ", ")
        guard AppConfig.aerospaceGapsMode != "manual" else { log("gaps are manual; set under [gaps]: \(hint)"); return }
        guard let path = file(), let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var changed = false, seen = Set<String>()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let p = parse(line) else { return line }
            seen.insert(p.side)
            guard let n = want[p.side], Double(n) != p.value else { return line }
            changed = true
            return Substring("\(p.head)\(n)\(p.tail)")
        }
        let missing = sides.filter { !seen.contains($0) }
        if !missing.isEmpty { log("\(path) has no plain gaps.outer.\(missing.joined(separator: " / ")) line, set under [gaps]: \(hint)") }
        guard changed else { return }
        let backup = path + ".bak-riskell-gaps"
        if !FileManager.default.fileExists(atPath: backup) { try? FileManager.default.copyItem(atPath: path, toPath: backup) }
        do { try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        catch { log("could not write \(path): \(error.localizedDescription)"); return }
        log("gaps written: \(hint)")
        reload()
    }

    /// One reload per change, off the main thread.
    private static func reload() {
        guard let bin = AeroSpace.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["reload-config", "--no-gui"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { log("reload-config failed: \(error.localizedDescription)") }
        }
    }

    /// One line per gaps.outer value in the file that is not what riskell needs, e.g. "AeroSpace gaps.outer.top is 56, riskell needs 8".
    static func drift(_ config: Config) -> [String] {
        let want = wanted(config)
        guard let path = file(), let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var have: [String: Double] = [:]
        for line in text.split(separator: "\n") { if let p = parse(line) { have[p.side] = p.value } }
        return sides.compactMap { s in
            guard let n = want[s], let h = have[s], h != Double(n) else { return nil }
            return "AeroSpace gaps.outer.\(s) is \(Int(h.rounded())), riskell needs \(n)"
        }
    }

    private static func log(_ m: String) { print("aerospace: \(m)"); fflush(stdout) }
}
