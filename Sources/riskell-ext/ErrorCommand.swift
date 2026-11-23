// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `riskell-ext error <title> [--detail D] [--try 'cmd|note']...`: the kit's error block on stderr, for a shell script that has to print
/// the same failure shape as the built commands. Internal: `scripts/risk` calls it from its `fail` function (the wrapper has no kit of its
/// own), it is not in the command table, and it always exits 2.
enum ErrorCommand {
    static func run(_ args: [String]) -> Int32 {
        var title = ""
        var detail: String?
        var tries: [(cmd: String, note: String)] = []
        var rest = args.makeIterator()
        while let arg = rest.next() {
            switch arg {
            case "--detail": detail = rest.next() ?? ""
            case "--try":
                let parts = (rest.next() ?? "").split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                tries.append((cmd: parts.first ?? "", note: parts.count > 1 ? parts[1] : ""))
            default: title = title.isEmpty ? arg : title + " " + arg      // a title of more than one word, unquoted
            }
        }
        let tty = Terminal.tty()
        var lines = tty.errorBlock(title: title.isEmpty ? "the command failed, and said nothing why" : title, detail: detail, tries: tries)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return 2
    }
}
