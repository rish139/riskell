// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `risk help [command]`: the front door and per-command help, rendered from the command table. Styled on a terminal; a pipe gets the same
/// text with no escape sequences. Every line is indented two spaces and the rows are aligned, so the screen reads as a table at 80 columns.
enum HelpScreen {
    /// Prints the front door with no name, one command when a name is given (an alias works too), or the group's subcommands. 0 when it
    /// printed, 2 for a name the table does not know.
    static func run(_ args: [String]) -> Int32 {
        let tty = terminal()
        let name = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { print(frontDoor(tty).joined(separator: "\n")); return 0 }
        if let row = command(named: name) { print(detail(tty, row).joined(separator: "\n")); return 0 }
        if !subcommands(of: name).isEmpty { print(group(tty, name).joined(separator: "\n")); return 0 }
        let head = String(name.split(separator: " ").first ?? "")      // `risk help ext add`: the pass-through's own page lists add
        if let row = command(named: head) { print(detail(tty, row).joined(separator: "\n")); return 0 }
        if !subcommands(of: head).isEmpty { print(group(tty, head).joined(separator: "\n")); return 0 }
        FileHandle.standardError.write(Data("risk: no command \"\(name)\": risk help lists them all\n".utf8))
        return 2
    }

    // MARK: screens

    /// The name and version, the one line that says what risk is, then commands by tier with their one-liners, then one example.
    private static func frontDoor(_ tty: Tty) -> [String] {
        var title = tty.heading("riskell")
        if let v = version() { title += " " + tty.dim(v) }
        var lines = ["  " + title, ""]
        lines.append("  build it, run it, check it, extend it.")
        lines.append("  " + tty.dim("risk help <command> for one, docs/CLI.md for all."))
        lines.append("")

        // One rows() call for every command, so the columns line up across both tiers; a tier heading is a row of its own.
        let dim = Style(fg: tty.palette.color(.text4, tty.mode))
        let rendered = tty.rows(commandTable.map { [Cell("    " + $0.display, .left, Style(bold: true)), Cell($0.summary)] })
        let headings = tty.rows(Tier.allCases.map { tier in
            [Cell("  " + tier.rawValue, .left, dim),
             Cell("\(commandTable.filter { $0.tier == tier }.count) commands", .right, Style(bold: true))]
        })
        for (section, tier) in Tier.allCases.enumerated() {
            lines.append(headings[section])
            lines.append(contentsOf: commandTable.indices.filter { commandTable[$0].tier == tier }.map { rendered[$0] })
            lines.append("")
        }
        lines.append("  " + tty.mark(.info, tty.bold(command(named: "status")?.example ?? "risk status")))
        return lines
    }

    /// One command: its synopsis and one-liner, then aliases, tier, example and what it replaces, then its subcommands when it has any.
    private static func detail(_ tty: Tty, _ row: Command) -> [String] {
        let dim = Style(fg: tty.palette.color(.text4, tty.mode)), bold = Style(bold: true)
        var lines = ["  " + tty.heading("risk " + row.usage), "", "  " + row.summary, ""]
        var cells: [[Cell]] = []
        if !row.aliases.isEmpty {
            cells.append([Cell("    aliases", .left, dim), Cell(row.aliases.map { "risk " + $0 }.joined(separator: ", "), .left, bold)])
        }
        cells.append([Cell("    tier", .left, dim), Cell(tierText(tty, row.tier))])
        cells.append([Cell("    example", .left, dim), Cell(row.example, .left, bold)])
        for (i, source) in row.replaces.enumerated() {
            cells.append([Cell(i == 0 ? "    replaces" : "", .left, dim), Cell(source, .left, bold)])
        }
        lines.append(contentsOf: tty.rows(cells))
        if !row.children.isEmpty { lines.append(contentsOf: childBlock(tty, row.children)) }
        return lines
    }

    /// A group such as `wm` that has no row of its own: its subcommands, one per line.
    private static func group(_ tty: Tty, _ name: String) -> [String] {
        var lines = ["  " + tty.heading("risk \(name) <subcommand>"), ""]
        lines.append("  " + tty.dim("pick one; risk help <command> prints its flags and example."))
        lines.append(contentsOf: childBlock(tty, subcommands(of: name)))
        return lines
    }

    private static func childBlock(_ tty: Tty, _ children: [Child]) -> [String] {
        var lines = ["", "  " + tty.dim("subcommands")]
        lines.append(contentsOf: tty.rows(children.map { [Cell("    " + $0.name, .left, Style(bold: true)), Cell($0.summary)] }))
        return lines
    }

    /// `✓ stable` in the ok tone, `! experimental` in the warn tone.
    private static func tierText(_ tty: Tty, _ tier: Tier) -> String {
        let token: Palette.Token = tier == .stable ? .ok : .warn
        return tty.styling("\(tier.mark.rawValue) \(tier.rawValue)", Style(fg: tty.palette.color(token, tty.mode), bold: true))
    }

    // MARK: the terminal

    private static func terminal() -> Tty {
        if let palette = themePalette() { return Tty.detect(palette: palette) }
        let detected = Tty.detect(palette: Palette(hex: [:]))
        return Tty(mode: .none, width: detected.width, palette: detected.palette)      // no theme to print in: plain text, not invented colours
    }

    /// The tokens of the theme in force, asked of the built `riskell` (the only thing that resolves a theme and enforces its floors).
    /// nil when it is not built yet, e.g. `swift build --product riskell-ext` on a fresh checkout.
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
