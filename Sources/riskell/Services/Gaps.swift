import Foundation
import RiskellKit

/// Keeps OmniWM's gaps.outer in step with the bars that are on: a strip or the bottom bar takes room, a bar that is off gives it back.
/// OmniWM reads settings.toml live (measured: a change shows in `omniwmctl query displays` within a second). Only the left / right /
/// bottom / top values under [gaps.outer] are touched, and only when they differ; the first change keeps a backup next to the file.
enum Gaps {
    static func apply(_ c: Config = .shared) {
        let want: [(String, CGFloat)] = [("left", c.gapLeft), ("right", c.gapRight), ("bottom", c.gapBottom), ("top", Config.gapTop)]
        let path = Compat.settingsPath
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n"), inOuter = false, changed = false
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inOuter = t == "[gaps.outer]"; continue }
            guard inOuter, let eq = t.firstIndex(of: "=") else { continue }
            let key = t[..<eq].trimmingCharacters(in: .whitespaces)
            guard let w = want.first(where: { $0.0 == key }) else { continue }
            let value = String(format: "%.1f", Double(w.1))
            if t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces) != value { lines[i] = "\(key) = \(value)"; changed = true }
        }
        guard changed else { return }
        let backup = path + ".bak-riskell-gaps"
        if !FileManager.default.fileExists(atPath: backup) { try? FileManager.default.copyItem(atPath: path, toPath: backup) }
        text = lines.joined(separator: "\n")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print("gaps: left \(c.gapLeft) right \(c.gapRight) bottom \(c.gapBottom) top \(Config.gapTop)"); fflush(stdout)
    }
}
