// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Darwin
import Dispatch
import Foundation
import RiskellTTY

/// `riskell-ext bench`: the numbers docs/EFFICIENCY.md publishes, measured again on this machine.
///
/// The table in docs/EFFICIENCY.md is the claim that riskell is cheap at rest. Two scripts can check it (`scripts/idle-cpu`,
/// `scripts/resource-check`), but neither says what it measured against the published figure, and neither records the machine, build and
/// layout a number came from, so a claim can only be believed. This command is that seam. `measures` is the whole table: what each costs,
/// how long one run takes, what it needs and which figure EFFICIENCY.md claims for it. `--list` prints it as data and starts nothing;
/// `--emit-doc` writes the published figures to docs/efficiency.json, so a fresh run can be diffed against the page; the runs (`idle`,
/// `card`, `all`) report their numbers beside the published one, with the fingerprint that makes the number mean something.
enum Bench {
    /// The JSON this command prints. Every object starts with it, so a reader can tell one shape from the next.
    static let schema = 1

    // MARK: - the table

    /// A figure docs/EFFICIENCY.md publishes: the row as the page prints it, the band it states as a percent of one core, and the same
    /// figure in seconds when the page gives one. `low`/`high` are the ends of a published range and the same number when it states one.
    struct Published {
        let text: String            // the published row, word for word
        let low: Double             // percent of one core, the low end
        let high: Double            // the high end
        let seconds: Double?        // s over the measure's window, when the page states it
    }

    /// One thing this command measures: at rest, at rest under load, or one hover card held open. `hot` is the value of RISKELL_FORCE_HOT
    /// that opens the card (the app's card id, which is not always the atom's: `clock` opens the `date` card). `window` is the measured part
    /// of a run, in seconds.
    struct Measure {
        let id: String              // what you type: `idle`, `loaded`, `card:clock`
        let summary: String         // one line, lowercase: what the number is
        let window: Int
        let hot: String?
        let loaded: Bool
        let published: Published?

        /// What one run of this measure needs: a scratch instance, plus the card it hovers or the load on every core.
        var needs: [String] {
            ["instance"] + (hot == nil ? [] : [id]) + (loaded ? ["loaded"] : [])
        }
    }

    /// The card rows of the published table, by the atoms they are opened from. The page groups five cards in one row ("1.4 to 1.9 %") and
    /// names the rest one by one; the ranges are kept as ranges.
    private static let cards14 = Published(text: "1.4 to 1.9 %", low: 1.4, high: 1.9, seconds: nil)

    /// The whole table, in the order a reader meets it. The published figures are the "After (all packages)" column of
    /// docs/EFFICIENCY.md, measured on the maintainer's machine; `machine` there is the page's own words, since it names no model.
    static let measures: [Measure] = [
        Measure(id: "idle", summary: "at rest: nothing open, nothing hovered", window: 30, hot: nil, loaded: false,
                published: Published(text: "0.33 s / 30 s (1.1 %), 104 to 110 MB, 6 to 9 threads", low: 1.1, high: 1.1, seconds: 0.33)),
        Measure(id: "loaded", summary: "at rest while every core is busy with other work", window: 30, hot: nil, loaded: true,
                published: Published(text: "0.09 s / 30 s", low: 0.3, high: 0.3, seconds: 0.09)),
        Measure(id: "card:clock", summary: "the date card held open", window: 20, hot: "date", loaded: false, published: cards14),
        Measure(id: "card:bat", summary: "the battery card held open", window: 20, hot: "bat", loaded: false, published: cards14),
        Measure(id: "card:workspaces", summary: "the workspaces card held open", window: 20, hot: "workspaces", loaded: false, published: cards14),
        Measure(id: "card:weather", summary: "the weather card held open", window: 20, hot: "weather", loaded: false, published: cards14),
        Measure(id: "card:usage", summary: "the AI usage card held open", window: 20, hot: "usage", loaded: false, published: cards14),
        Measure(id: "card:fan", summary: "the fan card held open", window: 20, hot: "fan", loaded: false,
                published: Published(text: "2.7 %", low: 2.7, high: 2.7, seconds: nil)),
        Measure(id: "card:net", summary: "the network card held open", window: 20, hot: "net", loaded: false,
                published: Published(text: "3.5 %", low: 3.5, high: 3.5, seconds: nil)),
        Measure(id: "card:cpu", summary: "the vitals card held open", window: 20, hot: "vitals", loaded: false,
                published: Published(text: "6.1 %", low: 6.1, high: 6.1, seconds: nil)),
        Measure(id: "card:vol", summary: "the mixer card held open", window: 20, hot: "vol", loaded: false,
                published: Published(text: "4.6 to 8.4 %", low: 4.6, high: 8.4, seconds: nil)),
    ]

    /// The published figure's machine, in the page's own words: docs/EFFICIENCY.md names no model, so a run here cannot claim to have
    /// reproduced it (see `verdict`).
    static let publishedMachine = "the 14-inch MacBook Pro"
    static let publishedModel: String? = nil

    /// The measure a word names: an id (`idle`, `card:clock`), a card's id (`date`, `vitals`) or the atom behind it (`clock`, `cpu`).
    private static func measure(named word: String) -> Measure? {
        measures.first { $0.id == word || $0.id == "card:" + word || $0.hot == word }
    }

    // MARK: - the command

    static func run(_ args: [String]) -> Int32 {
        var list = false, json = false, emitDoc = false
        var runs: Int?
        var words: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--list": list = true
            case "--json": json = true
            case "--emit-doc": emitDoc = true
            case "--runs":
                guard let v = value(&i, args), let n = Int(v), n > 0 else { return usage("--runs takes a number, e.g. 3") }
                runs = n
            default:
                guard !args[i].hasPrefix("-") else { return usage("no flag \"\(args[i])\"") }
                words.append(args[i])
            }
            i += 1
        }
        if list {
            guard words.isEmpty, !emitDoc, runs == nil else { return usage("--list prints the table and starts nothing: it takes no measure and no --runs") }
            return printList(json: json)
        }
        if emitDoc {
            guard words.isEmpty, !json, runs == nil else { return usage("--emit-doc writes the published table: it takes no measure and no --runs") }
            print(document())
            return 0
        }
        return usage(nil)
    }

    /// The value of a flag: the next argument, unless it is another flag.
    private static func value(_ i: inout Int, _ args: [String]) -> String? {
        guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
        i += 1
        return args[i]
    }

    // MARK: - --list

    /// The measures as data: what each costs, how long one run takes, what it needs and whether docs/EFFICIENCY.md claims it. Pure: no
    /// instance is started, and nothing of the owner's is read.
    private static func printList(json: Bool) -> Int32 {
        if json {
            let rows = measures.map { m in
                "{\"id\": \(jsonQuoted(m.id)), \"summary\": \(jsonQuoted(m.summary)), \"window\": \(m.window), \"needs\": ["
                    + m.needs.map(jsonQuoted).joined(separator: ", ") + "], \"hot\": " + (m.hot.map(jsonQuoted) ?? "null")
                    + ", \"published\": " + publishedJSON(m.published) + "}"
            }
            print("{\"schema\": \(schema), \"measures\": [\n  " + rows.joined(separator: ",\n  ")
                  + "\n], \"publishedMachine\": \(jsonQuoted(publishedMachine)), \"publishedModel\": " + (publishedModel.map(jsonQuoted) ?? "null") + "}")
            return 0
        }
        let tty = Terminal.tty()
        print(listing(tty))
        return 0
    }

    private static func publishedJSON(_ published: Published?) -> String {
        guard let p = published else { return "null" }
        return "{\"text\": \(jsonQuoted(p.text)), \"percent\": [\(number(p.low)), \(number(p.high))], \"seconds\": "
            + (p.seconds.map(number) ?? "null") + "}"
    }

    /// The table as a terminal prints it: the id and the one line, then what a run needs, how long it runs and the published figure.
    private static func listing(_ tty: Tty) -> String {
        let claimed = measures.filter { $0.published != nil }.count
        let dim = Style(fg: tty.palette.color(.text4, tty.mode))
        let pad = measures.map(\.id.count).max() ?? 0
        var lines = [tty.heading("bench") + tty.dim("  \(measures.count) measures, \(claimed) claimed in docs/EFFICIENCY.md; --list starts nothing")]
        lines.append("")
        for m in measures {
            lines.append("  " + tty.bold(m.id.padding(toLength: pad, withPad: " ", startingAt: 0)) + "  " + m.summary)
            let cost = m.needs.joined(separator: ", ") + " · \(m.window) s"
                + (m.published.map { " · published " + $0.text } ?? " · not published")
            lines.append("      " + tty.dim(cost))
        }
        lines.append("")
        lines.append("  " + tty.dim("published: the \"after\" column of docs/EFFICIENCY.md, measured on \(publishedMachine)"))
        lines.append("  " + tty.dim("risk bench idle | card <atom> | all [--runs N] [--json] — each run is a scratch instance, killed afterwards"))
        return lines.joined(separator: "\n")
    }

    // MARK: - --emit-doc

    /// docs/efficiency.json: the published table as data, from the same rows `--list` and the runs read, so a fresh run can be diffed
    /// against the page instead of retyped. Redirect it: `riskell-ext bench --emit-doc > docs/efficiency.json`.
    private static func document() -> String {
        let rows = measures.map { m in
            "    {\"id\": \(jsonQuoted(m.id)), \"window\": \(m.window), \"published\": " + publishedJSON(m.published) + "}"
        }
        return """
        {
          "schema": \(schema),
          "about": "The published efficiency figures, as data. Generated by `riskell-ext bench --emit-doc` from Sources/riskell-ext/Bench.swift; docs/EFFICIENCY.md is the prose.",
          "source": "docs/EFFICIENCY.md",
          "machine": \(jsonQuoted(publishedMachine)),
          "model": \(publishedModel.map(jsonQuoted) ?? "null"),
          "method": "scripts/idle-cpu and scripts/resource-check: 10 s to settle, then the CPU seconds the process used over the window; 0.30 s over 30 s is 1 % of one core",
          "noise": "single runs are noisy by about 0.04 to 0.1 s; the published idle row is the mean of three",
          "measures": [
        \(rows.joined(separator: ",\n"))
          ]
        }
        """
    }

    /// A number in JSON: no trailing `.0`, and two decimals at most, so 1.1 stays 1.1 and 0.25 stays 0.25.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    // MARK: - output

    private static func usage(_ problem: String?) -> Int32 {
        if let problem { FileHandle.standardError.write(Data("risk bench: \(problem)\n".utf8)) }
        FileHandle.standardError.write(Data("""
            usage: risk bench --list [--json]
                   risk bench idle [--runs N] [--json]
                   risk bench card <atom> [--runs N] [--json]
                   risk bench all [--runs N] [--json]
                   risk bench --emit-doc

            """.utf8))
        return 2
    }
}
