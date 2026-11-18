import Foundation
import RiskellKit
import RiskellTTY

/// `riskell --palette [--format hex|json|ansi] [--theme ID]`: the tokens of the theme in force, printed and then exit. It runs beside
/// `--list-themes` and `--check-themes`, before the instance lock, so it needs no bars and no window: the theme is already resolved
/// (`Theme.current`, main.swift) from the config, which falls back to the default scheme when the file or the scheme is not valid.
enum PaletteCommand {
    /// Reads the flags and prints once. 0 when it printed, 2 for a bad --format or an unknown --theme (message on stderr).
    static func run(_ args: [String]) -> Int32 {
        func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        func isFlag(_ s: String) -> Bool { s.hasPrefix("--") }

        var format = "hex"
        if args.contains("--format") {
            guard let f = value("--format"), !isFlag(f) else { return fail("--format wants hex, json or ansi") }
            guard ["hex", "json", "ansi"].contains(f) else { return fail("no --format \"\(f)\": hex, json or ansi") }
            format = f
        }

        var theme = Theme.current
        if args.contains("--theme") {
            guard let id = value("--theme"), !isFlag(id) else { return fail("--theme wants a scheme id") }
            guard let scheme = Theme.catalog().first(where: { $0.id == id }) else { return fail("no theme \"\(id)\": see riskell --list-themes") }
            theme = Theme.resolve(scheme)
        }

        let tokens = palette(of: theme)
        if format == "json" {
            print(json(theme, tokens))
        } else {
            print(lines(theme, tokens, ansi: format == "ansi").joined(separator: "\n"))
        }
        return 0
    }
    /// `id` and `variant`, then the tokens in `Theme.signature`'s order; with `ansi` every value carries its own colour. `ansi` is an explicit
    /// request, so it prints escapes even into a pipe; every other format stays plain there. NO_COLOR wins over both.
    private static func lines(_ theme: Theme, _ palette: Palette, ansi: Bool) -> [String] {
        // `--format ansi` is an explicit request for escapes, so it overrides the pipe rule (NO_COLOR still wins): a pager or a script that
        // pipes it gets the sequences it asked for.
        let tty = ansi ? Tty.forced(palette: palette) : Tty.detect(palette: palette)
        let label = Style(fg: palette.color(.text4, tty.mode))
        var rows: [[Cell]] = [
            [Cell("id", .left, label), Cell(theme.id)],
            [Cell("variant", .left, label), Cell(theme.dark ? "dark" : "light")],
        ]
        for token in Palette.Token.allCases {
            let pen = ansi ? Style(fg: palette.color(token, tty.mode), bold: true) : .plain
            rows.append([Cell(token.rawValue, .left, label), Cell(palette[token].hex, .left, pen)])
        }
        return tty.rows(rows)
    }

    private static func json(_ theme: Theme, _ tokens: Palette) -> String {
        let all = Palette.Token.allCases
        var out = "{\n  \"id\": \(quoted(theme.id)),\n  \"variant\": \(quoted(theme.dark ? "dark" : "light")),\n  \"tokens\": {\n"
        for (i, token) in all.enumerated() {
            out += "    \(quoted(token.rawValue)): \(quoted(tokens[token].hex))" + (i == all.count - 1 ? "\n" : ",\n")
        }
        return out + "  }\n}"
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The theme's tokens as 8-bit triples: the kit keeps them as 0...1 doubles, a terminal takes bytes.
    private static func palette(of theme: Theme) -> Palette {
        func hex(_ c: RGB) -> String {
            RGB8(UInt8((c.r * 255).rounded()), UInt8((c.g * 255).rounded()), UInt8((c.b * 255).rounded())).hex
        }
        return Palette(hex: ["bg": hex(theme.bg), "tile": hex(theme.tile), "canvas": hex(theme.canvas),
                             "text1": hex(theme.text1), "text2": hex(theme.text2), "text3": hex(theme.text3), "text4": hex(theme.text4),
                             "accent": hex(theme.accent), "ok": hex(theme.ok), "warn": hex(theme.warn), "crit": hex(theme.crit),
                             "info": hex(theme.info), "critInk": hex(theme.critInk), "prov": hex(theme.prov), "amberDim": hex(theme.amberDim)])
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("riskell: \(message)\n".utf8))
        return 2
    }
}
