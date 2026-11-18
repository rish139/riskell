// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// The terminal every command here writes through: the mode from the environment and the theme in force, so a pipe gets plain text and
/// nothing hardcodes a colour. The theme is asked of the built `riskell`, the only thing that resolves a scheme and enforces its floors.
enum Terminal {
    static func tty() -> Tty {
        if let palette = themePalette() { return Tty.detect(palette: palette) }
        let detected = Tty.detect(palette: Palette(hex: [:]))
        return Tty(mode: .none, width: detected.width, palette: detected.palette)      // no theme to print in: plain text, not invented colours
    }

    /// The tokens of the theme in force, asked of the built `riskell`. nil when it is not built yet, e.g. `swift build --product riskell-ext`
    /// on a fresh checkout.
    private static func themePalette() -> Palette? {
        guard let root = checkout() else { return nil }
        let binary = root + "/.build/release/riskell"
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--palette", "--format", "json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: String] else { return nil }
        return Palette(hex: tokens)
    }
}
