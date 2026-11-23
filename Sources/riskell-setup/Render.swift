import Foundation
import RiskellTTY

let riskellVersion = "1.0"

/// The screens as the kit's lines. Nothing here draws a glyph, a rule or a colour: a screen is built from the kit's
/// masthead, sections, checks, plan, next line and hints, and `screen` only adds the air above the footer.
extension App {
    /// The installer's terminal: the palette of riskell's default scheme, the width of the window it is in.
    static func makeTty(width: Int, mode: RiskellTTY.Mode, interactive: Bool) -> Tty {
        Tty(mode: mode, width: width, palette: DoctorScreen.palette(), glyphs: Glyphs.detect(), isInteractive: interactive)
    }

    static func liveTty(width: Int) -> Tty {
        makeTty(width: width, mode: RiskellTTY.Mode.detect(env: ProcessInfo.processInfo.environment), interactive: true)
    }

    /// A section with the blank line the screens keep above it.
    func section(_ tty: Tty, _ title: String) -> [String] {
        ["", "  " + tty.section(title)]
    }

    /// The body of the current screen, without the footer.
    func bodyLines(_ tty: Tty, height: Int) -> [String] {
        switch stage {
        case .welcome: return welcomeLines(tty)
        case .wm: return wmLines(tty)
        case .bars: return barsLines(tty)
        case .theme: return themeLines(tty, height: height)
        case .weather: return weatherLines(tty)
        case .usage: return usageLines(tty)
        case .gestures: return gesturesLines(tty)
        case .scale: return scaleLines(tty)
        case .review: return reviewLines(tty, height: height)
        case .diff: return diffLines(tty)
        case .install: return installLines(tty)
        case .finish: return finishLines(tty)
        }
    }

    /// The whole frame: the body, a notice or a build line above the footer, the footer at the bottom edge of `height`.
    func screen(_ tty: Tty, height: Int) -> [String] {
        var foot: [String] = []
        if let n = notice { foot.append("  " + tty.tone(n, noticeIsError ? .crit : .text3)) }
        if case .running(let last) = build {
            foot.append("  " + tty.tone(last.isEmpty ? "building riskell" : "building riskell · \(last)", .text4))
        }
        foot.append(hintLine(tty))
        let room = max(1, height - foot.count)
        var body = bodyLines(tty, height: room)
        if body.count > room {
            let dropped = body.count - (room - 1)
            body = Array(body.prefix(max(0, room - 1)))
            if room > 0 { body.append("  " + tty.tone("… \(dropped) more lines", .text4)) }
        }
        let pad = Array(repeating: "", count: max(0, height - foot.count - body.count))
        return body + pad + foot
    }

    /// The keys that work on this screen, in the kit's hint shape (`enter continue · esc quit`).
    func hintLine(_ tty: Tty) -> String {
        func hint(_ parts: [(String, String)]) -> String {
            tty.footerHint(parts.map { (cmd: $0.0, text: $0.1) })
        }
        switch stage {
        case .welcome:
            return hint([("enter", "continue"), ("esc", "quit")])
        case .wm, .theme:
            return hint([("up/down", "move"), ("enter", "continue"), ("esc", "back"), ("q", "quit")])
        case .bars:
            return hint([("up/down", "move"), ("left/right", "change"), ("enter", "continue"), ("esc", "back")])
        case .weather:
            if manual { return hint([("enter", "use it"), ("esc", "back")]) }
            return hint([("type", "a city"), ("up/down", "choose"), ("enter", "continue"), ("esc", "back")])
        case .usage:
            if consent != nil { return hint([("y", "turn it on"), ("any other key", "leaves it off")]) }
            return hint([("up/down", "move"), ("space", "toggle"), ("enter", "continue"), ("esc", "back")])
        case .gestures:
            return hint([("up/down", "move"), ("space", "toggle"), ("enter", "continue"), ("esc", "back")])
        case .scale:
            return hint([("up/down", "move"), ("left/right", "adjust"), ("enter", "continue"), ("esc", "back")])
        case .review:
            return hint([("up/down", "move"), ("space", "toggle"), ("enter", "choose"), ("esc", "back")])
        case .diff:
            return hint([("enter", "back"), ("esc", "back")])
        case .install:
            if job?.failMessage != nil { return hint([("enter", "retry"), ("esc", "review"), ("q", "quit")]) }
            if job?.finished == true { return hint([("enter", "continue")]) }
            return hint([("working", "the installer is writing the plan")])
        case .finish:
            return hint([("enter", "done"), ("q", "quit")])
        }
    }
}
