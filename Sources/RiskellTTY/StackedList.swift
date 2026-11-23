// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation

// A list for entries whose names are long (a flag and its values), so a narrow terminal still has
// room for words. Nothing here is a colour, a glyph or a width of its own: every line is the kit's tokens and the kit's two-space margin.

extension Tty {
    /// A list of named entries: the two-column shape of `commandList` when there is room for a description beside the widest name, and the
    /// name on its own line above its description when there is not.
    ///
    /// `commandList` pads every name to the widest one, which is right for `status`, `log` and `dev`; a page of flags pads to `--opencode-workspace`
    /// and leaves sixteen columns for a sentence at 44, one word per line. Below 56 columns of content this stacks instead, which is the same
    /// list read down rather than across.
    public func stackedList(_ groups: [(title: String, rows: [(name: String, text: String)])]) -> [String] {
        guard contentWidth < 56 else { return commandList(groups) }
        var out: [String] = []
        for (i, group) in groups.enumerated() {
            if i > 0 { out.append("") }
            out.append("  " + ink(group.title.uppercased(), .text4))
            for row in group.rows {
                out.append("    " + ink(row.name, .text1, bold: true))
                out += wrap(row.text, max(1, contentWidth - 6)).map { "      " + ink($0, .text3) }
            }
        }
        return out
    }
}
