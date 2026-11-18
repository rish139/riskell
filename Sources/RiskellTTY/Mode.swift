import Foundation

/// How colour is written to a terminal: the triple itself, the nearest entry the terminal can show, or nothing at all.
///
/// `none` is also the answer for a pipe, so a caller can print through a `Tty` without asking: a styled line never reaches a file.
public enum Mode: Equatable {
    case none, ansi16, ansi256, truecolor

    /// NO_COLOR, COLORTERM (`truecolor` / `24bit`), TERM (`…-direct` writes truecolor, `dumb` writes nothing) and `isatty(1)`.
    public static func detect(env: [String: String] = ProcessInfo.processInfo.environment, isTTY: Bool = isatty(1) == 1) -> Mode {
        guard isTTY else { return .none }
        if let noColor = env["NO_COLOR"], !noColor.isEmpty { return .none }
        let term = (env["TERM"] ?? "").lowercased()
        if term == "dumb" { return .none }
        let colorterm = (env["COLORTERM"] ?? "").lowercased()
        if colorterm == "truecolor" || colorterm == "24bit" || term.hasSuffix("-direct") { return .truecolor }
        return term.contains("256") ? .ansi256 : .ansi16
    }
}
