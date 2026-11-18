import Foundation
import RiskellKit
import RiskellWM

/// Keeps OmniWM's gaps.outer in step with the bars that are on: a strip or the bottom bar takes room, a bar that is off gives it back.
/// OmniWM reads settings.toml live (measured: a change shows in `omniwmctl query displays` within a second). Only the left / right /
/// bottom / top values under [gaps.outer] are touched, and only when they differ (RiskellWM.Gaps.rewrite says what the text becomes);
/// the first change keeps a backup next to the file.
enum Gaps {
    static func apply(_ c: Config = .shared) {
        let want = RiskellWM.Gaps.Outer(left: Double(c.gapLeft), right: Double(c.gapRight),
                                        bottom: Double(c.gapBottom), top: Double(Config.gapTop))
        let path = Compat.settingsPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let rewritten = RiskellWM.Gaps.rewrite(text: text, want: want) else { return }
        let backup = path + ".bak-riskell-gaps"
        if !FileManager.default.fileExists(atPath: backup) { try? FileManager.default.copyItem(atPath: path, toPath: backup) }
        try? rewritten.write(toFile: path, atomically: true, encoding: .utf8)
        print("gaps: left \(c.gapLeft) right \(c.gapRight) bottom \(c.gapBottom) top \(Config.gapTop)"); fflush(stdout)
    }
}
