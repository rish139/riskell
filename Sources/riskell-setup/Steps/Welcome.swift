import Foundation
import RiskellTTY

extension App {
    /// The kit's masthead, one paragraph that says what the next eight questions do, and nothing else.
    func welcomeLines(_ tty: Tty) -> [String] {
        let identity = [
            facts.macos.map { "macOS \($0)" } ?? "macOS unknown",
            facts.arch == "arm64" ? "Apple silicon" : facts.arch,
            facts.detectedWM ?? "no window manager",
        ].joined(separator: " · ")
        let state: State = facts.agentLoaded ? .running("running") : .unknown("not installed")
        var out = tty.masthead(version: "setup \(riskellVersion)", lines: [identity], state: state)
        out.append("")
        out += tty.paragraph("The guided installer asks eight short questions: your window manager, the bars, a theme, a weather "
            + "place, the optional usage sources, the trackpad gestures and the scale. Nothing is written until you confirm.")
        if facts.blocked {
            out.append("")
            out += tty.errorBlock(title: "Swift is needed to build riskell", detail: nil,
                                  tries: [(cmd: "xcode-select --install", note: "then start setup again")])
        }
        return out
    }
}
