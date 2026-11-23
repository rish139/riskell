// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation

/// The home folder every `risk` command reads and writes under: `$HOME` when the shell names an absolute one, else the account's own.
/// `NSHomeDirectory()` ignores `$HOME`, so a test that pointed `HOME` at a scratch folder was still reading and writing the real
/// `~/.config/riskell`. In a normal shell `$HOME` is the real home, so nothing moves.
func homePath() -> String {
    if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/"), home.count > 1 { return home }
    return NSHomeDirectory()
}
