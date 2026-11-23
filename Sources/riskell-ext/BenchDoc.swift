// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// `riskell-ext bench emit-doc`: docs/efficiency.json, the table docs/EFFICIENCY.md publishes, as data a diff can read.
///
/// The page is prose written by hand; this file is generated, so a change to a published figure shows up as a diff a reader can review instead
/// of as a sentence nobody re-checked. The rows are `Bench.measures`, the table `bench --list` prints and the runs measure, so the file cannot
/// drift from what the command measures or retype a number of its own. A published figure and a measured one are different claims: each row
/// carries the page's figure and an empty `measured`, and nothing here fills it — a run does that. Nothing is read from this machine and nothing
/// is stamped with a time, so the same checkout writes the same bytes twice.
enum BenchDoc {
    /// What a reader tells this document by: the shape of the published table, not of a run (`Bench.schema`).
    static let schema = "riskell.efficiency/1"

    /// The page whose numbers this file mirrors: the prose stays there.
    static let source = "docs/EFFICIENCY.md"

    /// The file the numbers live in, from the root of the checkout.
    static let path = "docs/efficiency.json"

    /// `--json` prints the document and writes nothing, so a script can compare it with the committed file first; the flagless form writes it
    /// and says in one line what it wrote.
    static func run(_ args: [String]) -> Int32 {
        if let other = args.first(where: { $0 != "--json" }) { return usage("takes only --json, not \"\(other)\"") }
        if args.contains("--json") {
            print(document(), terminator: "")
            return 0
        }
        guard let root = checkout() else { return fail("run it inside the riskell checkout (no extensions.lock.json above here)") }
        do { try document().write(toFile: root + "/" + path, atomically: true, encoding: .utf8) }
        catch { return fail("could not write \(path): \(error)") }
        let published = Bench.measures.filter { $0.published != nil }.count
        let tty = Terminal.tty()
        var lines = [tty.header("bench emit-doc", detail: path)]
        lines += tty.checks([
            (Tone.ok, "wrote", path, nil),
            (Tone.note, "measures", "\(Bench.measures.count), \(published) with a published figure", nil),
            (Tone.note, "schema", "\(schema), mirroring \(source)", nil),
        ])
        lines.append("")
        lines.append(tty.footerHint([(cmd: "risk bench --list", text: "the table as a terminal prints it")]))
        print(lines.joined(separator: "\n"))
        return 0
    }

    /// The document itself: one object, the rows in the order the page prints them, and no field that two runs could disagree about.
    static func document() -> String {
        return """
        {
          "schema": \(jsonQuoted(schema)),
          "generatedBy": \(jsonQuoted("riskell-ext bench emit-doc, from the measures in Sources/riskell-ext/Bench.swift")),
          "source": \(jsonQuoted(source)),
          "publishedMachine": \(jsonQuoted(Bench.publishedMachine)),
          "publishedModel": \(Bench.publishedModel.map(jsonQuoted) ?? "null"),
          "measuredNote": \(jsonQuoted("measured is null in every row: \(path) holds what \(source) publishes, and only a run fills that field (riskell-ext bench <id> --json, or bench all --json for the whole table)")),
          "measures": [
        \(Bench.measures.map(row).joined(separator: ",\n"))
          ]
        }

        """
    }

    /// One measure: what `bench --list` says about it, the figure the page publishes, and the empty field a run fills.
    private static func row(_ measure: Bench.Measure) -> String {
        return [
            "    {",
            "      \"id\": " + jsonQuoted(measure.id) + ",",
            "      \"summary\": " + jsonQuoted(measure.summary) + ",",
            "      \"window\": \(measure.window),",
            "      \"needs\": [" + measure.needs.map(jsonQuoted).joined(separator: ", ") + "],",
            "      \"hot\": " + (measure.hot.map(jsonQuoted) ?? "null") + ",",
            "      \"published\": " + published(measure.published) + ",",
            "      \"measured\": null",
            "    }",
        ].joined(separator: "\n")
    }

    /// The page's figure as numbers beside its words, in the shape `bench --list --json` prints, so one reader parses either. A row the page
    /// does not claim is null here rather than absent, so every row has the same keys.
    private static func published(_ published: Bench.Published?) -> String {
        guard let claim = published else { return "null" }
        return "{\"text\": " + jsonQuoted(claim.text) + ", \"percent\": [" + number(claim.low) + ", " + number(claim.high) + "], \"seconds\": "
            + (claim.seconds.map(number) ?? "null") + "}"
    }

    /// A published number the way `bench --list --json` writes it (`Bench.number`, private to that file): a whole number without a
    /// decimal point, anything else to two places, so one reader parses either document.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func usage(_ problem: String) -> Int32 {
        Usage.error("bench", "emit-doc " + problem)
    }

    private static func fail(_ problem: String) -> Int32 {
        Usage.failure(problem, tries: [(cmd: "risk bench --list", note: "what the document mirrors")])
        return 1
    }
}
