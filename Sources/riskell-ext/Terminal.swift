// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// The terminal every command here writes through: the mode from the environment and the theme in force, so a pipe gets plain text and
/// nothing hardcodes a colour. The loading itself is the kit's (`Tty.themed()`): the built `riskell` is asked for the tokens, and with no
/// binary to ask there is no theme, so the screen is plain rather than a guessed palette.
enum Terminal {
    static func tty() -> Tty { Tty.themed() }
}
