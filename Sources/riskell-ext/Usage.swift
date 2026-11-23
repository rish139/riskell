// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// The one way a command says it was used wrongly or failed: the kit's error block on stderr, never a bare `usage:` line. A wrong
/// argument names the problem, shows the command's synopsis from the command table, and points at its help page.
enum Usage {
    /// A wrong or missing argument for `command` (`ctl`, `config`, `ext`...). Exit status 2.
    static func error(_ command: String, _ problem: String) -> Int32 {
        let tty = Terminal.tty()
        let synopsis = commandTable.first { $0.display == command || $0.name == command }.map { "risk " + $0.usage }
        write(tty.errorBlock(title: strip(problem), detail: synopsis, tries: [("risk help \(command)", "the full page")]))
        return 2
    }

    /// Something that failed rather than was mistyped: the message becomes the title. Exit status is the caller's.
    static func failure(_ message: String, tries: [(cmd: String, note: String)] = [("risk status", "see what else is off")]) {
        write(Terminal.tty().errorBlock(title: strip(message), detail: nil, tries: tries))
    }

    /// The message without its old `risk ext:` / `risk:` prefix: the header of the block already says whose it is.
    static func strip(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^risk( [a-z-]+)?: "#, options: .regularExpression) { text.removeSubrange(range) }
        return text
    }

    private static func write(_ lines: [String]) {
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
