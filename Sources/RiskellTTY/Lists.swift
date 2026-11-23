import Darwin
import Dispatch
import Foundation

// The second half of the command line's screens: the lists, tables, logs, plans, prompts and progress a working command prints.
//
// Like Screens.swift, every method here returns styled `[String]` and prints nothing, so the caller decides where they go. `Progress` is the
// one exception: it owns a line of the terminal while it runs and prints the steps it finishes. Widths are counted in characters, so the
// escapes of a coloured line are not counted and the plain one lines up with it. A line that is one thing (a hint, a log line) is left
// whole rather than cut, but a table and a plan fit what room there is.

/// One column of a table: how hard it is to lose. When a line does not fit, whole columns go, and the lowest number goes first.
public struct Column: Equatable {
    public var priority: Int

    public init(priority: Int = 0) {
        self.priority = priority
    }
}

/// The severity of a log line, which is another way of naming the colour and the word it prints.
public enum Level: Equatable {
    case info, warn, error

    /// The token the level prints in.
    var token: Palette.Token {
        switch self {
        case .info: return .info
        case .warn: return .warn
        case .error: return .crit
        }
    }

    /// The word, which is the level's own name: four, four and five characters, so it is padded to five on a line.
    var word: String {
        switch self {
        case .info: return "info"
        case .warn: return "warn"
        case .error: return "error"
        }
    }
}

extension Tty {
    // MARK: a list of commands

    /// The list of commands a reader meets: a group title, its rows, a blank line, the next group.
    ///
    /// Group titles are upper case and dim, rows are indented four spaces, and every name is padded to the widest name of the whole list,
    /// so the columns line up across the groups. A description wraps under its own column, never under the name.
    public func commandList(_ groups: [(title: String, rows: [(name: String, text: String)])]) -> [String] {
        let nameWidth = (groups.flatMap { $0.rows.map(\.name.count) }.max() ?? 0) + 2
        var out: [String] = []
        for (i, group) in groups.enumerated() {
            if i > 0 { out.append("") }
            out.append("  " + ink(group.title.uppercased(), .text4))
            out += commandRows(group.rows, nameWidth: nameWidth)
        }
        return out
    }

    /// The rows of a command list: the name bold in a column of `nameWidth`, the description dim, hanging under itself when it wraps.
    private func commandRows(_ rows: [(name: String, text: String)], nameWidth: Int) -> [String] {
        let indent = 4 + nameWidth
        let room = max(1, contentWidth - indent)
        return rows.flatMap { row in
            wrap(row.text, room).enumerated().map { i, part in
                i == 0
                    ? "    " + ink(padding(row.name, nameWidth), .text1, bold: true) + ink(part, .text3)
                    : String(repeating: " ", count: indent) + ink(part, .text3)
            }
        }
    }

    // MARK: a table

    /// The two lines above a table: the title on the left, `meta` against the right edge of `contentWidth`, and a rule under them.
    public func tableHead(title: String, meta: String?) -> [String] {
        var head = headerPrefix(title)
        let left = headerWidth(title)
        if let meta, !meta.isEmpty, contentWidth - left > 1 {
            let room = max(1, contentWidth - left - 1)
            let shown = meta.count <= room ? meta : cut(meta, room)
            head += String(repeating: " ", count: max(1, contentWidth - left - shown.count)) + ink(shown, .text4)
        }
        return [head, "  " + ink(String(repeating: glyphs.ruleChar, count: max(0, contentWidth - 2)), .text4)]
    }

    /// A table: a title and a note, a rule, then one line per row.
    ///
    /// Every row begins with its mark, which `statusDot(_:)` makes, and then has one cell per column. A column is as wide as its widest
    /// cell. When a line does not fit, whole columns are dropped from the right, the lowest `priority` first; once only one column is left
    /// it is cut with an ellipsis. So a narrow terminal loses a column rather than half a word.
    public func table(title: String, meta: String?, columns: [Column], rows: [[Cell]]) -> [String] {
        var out = tableHead(title: title, meta: meta)
        guard !columns.isEmpty, !rows.isEmpty else { return out }
        var shown = Array(columns.indices)
        var widths = tableWidths(rows, shown)
        while 3 + 2 * widths.count + widths.reduce(0, +) > contentWidth, shown.count > 1 {
            let drop = shown.indices.min { a, b in
                columns[shown[a]].priority == columns[shown[b]].priority
                    ? a > b : columns[shown[a]].priority < columns[shown[b]].priority
            }
            guard let drop else { break }
            shown.remove(at: drop)
            widths = tableWidths(rows, shown)
        }
        let last = shown.count - 1
        let room = contentWidth - (3 + 2 * shown.count + widths[0..<last].reduce(0, +))
        if room < widths[last] { widths[last] = max(1, room) }
        let cells = rows.map { row -> [Cell] in
            let mark = row.first ?? Cell("")
            var line = [Cell(mark.text, mark.align, mark.style)]
            for (i, column) in shown.enumerated() {
                var cell = row.count > column + 1 ? row[column + 1] : Cell("")
                if i == last, cell.text.count > widths[last] { cell.text = cut(cell.text, widths[last]) }
                line.append(cell)
            }
            return line
        }
        out += self.rows(cells).map { "  " + $0 }      // the margin is the screen's, not the mark's
        return out
    }

    /// The mark a table row starts with: this terminal's dot, in the tone's colour.
    public func statusDot(_ tone: Tone) -> Cell {
        Cell(glyphs.dot, .left, Style(fg: color(for: tone)))
    }

    /// How wide each of the columns `shown` is, over every row.
    private func tableWidths(_ rows: [[Cell]], _ shown: [Int]) -> [Int] {
        shown.map { column in rows.compactMap { $0.count > column + 1 ? $0[column + 1].text.count : nil }.max() ?? 0 }
    }

    // MARK: one line of help, one line of log

    /// The line under a screen that says where to go next: a command in the accent, what it does dimmer, a `·` between parts.
    public func footerHint(_ parts: [(cmd: String, text: String)]) -> String {
        let hint = parts.map { part in
            ink(part.cmd, .accent) + (part.text.isEmpty ? "" : " " + ink(part.text, .text4))
        }
        return "  " + hint.joined(separator: "   " + ink(glyphs.note, .text4) + "   ")
    }

    /// One line of a log: the time, the level in its colour, the source, then the message. A message that is too long is cut with an
    /// ellipsis rather than wrapped: a log line stays one line.
    public func logLine(time: String, level: Level, source: String, message: String) -> String {
        // A line the log wrote without a time has none to show: the column is left out rather than filled with dashes.
        let stamp = time.hasPrefix("--") ? "" : ink(time, .text4) + "  "
        let head = 2 + (stamp.isEmpty ? 0 : time.count + 2) + 5 + 2 + 9 + 1
        let room = max(1, contentWidth - head)
        let shown = message.count <= room ? message : cut(message, room)
        return "  " + stamp + ink(padding(level.word, 5), level.token) + "  "
            + ink(padding(source, 9), .text3) + " " + ink(shown, .text1)
    }

    // MARK: a dry run

    /// The one shape for every `--dry-run`: what would happen, then what was and was not written.
    ///
    /// A step that is already satisfied says `has` instead of `would` and is dim, because it is not something the run will do. The note is
    /// the last line: "dry run, nothing written; add --yes to write". A row has no default in Swift, so the plan that has nothing satisfied
    /// yet is the two-element form, and a plan with a step already done passes `satisfied` on every row.
    public func plan(_ rows: [(verb: String, text: String)], note: String) -> [String] {
        plan(rows.map { (verb: $0.verb, text: $0.text, satisfied: false) }, note: note)
    }

    /// The same, with each row saying whether it is already satisfied.
    public func plan(_ rows: [(verb: String, text: String, satisfied: Bool)], note: String) -> [String] {
        let verbWidth = rows.map(\.verb.count).max() ?? 0
        let indent = 2 + 5 + 1 + verbWidth + 1
        let room = max(1, contentWidth - indent)
        var out: [String] = []
        for row in rows {
            let word = row.satisfied ? "has" : "would"
            let verb: Palette.Token = row.satisfied ? .text4 : .accent      // Tone.note is the dimmest text
            let text = row.satisfied ? color(for: .note) : palette.color(.text1, mode)
            for (i, part) in wrap(row.text, room).enumerated() {
                let lead = i == 0
                    ? "  " + ink(padding(word, 5), .text4) + " " + ink(padding(row.verb, verbWidth), verb) + " "
                    : String(repeating: " ", count: indent)
                out.append(lead + ink(part, text))
            }
        }
        out.append("")
        out += wrap(note, contentWidth - 2).map { "  " + ink($0, .text4) }
        return out
    }

    // MARK: nothing to show, and one command in full

    /// A screen with nothing on it: what is missing, and the command that would fill it.
    public func empty(_ title: String, hint: (cmd: String, text: String)?) -> [String] {
        var out = wrap(title, contentWidth - 2).map { "  " + ink($0, .text3) }
        if let hint { out.append(footerHint([hint])) }
        return out
    }

    /// One command in full: how it is called, what it does, its named values, and its subcommands when it has any.
    ///
    /// A field is a name and its values; a second value continues on the line below, under the first. An `example` is the one field whose
    /// value is in the accent, because it is the line to copy.
    public func detail(usage: String, summary: String, fields: [(String, [String])], children: [(String, String)]) -> [String] {
        var out = wrap(usage, contentWidth - 2).map { "  " + ink($0, .text1, bold: true) }
        out.append("")
        out += wrap(summary, contentWidth - 2).map { "  " + ink($0, .text3) }
        if !fields.isEmpty {
            out.append("")
            let keyWidth = fields.map(\.0.count).max() ?? 0
            let column = 4 + keyWidth + 2
            let room = max(1, contentWidth - column)
            for (key, values) in fields {
                let token: Palette.Token = key.lowercased() == "example" ? .accent : .text1
                for (i, value) in values.enumerated() {
                    for (j, part) in wrap(value, room).enumerated() {
                        let lead = i == 0 && j == 0
                            ? "    " + ink(padding(key, keyWidth), .text4) + "  "
                            : String(repeating: " ", count: column)
                        out.append(lead + ink(part, token))
                    }
                }
            }
        }
        if !children.isEmpty {
            out.append("")
            out += commandRows(children, nameWidth: (children.map(\.0.count).max() ?? 0) + 2)
        }
        return out
    }

    // MARK: a question

    /// Ask one question and read the answer: true, false, or nil when there is no terminal to ask on, in which case the caller must refuse
    /// without `--yes`. An empty line, or a word that is neither yes nor no, takes the default.
    public func confirm(_ question: String, default answer: Bool) -> Bool? {
        guard isInteractive else { return nil }
        let marks = answer ? "[Y/n]" : "[y/N]"
        FileHandle.standardOutput.write(Data(("  " + ink("?", .accent) + "  " + question + "  " + ink(marks, .text4)).utf8))
        guard let line = readLine() else { return answer }
        switch line.trimmingCharacters(in: .whitespaces).lowercased() {
        case "y", "yes": return true
        case "n", "no": return false
        default: return answer
        }
    }
}

/// One command's work, step by step: a spinner on a terminal, one plain line everywhere else.
///
/// This is the only thing in the kit that writes. It owns one line of the terminal while a step is in progress and prints each step it
/// finishes, with how long that step took. The timer turns only while a step is in progress and is cancelled when the step ends, so nothing
/// runs while the command is idle. The cursor it hides is put back when it stops and when the process is interrupted.
///
/// Off a terminal, or with NO_COLOR, there is no spinner and no carriage return: each finished step is one line, which is what a script
/// reading the output sees. `now` and `write` are the real clock and stdout, and exist so a recording can be made of a run that never
/// happened.
public final class Progress {
    private let tty: Tty
    private let steps: [String]
    private let now: () -> Double
    private let write: (String) -> Void
    private let interactive: Bool
    private let labelWidth: Int
    private var started: [Double]
    private var running: Int?
    private var frame = 0
    private var timer: DispatchSourceTimer?
    private var cursorHidden = false

    public init(tty: Tty, steps: [String],
                now: @escaping () -> Double = { Date().timeIntervalSince1970 },
                write: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) }) {
        self.tty = tty
        self.steps = steps
        self.now = now
        self.write = write
        self.interactive = tty.isInteractive && tty.mode != .none
        self.labelWidth = (steps.map(\.count).max() ?? 0) + 1
        let at = now()
        self.started = Array(repeating: at, count: steps.count)
        if interactive { signal(SIGINT, progressInterrupted) }
    }

    deinit { stop() }

    /// Start a step: from here until it is finished, the line is the spinner's.
    public func begin(_ step: Int) {
        guard steps.indices.contains(step) else { return }
        running = step
        started[step] = now()
        guard interactive, timer == nil else { return }
        hideCursor()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        timer.setEventHandler { [weak self] in self?.spin() }
        self.timer = timer
        timer.resume()
    }

    /// Finish a step: its mark in `tone`, what it did, and how long it took. The line the spinner owned becomes this line.
    public func finish(_ step: Int, _ tone: Tone, detail: String) {
        guard steps.indices.contains(step) else { return }
        let elapsed = now() - started[step]
        running = nil
        stop()
        let line = row(step, tone, detail, elapsed: elapsed)
        write(interactive ? "\r\u{1b}[2K" + line + "\n" : line + "\n")
    }

    /// The command is done: nothing is left to draw, and the summary is the last line.
    public func done(summary: String) {
        running = nil
        stop()
        guard !summary.isEmpty else { return }
        write("  " + tty.ink(summary, .text3) + "\n")
    }

    /// One finished step in the shape of a check: its mark, its label in the key column, what it did, then the time it took.
    private func row(_ step: Int, _ tone: Tone, _ detail: String, elapsed: Double) -> String {
        let time = String(format: "%.1f s", elapsed)
        let room = max(1, tty.contentWidth - (2 + 1 + 2 + labelWidth + 1) - 2 - time.count)
        var line = "  " + tty.ink(tty.glyph(for: tone), tty.color(for: tone)) + "  "
            + tty.ink(tty.padding(steps[step], labelWidth), .text3)
        if !detail.isEmpty { line += " " + tty.ink(detail.count <= room ? detail : tty.cut(detail, room), .text1) }
        return line + "  " + tty.ink(time, .text4)
    }

    /// What the spinner's line says now: the mark, then the step. Only the timer's queue calls this, and only while a timer exists.
    private func spin() {
        guard timer != nil, let running else { return }
        let marks = tty.glyphs == .ascii ? ["|", "/", "-", "\\"] : ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let mark = marks[frame % marks.count]
        frame += 1
        let label = tty.cut(steps[running], max(1, tty.contentWidth - 5))
        write("\r\u{1b}[2K  " + tty.ink(mark, .accent) + "  " + tty.ink(label, .text3))
    }

    /// Stop the timer and put the cursor back: the two things a finished command must never leave behind.
    private func stop() {
        let timer = self.timer
        self.timer = nil
        timer?.cancel()
        guard cursorHidden else { return }
        cursorHidden = false
        write("\u{1b}[?25h")
    }

    private func hideCursor() {
        guard !cursorHidden else { return }
        cursorHidden = true
        write("\u{1b}[?25l")
    }
}

/// SIGINT during a step: put the cursor back, then let the interrupt do what it would have done without us.
private func progressInterrupted(_ number: Int32) {
    let show = Array("\u{1b}[?25h".utf8)
    _ = show.withUnsafeBufferPointer { Darwin.write(1, $0.baseAddress, $0.count) }
    signal(number, SIG_DFL)
    raise(number)
}
