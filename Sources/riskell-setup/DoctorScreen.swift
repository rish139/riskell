import Foundation
import RiskellTTY

/// One row of the health screen: its tone, its key in the column, its value, and the command that would fix it.
struct ScreenRow {
    let tone: Tone
    let key: String
    let value: String
    let hint: (cmd: String, note: String?)?

    init(tone: Tone, key: String, value: String, hint: (cmd: String, note: String?)? = nil) {
        self.tone = tone
        self.key = key
        self.value = value
        self.hint = hint
    }
}

/// One section of the health screen: the heading and its rows.
struct ScreenSection {
    let title: String
    let rows: [ScreenRow]
}

/// The health report as data, ready to draw: what this machine is, what the agent is doing, and the rows.
///
/// The report itself is built by `Doctor`; `DoctorScreen` is the only thing that turns it into lines. Nothing here reads the clock, a
/// file or a process, so a fixed report always draws the same screen.
struct Report {
    let version: String
    let macOS: String?
    let chip: String
    let windowManager: String?
    let state: MastheadState
    let sections: [ScreenSection]

    /// The counts the summary shows, over every row of every section.
    var counts: (ok: Int, warn: Int, crit: Int) {
        let tones = sections.flatMap(\.rows).map(\.tone)
        return (tones.filter { $0 == .ok }.count,
                tones.filter { $0 == .warn }.count,
                tones.filter { $0 == .crit }.count)
    }

    /// The first row worth looking at, in the order a person reads the screen.
    var firstProblem: ScreenRow? {
        sections.flatMap(\.rows).first { $0.tone == .warn || $0.tone == .crit }
    }
}

/// The `risk status` screen, drawn from a `Report`: one line per section by default, and every row with its value under `--all`.
enum DoctorScreen {
    /// The screen as lines, already styled for `tty`. The caller prints them and adds nothing.
    static func render(report: Report, tty: Tty, all: Bool = false) -> [String] {
        all ? everything(report: report, tty: tty) : compact(report: report, tty: tty)
    }

    /// The default screen: the masthead, one line per section's keys, the rows that need looking at, the counts and what to do next.
    /// A healthy machine is one glance; only the rows worth reading are drawn out in full.
    private static func compact(report: Report, tty: Tty) -> [String] {
        let identity = [report.macOS.map { "macOS \($0)" } ?? "macOS unknown", report.chip,
                        report.windowManager ?? "no window manager"].joined(separator: " · ")
        var out = tty.masthead(version: report.version, lines: [identity], state: report.state)
        let sections = report.sections.filter { !$0.rows.isEmpty }
        let titleWidth = (sections.map(\.title.count).max() ?? 0) + 2
        out.append("")
        for section in sections {
            out += tty.keyLine(section.title, titleWidth: titleWidth, keys: section.rows.map { ($0.tone, $0.key) })
        }
        // the worst first, and only these: a row that is fine is already on its section's line
        let rows = report.sections.flatMap(\.rows)
        let problems = rows.filter { $0.tone == .crit } + rows.filter { $0.tone == .warn }
        if !problems.isEmpty {
            out.append("")
            out += tty.checks(problems.map { ($0.tone, $0.key, $0.value, $0.hint) })
        }
        let counts = report.counts
        out += ["", "  " + tty.summary(ok: counts.ok, warn: counts.warn, crit: counts.crit), ""]
        let more = tty.footerHint([(cmd: "risk status --all", text: "every check, with its detail")])
        if let first = problems.first(where: { $0.hint != nil }), let hint = first.hint {
            out.append(tty.next(cmd: hint.cmd, why: oneLine(hint.note ?? first.value, cmd: hint.cmd, tty: tty)))
            out.append(more)
        } else if problems.isEmpty {
            out.append("  " + tty.tone("everything is in order", .text3))
            out.append(more)
        } else {
            out.append(more)
        }
        return out
    }

    /// `risk status --all`: every row with its value, and the hint under the ones worth looking at.
    private static func everything(report: Report, tty: Tty) -> [String] {
        let identity = [report.macOS.map { "macOS \($0)" } ?? "macOS unknown", report.chip,
                        report.windowManager ?? "no window manager"].joined(separator: " · ")
        var out = tty.masthead(version: report.version, lines: [identity], state: report.state)
        let keyWidth = (report.sections.flatMap(\.rows).map(\.key.count).max() ?? 0) + 1
        for section in report.sections {
            out += ["", "  " + tty.section(section.title)]
            for row in section.rows {
                let hint = row.tone == .warn || row.tone == .crit ? row.hint : nil
                out += tty.check(row.tone, row.key, row.value, hint: hint, keyWidth: keyWidth)
            }
        }
        let counts = report.counts
        out += ["", "  " + tty.summary(ok: counts.ok, warn: counts.warn, crit: counts.crit), ""]
        if let first = report.firstProblem, let hint = first.hint {
            out.append(tty.next(cmd: hint.cmd, why: oneLine(hint.note ?? first.value, cmd: hint.cmd, tty: tty)))
        } else if report.firstProblem == nil {
            out.append("  " + tty.tone("everything is in order", .text3))
        }
        return out
    }

    /// A detail is a sentence with paths in it: a path longer than 48 characters loses its middle, so it stops taking a line of its own.
    static func tighten(_ detail: String) -> String {
        detail.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            guard w.count > 48, w.hasPrefix("~") || w.hasPrefix("/") else { return w }
            let parts = w.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return w }
            let root = w.hasPrefix("/") ? "" : parts[0]
            return root + "/…/" + parts.suffix(3).joined(separator: "/")
        }.joined(separator: " ")
    }

    /// The one thing to do next is one line: what follows it is cut to the room left, at a space when there is one.
    private static func oneLine(_ text: String, cmd: String, tty: Tty) -> String {
        let room = max(1, tty.contentWidth - 10 - cmd.count)
        guard text.count > room else { return text }
        let cut = String(text.prefix(room))
        if let space = cut.lastIndex(of: " "), space != cut.startIndex { return String(cut[..<space]) }
        return room <= 1 ? "…" : String(text.prefix(room - 1)) + "…"
    }

    /// The palette the self-test draws its fixed report with: the installer's default scheme. The screen a person meets does not use it,
    /// because `--doctor` asks the theme in force (`Tty.themed()`), and the recording is written in a mode with no colour, where it is not
    /// consulted at all — it is here as the fixed data's own answer, not as a colour the doctor imposes.
    static func palette() -> Palette {
        let s = schemeData.first { $0.isDefault } ?? schemeData[0]
        return Palette(hex: ["bg": s.bg, "tile": s.tile, "text1": s.text1, "text2": s.text2, "text3": s.text3, "text4": s.text4,
                             "accent": s.accent, "ok": s.ok, "warn": s.warn, "crit": s.crit, "info": s.info])
    }
}
