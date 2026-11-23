// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation

// The terminal every `risk` command writes through, in the theme in force.
//
// The theme is not something this side can work out: only the built `riskell` resolves a scheme, applies its floors and knows which one is
// active, so it is asked with `--palette --format json` and the answer is the palette. Nothing here invents a colour: with no built binary
// (a fresh checkout, or the installer inside an installed copy with no checkout beside it) there is no theme to print in, and the screen is
// plain text instead of a guessed palette.

extension Tty {
    /// The terminal this process writes to: the mode from the environment, the width from COLUMNS, the glyphs from the locale, and the
    /// tokens of the theme in force. A pipe is still plain: the mode is what decides, exactly as `detect` does.
    public static func themed(env: [String: String] = ProcessInfo.processInfo.environment) -> Tty {
        if let palette = themePalette(env: env) { return Tty.detect(palette: palette, env: env) }
        let detected = Tty.detect(palette: Palette(hex: [:]), env: env)
        return Tty(mode: .none, width: detected.width, palette: detected.palette)      // no theme to print in: plain text, not invented colours
    }

    /// The tokens of the theme in force, asked of the built `riskell`. nil when it is not built yet, or this is not a checkout, which is
    /// what a `swift build --product riskell-ext` on a fresh clone and the installer in an installed copy both look like.
    private static func themePalette(env: [String: String]) -> Palette? {
        guard let root = checkoutRoot(env: env) else { return nil }
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

    /// The riskell checkout this tool runs from: RISKELL_ROOT when `scripts/risk` sets it, else the nearest parent of the working directory
    /// or of the executable that holds VERSION and extensions.lock.json. nil when the binary has been copied out of a checkout.
    static func checkoutRoot(env: [String: String]) -> String? {
        let fm = FileManager.default
        if let given = env["RISKELL_ROOT"], fm.fileExists(atPath: given + "/extensions.lock.json") { return given }
        var starts = [fm.currentDirectoryPath]
        if let executable = Bundle.main.executablePath { starts.append((executable as NSString).deletingLastPathComponent) }
        for start in starts {
            var dir = start
            while true {
                if fm.fileExists(atPath: dir + "/VERSION"), fm.fileExists(atPath: dir + "/extensions.lock.json") { return dir }
                if dir == "/" { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return nil
    }
}
