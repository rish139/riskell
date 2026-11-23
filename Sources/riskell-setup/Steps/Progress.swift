import Foundation
import RiskellTTY

/// The install screen (the steps in the kit's progress rows, the failure block) and the finish screen (the steps, done, and the
/// one line to run next). While it runs, the kit's `Progress` owns the line and animates it.
extension App {
    /// The rows of the current job, in the order the engine runs them.
    func installRows() -> [(label: String, tone: Tone, detail: String, time: String)] {
        guard let j = job else { return [] }
        return (0..<j.names.count).map { i in
            switch j.status[i] {
            case .done:
                return (label: j.names[i], tone: .ok, detail: j.details[i], time: "")
            case .skipped:
                return (label: j.names[i], tone: .note, detail: j.details[i], time: "")
            case .failed:
                return (label: j.names[i], tone: .crit, detail: j.failMessage ?? j.details[i], time: "")
            case .running:
                let detail = j.logLast.isEmpty ? "working…" : App.humanize(j.logLast)
                return (label: j.names[i], tone: .warn, detail: detail, time: "")
            case .pending:
                return (label: j.names[i], tone: .note, detail: "", time: "")
            }
        }
    }

    func installLines(_ tty: Tty) -> [String] {
        guard let j = job else { return [] }
        let failed = j.failMessage != nil
        let title = failed ? "install stopped" : (j.finished ? "installed" : "installing")
        var out = section(tty, title)
        out += tty.progressRows(installRows())
        if failed {
            out.append("")
            out += tty.errorBlock(title: j.failMessage ?? "the install stopped", detail: nil,
                                  tries: [(cmd: "enter", note: "try again; finished steps are not repeated"),
                                          (cmd: "esc", note: "back to the review")])
            for line in j.failTail.suffix(5) { out += tty.paragraph(line) }
        }
        return out
    }

    /// The first lines above the kit's `Progress` while it runs: what is happening and that it is safe to run again.
    func installHeaderLines(_ tty: Tty) -> [String] {
        var out = section(tty, "installing")
        out += tty.paragraph("Backups first. Running setup again is safe.")
        out.append("")
        return out
    }

    func finishLines(_ tty: Tty) -> [String] {
        guard let j = job else { return [] }
        var out = section(tty, "installed")
        let rows: [(label: String, tone: Tone, detail: String, time: String)] = (0..<j.names.count).compactMap { i in
            switch j.status[i] {
            case .done: return (label: j.names[i], tone: .ok, detail: j.details[i], time: "")
            case .skipped: return (label: j.names[i], tone: .note, detail: j.details[i], time: "")
            default: return nil
            }
        }
        out += tty.progressRows(rows)
        out.append("")
        out += tty.paragraph("riskell is running. Settings live in ~/.config/riskell.")
        if c.gesturesRiskell {
            out += tty.paragraph("Accessibility is needed for riskell's own gestures; Location Services gives the network card Wi-Fi names.")
        }
        out.append(tty.next(cmd: "ctrl-alt-,", why: "open riskell preferences"))
        return out
    }

    /// A raw tool line as a status sentence: "==> Writing launch agent" becomes "starting the launch agent…".
    static func humanize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("==> ") { s = String(s.dropFirst(4)) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if s.lowercased().contains("writing launch agent") { return "starting the launch agent…" }
        if let first = s.first { s = first.lowercased() + s.dropFirst() }
        return s.hasSuffix("…") ? s : s + "…"
    }
}
