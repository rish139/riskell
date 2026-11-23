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
/// how long one run takes, what it needs and which figure EFFICIENCY.md claims for it. `--list` prints it as data and starts nothing; the
/// runs (`idle`, `card`, `all`) report their numbers beside the published one, with the fingerprint that makes the number mean something.
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

    /// How a reader measures this one on its own: the word `run` takes for it. `loaded` has none of its own, so it comes with `all`.
    private static func invocation(_ measure: Measure) -> String {
        if measure.id.hasPrefix("card:") { return "risk bench card " + measure.id.dropFirst("card:".count) }
        return measure.id == "idle" ? "risk bench idle" : "risk bench all"
    }

    // MARK: - measuring

    /// One run's numbers: the CPU seconds the instance used over the window, the same as a percent of one core, and the resident memory
    /// (MB) and thread count at the end of the window.
    struct Sample {
        let seconds: Double
        let percent: Double
        let memory: Int
        let threads: Int
    }

    /// A measure that has been run: every sample, the median of them (the number to judge by) and the spread between them. A single run has
    /// no spread, and `noise` says so by being nil: the output must never let one run look like a median of three.
    struct Result {
        let measure: Measure
        let samples: [Sample]
        let median: Sample
        let noise: Double?

        init(_ measure: Measure, _ samples: [Sample]) {
            self.measure = measure
            self.samples = samples
            let sorted = samples.sorted { $0.seconds < $1.seconds }
            let middle = sorted.count / 2
            let seconds = sorted.count % 2 == 1 ? sorted[middle].seconds : (sorted[middle - 1].seconds + sorted[middle].seconds) / 2
            self.median = Sample(seconds: seconds, percent: seconds * 100 / Double(measure.window),
                                 memory: sorted[middle].memory, threads: sorted[middle].threads)
            self.noise = samples.count < 2 ? nil : (sorted[sorted.count - 1].seconds - sorted[0].seconds)
        }
    }

    /// What the number is judged against. `docs/EFFICIENCY.md`'s figures come from the maintainer's 14-inch MacBook Pro and name no model
    /// (`publishedModel` is nil), so a run here reports `cannot-compare` while still printing both numbers; filling the model in once turns
    /// the same code into a real comparison.
    enum Verdict: String {
        case reproduced, exceeded, below, cannotCompare = "cannot-compare"
    }

    /// The published band widened by this run's own noise: a run inside it reproduced the figure, one above it exceeded it. nil when the
    /// page claims nothing for the measure.
    static func verdict(_ result: Result, machine: String) -> Verdict? {
        guard let published = result.measure.published else { return nil }
        guard let publishedModel, publishedModel == machine else { return .cannotCompare }
        let band = (result.noise ?? 0.1) / Double(result.measure.window) * 100      // the page's single-run noise is 0.1 s
        if result.median.percent > published.high + band { return .exceeded }
        if result.median.percent < published.low - band { return .below }
        return .reproduced
    }

    /// What a run needs from outside the table: the built app, the two files it reads and the scratch folder both of them and everything
    /// the instance writes live in.
    struct Setup {
        let binary: String
        let layout: String
        let config: String
        let scratch: String
    }

    /// The layout every run is measured against: the classic preset, which is also riskell's built-in default (`Sources/riskell/Layout.swift`'s
    /// `Config.defaults`, the setup app's Classic in `Sources/riskell-setup/Presets.swift`). It places every built-in atom, which is the layout
    /// docs/EFFICIENCY.md's rows describe, so a figure here belongs to this table and not to whatever the owner has placed. A change to that
    /// default belongs here too.
    static let scratchLayout = """
    {
      "top": {"start": [{"atoms": ["compat"], "id": "compat"}], "center": [],
              "end": [{"atoms": ["ext:bat", "ext:clock"], "id": "status"}]},
      "bottom": {"start": [], "center": [{"atoms": ["ext:cpu"], "id": "cpu"}],
                 "end": [{"atoms": ["ext:net", "ext:vol"], "id": "link"}, {"atoms": ["ext:weather"], "id": "sky"}]},
      "left": {"start": [{"atoms": ["ext:workspaces", "ext:appicon"], "id": "workspaces"}], "center": [],
               "end": [{"atoms": ["ext:usage", "ext:fan"], "id": "system"}]},
      "right": {"start": [], "center": [], "end": []},
      "hugTop": false, "hugBottom": false, "hugLeft": true, "hugRight": true,
      "gap": 8,
      "on": {"top": true, "bottom": true, "left": true, "right": false},
      "spill": {"top": "fill", "bottom": "fill", "left": "fill", "right": "fill"}
    }
    """

    /// The config a run is measured against: valid JSON with no keys, so every setting is riskell's default and the owner's drop-in pills are
    /// not read (`AppConfig.pillsDirectory` is the `pills` folder next to the config file).
    static let scratchConfig = "{}"

    /// The machine, the OS, the build and the files a number belongs to. Without them a number says nothing: the same layout on another
    /// machine, or the same machine on another build, is another figure. The two file fields carry the word `scratch` and what the file holds
    /// beside the path, because bench writes both: a reader of a number can see it is not the owner's layout.
    struct Fingerprint {
        let machine: String         // hw.model
        let os: String              // macOS version and build
        let revision: String        // git rev-parse --short HEAD, or "unknown" outside a git checkout
        let binary: String
        let layout: String          // this run's layout.json, written by bench in its scratch folder
        let config: String          // and its config.json
        let cores: Int
    }

    /// The built app and a scratch folder of this run's own: the layout and the config are written into it (`scratchLayout`, `scratchConfig`)
    /// and the instance writes everything else there too, so a run never reads the owner's layout, never writes into ~/.config/riskell and
    /// leaves nothing behind.
    private static func setup() -> Setup {
        guard let root = checkout() else {
            Usage.failure("run it inside the riskell checkout (no extensions.lock.json above here)")
            exit(1)
        }
        let binary = root + "/.build/release/riskell"
        guard fm.isExecutableFile(atPath: binary) else {
            Usage.failure("the app is not built, and these numbers are measured on it",
                          tries: [(cmd: "swift build -c release", note: "builds .build/release/riskell")])
            exit(1)
        }
        let scratch = "/tmp/risk-bench-\(getpid())"
        let layout = scratch + "/layout.json", config = scratch + "/config.json"
        try? fm.removeItem(atPath: scratch)          // a folder a killed run of this pid left is not a fixture to trust
        do {
            try fm.createDirectory(atPath: scratch + "/cache", withIntermediateDirectories: true)
            try scratchLayout.write(toFile: layout, atomically: true, encoding: .utf8)
            try scratchConfig.write(toFile: config, atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(atPath: scratch)
            Usage.failure("could not write the scratch layout and config in \(scratch): \(error)")
            exit(1)
        }
        return Setup(binary: binary, layout: layout, config: config, scratch: scratch)
    }

    /// The machine, the OS, the build and the two files this run wrote, each named with the word `scratch`, so a number can never be read as
    /// the owner's layout.
    private static func fingerprint(_ setup: Setup) -> Fingerprint {
        let root = checkout() ?? ""
        let revision = sh(["git", "rev-parse", "--short", "HEAD"], in: root.isEmpty ? nil : root)
        let os = sh(["sw_vers", "-productVersion"]).1 + " (" + sh(["sw_vers", "-buildVersion"]).1 + ")"
        return Fingerprint(machine: sh(["sysctl", "-n", "hw.model"]).1, os: "macOS " + os,
                           revision: revision.0 == 0 ? revision.1 : "unknown", binary: setup.binary,
                           layout: setup.layout + " (scratch: the classic preset)",
                           config: setup.config + " (scratch: an empty config)", cores: Int(sh(["sysctl", "-n", "hw.ncpu"]).1) ?? 0)
    }

    // MARK: - the command

    static func run(_ args: [String]) -> Int32 {
        var list = false, json = false
        var runs: Int?
        var words: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--list": list = true
            case "--json": json = true
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
            guard words.isEmpty, runs == nil else { return usage("--list prints the table and starts nothing: it takes no measure and no --runs") }
            return printList(json: json)
        }
        switch words.first {
        case "idle" where words.count == 1:
            return runMeasures([measures[0]], count: runs ?? 3, json: json)
        case "card" where words.count == 2:
            guard let card = measure(named: words[1]), card.hot != nil else { return unknownCard(words[1]) }
            return runMeasures([card], count: runs ?? 3, json: json)
        case "all" where words.count == 1:
            return runMeasures(measures, count: runs ?? 1, json: json, narrate: true)
        default:
            return usage("name a measure: idle, card <atom> or all")
        }
    }

    /// The value of a flag: the next argument, unless it is another flag.
    private static func value(_ i: inout Int, _ args: [String]) -> String? {
        guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
        i += 1
        return args[i]
    }

    /// The words `bench card` knows, printed when one of them was mistyped: exit 2 with the list, since an atom nobody measures would
    /// otherwise leave an empty screen that reads like a measurement of nothing. `--list` prints the same measures with their figures.
    private static func unknownCard(_ word: String) -> Int32 {
        let cards = measures.filter { $0.hot != nil }.map { $0.id.replacingOccurrences(of: "card:", with: "") }
        return usage("no card \"\(word)\": the cards are \(cards.joined(separator: ", ")) (bench --list prints them all)")
    }

    // MARK: - --list

    /// The measures as data: what each costs, how long one run takes and whether docs/EFFICIENCY.md claims it (the JSON also says what a
    /// run needs). Pure: no instance is started, and nothing of the owner's is read.
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
        print(listing(tty).joined(separator: "\n"))
        return 0
    }

    private static func publishedJSON(_ published: Published?) -> String {
        guard let p = published else { return "null" }
        return "{\"text\": \(jsonQuoted(p.text)), \"percent\": [\(number(p.low)), \(number(p.high))], \"seconds\": "
            + (p.seconds.map(number) ?? "null") + "}"
    }

    /// The table as a terminal prints it: one check a measure, its one line, how long a run is and the figure the page claims. A check, not
    /// a table, because the published row is a sentence that must not be cut: it wraps under its own column instead.
    private static func listing(_ tty: Tty) -> [String] {
        let claimed = measures.filter { $0.published != nil }.count
        var lines = [tty.header("bench", detail: "\(measures.count) measures, \(claimed) claimed in docs/EFFICIENCY.md")]
        lines += tty.checks(measures.map { measure in
            let cost = "\(measure.summary) · \(measure.window) s"
                + (measure.published.map { " · published " + $0.text } ?? " · not published")
            return (Tone.note, measure.id, cost, nil)
        })
        lines.append("")
        lines += tty.paragraph("published is the \"after\" column of docs/EFFICIENCY.md, measured on \(publishedMachine); --list starts nothing")
        lines.append(tty.footerHint([(cmd: "risk bench idle", text: "the idle figure, three runs"),
                                     (cmd: "risk bench all", text: "every measure, once each")]))
        return lines
    }

    // MARK: - the scratch instance

    /// The one instance a run has going, the busy loops the loaded measure keeps for its whole length, and this run's folder: all three go
    /// however the command ends, and the instance's `--stay` is the last resort.
    private static var scratch = ""
    private static var child: Process?
    private static var loads: [Process] = []
    private static var signalSources: [DispatchSourceSignal] = []

    /// The seconds an instance gets to draw its bars and take its first readings before the measured window starts. `before` counts it into
    /// a measure's cost, so `bench all` can say how long it is about to take instead of leaving the screen to guess.
    private static let settle = 10

    /// Runs one measure `count` times, in order. Each run is a scratch instance of the built app: its own config, layout, cache and event
    /// socket, `--no-reserve` so it never takes the running bar's, and `--stay` so it cannot outlive this process. Ten seconds to settle (the
    /// bars drawn, the first readings in), then the CPU seconds it uses over `measure.window`.
    private static func samples(_ measure: Measure, count: Int, _ setup: Setup) -> [Sample] {
        if measure.loaded { startLoad() }
        defer { stopLoad() }
        var out: [Sample] = []
        for index in 0..<count {
            let shots = setup.scratch + "/snap-\(measure.id)-\(index)"
            try? fm.createDirectory(atPath: shots, withIntermediateDirectories: true)
            let instance = Process()
            instance.executableURL = URL(fileURLWithPath: setup.binary)
            instance.arguments = ["--no-usage", "--no-reserve", "--fake-media", "--snap", shots, "--stay", "\(measure.window + 14)"]
            instance.environment = environment(measure, setup)
            instance.standardOutput = FileHandle.nullDevice
            instance.standardError = FileHandle.nullDevice
            child = instance
            do { try instance.run() } catch {
                child = nil
                Usage.failure("could not start \(setup.binary): \(error)")
                exit(1)
            }
            let pid = instance.processIdentifier
            pause(Double(settle))
            let start = cpuSeconds(pid)
            pause(Double(measure.window))
            let used = cpuSeconds(pid) - start
            let sample = Sample(seconds: used, percent: used * 100 / Double(measure.window), memory: residentMB(pid), threads: threadCount(pid))
            let alive = instance.isRunning
            instance.terminate()        // SIGTERM: the app shuts down cleanly, and --stay is the way out if it does not
            instance.waitUntilExit()
            child = nil
            guard alive else {
                Usage.failure("the instance exited during run \(index + 1) of \(measure.id): a dead process's CPU time is not a measurement",
                              tries: [(cmd: invocation(measure) + " --runs 1", note: "try that measure on its own")])
                exit(1)
            }
            out.append(sample)
        }
        return out
    }

    /// The instance's environment: everything the caller had except its own RISKELL_ variables, then this run's. A stray RISKELL_FORCE_HOT
    /// in the shell therefore cannot open a card on the idle measure, and nothing can point an instance at a real config, cache or socket.
    private static func environment(_ measure: Measure, _ setup: Setup) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("RISKELL_") }
        env["RISKELL_CONFIG"] = setup.config
        env["RISKELL_LAYOUT"] = setup.layout
        env["RISKELL_CACHE_DIR"] = setup.scratch + "/cache"
        env["RISKELL_EVENT_SOCKET"] = setup.scratch + "/ev.sock"
        env["RISKELL_DEMO"] = "1"           // placeholder names for devices, volumes, processes and addresses
        if let hot = measure.hot { env["RISKELL_FORCE_HOT"] = hot }
        return env
    }

    /// The instance's CPU time in seconds: `ps -o cputime` prints `MM:SS.ss`, and `HH:MM:SS.ss` past an hour.
    private static func cpuSeconds(_ pid: Int32) -> Double {
        let parts = sh(["ps", "-o", "cputime=", "-p", "\(pid)"]).1.trimmingCharacters(in: .whitespaces).split(separator: ":")
        let numbers = parts.compactMap { Double($0) }
        guard !numbers.isEmpty, numbers.count == parts.count else { return 0 }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }

    /// Resident memory in MB, as `scripts/resource-check` reads it.
    private static func residentMB(_ pid: Int32) -> Int { Int((Double(sh(["ps", "-o", "rss=", "-p", "\(pid)"]).1) ?? 0) / 1024) }

    /// `ps -M` prints a line a thread, plus a header.
    private static func threadCount(_ pid: Int32) -> Int {
        max(0, sh(["ps", "-M", "-p", "\(pid)"]).1.split(separator: "\n").count - 1)
    }

    /// One busy loop a core, so "every core busy" means what it says. Nothing of it survives the measure.
    private static func startLoad() {
        let cores = Int(sh(["sysctl", "-n", "hw.ncpu"]).1) ?? 1
        for _ in 0..<max(1, cores) {
            let loop = Process()
            loop.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            loop.standardOutput = FileHandle.nullDevice
            loop.standardError = FileHandle.nullDevice
            guard (try? loop.run()) != nil else { continue }
            loads.append(loop)
        }
    }

    private static func stopLoad() {
        for loop in loads where loop.isRunning { loop.terminate() }
        for loop in loads { loop.waitUntilExit() }
        loads = []
    }

    /// The instance, the loops and the folder: what a ^C or a kill must never leave behind. (`exit` in a signal handler skips the `defer`
    /// in the run, so the handler calls this itself.)
    private static func stopEverything() {
        if let instance = child, instance.isRunning {
            instance.terminate()
            instance.waitUntilExit()
        }
        child = nil
        stopLoad()
        if !scratch.isEmpty { try? fm.removeItem(atPath: scratch) }
    }

    private static func watchSignals() {
        guard signalSources.isEmpty else { return }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                stopEverything()
                exit(128 + sig)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func pause(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

    // MARK: - the runs

    /// The run itself: the measures picked out, the scratch folder, the trap that kills whatever it starts, then the numbers in the form the
    /// caller asked for. Every path out of here goes through `defer stopEverything()`, and every measure is measured by `samples`, whether it was
    /// named on its own or came with `all`. `narrate` decides only when the lines are printed: `bench all` says what it is about to do before the
    /// first run and a line a measure as each finishes, since minutes pass before its report; a `--json` caller gets the one object and none of
    /// the talk.
    private static func runMeasures(_ picked: [Measure], count: Int, json: Bool, narrate: Bool = false) -> Int32 {
        guard !picked.isEmpty else { return usage("nothing to measure") }
        let setup = setup()
        scratch = setup.scratch
        watchSignals()
        defer { stopEverything() }
        let mark = fingerprint(setup)
        let tty = Terminal.tty(), pad = picked.map(\.id.count).max() ?? 0
        let talking = narrate && !json
        if talking { say(before(picked, count: count, tty).joined(separator: "\n")) }
        var results: [Result] = []
        for measure in picked {
            let result = Result(measure, samples(measure, count: count, setup))
            results.append(result)
            if talking { say(tty.check(tone(result, machine: mark.machine), measure.id, numbers(result), keyWidth: pad + 1).joined(separator: "\n")) }
        }
        if json { print(jsonReport(results, mark)) }
        else if talking { print(trailer(results, count: count, mark: mark, tty).joined(separator: "\n")) }
        else { print(report(results, mark, tty).joined(separator: "\n")) }
        return 0
    }

    /// A line `bench all` prints while it measures, flushed at once: a pipe holds its buffer until the process exits, and the point of the line
    /// is that someone can see where a six-minute run has got to, or find out where it stopped.
    private static func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// What `bench all` is about to do, printed before the first run: the measures are 20 to 30 s each and six minutes together, and a command
    /// that says nothing for six minutes looks like one that is stuck. A run costs `settle` plus the measure's window.
    private static func before(_ picked: [Measure], count: Int, _ tty: Tty) -> [String] {
        let dim = Style(fg: tty.palette.color(.text4, tty.mode))
        let each = count == 1 ? "one run each" : "\(count) runs each"
        let estimate = count * picked.reduce(0) { $0 + $1.window + settle }
        var lines = tty.table(title: "bench all", meta: "\(picked.count) measures",
                              columns: [Column(priority: 3), Column(priority: 2), Column(priority: 1)],
                              rows: picked.map { measure in
                                  [tty.statusDot(.note),
                                   Cell(measure.id, .left, Style(bold: true)),
                                   Cell(measure.summary, .left, Style(fg: tty.palette.color(.text3, tty.mode))),
                                   Cell("\(measure.window) s", .right, dim)]
                              })
        lines.append("")
        lines += tty.paragraph("\(each), about \(duration(estimate)); every run is a scratch instance, killed however this command ends")
        return lines
    }

    /// A run's cost, rounded the way someone waiting for it would say it out loud.
    private static func duration(_ seconds: Int) -> String {
        seconds < 90 ? "\(seconds) s" : "\(Int((Double(seconds) / 60).rounded())) minutes"
    }

    /// The median of one finished measure, as `bench all` prints it the moment the measure is done: what it used, beside nothing yet —
    /// the page's figure is set beside it once, at the end, because on this machine it can never be reproduced (`verdict`).
    private static func numbers(_ result: Result) -> String {
        let median = result.median
        return "\(fixed(median.seconds)) s · \(fixed(median.percent)) % · \(median.memory) MB · \(median.threads) threads"
    }

    /// The tone a finished measure is marked with: what its verdict on the published figure says, and dim when there is nothing to compare.
    private static func tone(_ result: Result, machine: String) -> Tone {
        guard let verdict = verdict(result, machine: machine) else { return .note }
        switch verdict {
        case .reproduced, .below: return .ok
        case .exceeded: return .crit
        case .cannotCompare: return .note
        }
    }

    /// What the measures of one `all` share, said once rather than a block each: the fingerprint the numbers belong to, the note a single run
    /// needs, and the reason a published figure cannot be compared with one measured here (see `verdict`).
    private static func trailer(_ results: [Result], count: Int, mark: Fingerprint, _ tty: Tty) -> [String] {
        var lines = [""]
        lines += fingerprintRows(mark, tty)
        if count < 3 {
            lines += tty.check(.warn, "one run each", "a single run is noise of about ±0.1 s",
                               hint: (cmd: "risk bench idle --runs 3", note: "a median instead of one run"), keyWidth: 14)
        }
        let claimed = results.filter { $0.measure.published != nil }.count
        if claimed > 0 {
            lines += tty.check(.warn, "cannot compare",
                               "\(claimed) published figure\(claimed == 1 ? "" : "s"): the page measured another machine, on another layout",
                               hint: (cmd: "risk bench --list", note: "which measures the page claims"), keyWidth: 14)
        }
        lines.append("")
        lines.append(tty.footerHint([(cmd: "risk bench --list", text: "every measure and its figure")]))
        return lines
    }

    private static func sampleJSON(_ sample: Sample) -> String {
        "{\"seconds\": \(fixed(sample.seconds)), \"percent\": \(fixed(sample.percent)), \"memory\": \(sample.memory), \"threads\": \(sample.threads)}"
    }

    private static func fingerprintJSON(_ mark: Fingerprint) -> String {
        "{\"machine\": \(jsonQuoted(mark.machine)), \"os\": \(jsonQuoted(mark.os)), \"revision\": \(jsonQuoted(mark.revision)), "
            + "\"binary\": \(jsonQuoted(mark.binary)), \"layout\": \(jsonQuoted(mark.layout)), \"config\": \(jsonQuoted(mark.config)), "
            + "\"cores\": \(mark.cores)}"
    }

    /// Every run, its median, the spread, the fingerprint, the published figure and the verdict: one object, so a script reads the same
    /// numbers the terminal prints.
    private static func jsonReport(_ results: [Result], _ mark: Fingerprint) -> String {
        let rows = results.map { r in
            let noise = r.noise.map { "{\"seconds\": \(fixed($0)), \"percent\": \(fixed($0 * 100 / Double(r.measure.window)))}" } ?? "null"
            return "{\"measure\": \(jsonQuoted(r.measure.id)), \"window\": \(r.measure.window), \"runs\": \(r.samples.count), "
                + "\"samples\": [" + r.samples.map(sampleJSON).joined(separator: ", ") + "], "
                + "\"median\": " + sampleJSON(r.median) + ", \"noise\": " + noise
                + ", \"published\": " + publishedJSON(r.measure.published)
                + ", \"verdict\": " + (verdict(r, machine: mark.machine).map { jsonQuoted($0.rawValue) } ?? "null") + "}"
        }
        return "{\"schema\": \(schema), \"fingerprint\": " + fingerprintJSON(mark) + ", \"results\": [\n  "
            + rows.joined(separator: ",\n  ") + "\n]}"
    }

    /// The runs as a terminal prints them: a table a measure — the samples and the median, what the measure is, and the spread when there
    /// is one — then the fingerprint the numbers belong to, and how each median stands beside the page's figure.
    private static func report(_ results: [Result], _ mark: Fingerprint, _ tty: Tty) -> [String] {
        let dim = Style(fg: tty.palette.color(.text4, tty.mode))
        var lines: [String] = []
        for result in results {
            let window = result.measure.window
            func row(_ tone: Tone, _ label: String, _ sample: Sample, bold: Bool) -> [Cell] {
                [tty.statusDot(tone), Cell(label, .left, Style(bold: bold)), Cell(fixed(sample.seconds) + " s", .right),
                 Cell(fixed(sample.percent) + " %", .right), Cell("\(sample.memory) MB", .right, dim), Cell("\(sample.threads) threads", .right, dim)]
            }
            var rows = result.samples.enumerated().map { index, sample in row(.note, "run \(index + 1)", sample, bold: false) }
            rows.append(row(.ok, "median", result.median, bold: true))
            if !lines.isEmpty { lines.append("") }
            let runs = result.samples.count == 1 ? "one run of \(window) s" : "\(result.samples.count) runs of \(window) s"
            lines += tty.table(title: "bench " + result.measure.id, meta: runs,
                               columns: [Column(priority: 4), Column(priority: 3), Column(priority: 2), Column(priority: 1), Column(priority: 1)],
                               rows: rows)
            lines.append("")
            lines += tty.paragraph(result.measure.summary)
            if let noise = result.noise {
                lines += tty.check(.note, "noise", "±\(fixed(noise)) s between runs (\(fixed(noise * 100 / Double(window))) %)", keyWidth: 8)
            } else {
                lines += tty.check(.warn, "one run", "a single run is noise of about ±0.1 s",
                                   hint: (cmd: invocation(result.measure) + " --runs 3", note: "a median instead of one run"), keyWidth: 8)
            }
        }
        lines.append("")
        lines += fingerprintRows(mark, tty)
        for result in results {
            guard let published = result.measure.published, let verdict = verdict(result, machine: mark.machine) else { continue }
            let here = "\(fixed(result.median.seconds)) s over \(result.measure.window) s (\(fixed(result.median.percent)) %)"
            lines.append("")
            switch verdict {
            case .cannotCompare:
                lines += tty.check(.warn, "cannot compare", "\(here) · published \(published.text)",
                                   hint: (cmd: "risk bench --list", note: "which measures the page claims"), keyWidth: 15)
            case .reproduced:
                lines += tty.check(.ok, "reproduced", "\(here) · inside the published \(published.text)", keyWidth: 15)
            case .exceeded:
                lines += tty.check(.crit, "exceeded", "\(here) · above the published \(published.text)", keyWidth: 15)
            case .below:
                lines += tty.check(.ok, "below", "\(here) · under the published \(published.text)", keyWidth: 15)
            }
        }
        lines.append("")
        lines.append(tty.footerHint([(cmd: "risk bench --list", text: "every measure and its figure")]))
        return lines
    }

    /// A measured number in JSON and in the terminal: two decimals, which is finer than the noise, so nothing is rounded into looking better.
    private static func fixed(_ value: Double) -> String { String(format: "%.2f", value) }

    /// The machine, the build and the two scratch files the numbers belong to, as checks: printed once, under the runs they explain.
    private static func fingerprintRows(_ mark: Fingerprint, _ tty: Tty) -> [String] {
        let shown = mark.binary.replacingOccurrences(of: (checkout() ?? "") + "/", with: "")
        return tty.checks([
            (Tone.note, "machine", "\(mark.machine) · \(mark.os) · \(mark.cores) cores", nil),
            (Tone.note, "build", "\(mark.revision) · \(shown)", nil),
            (Tone.note, "layout", mark.layout, nil),
            (Tone.note, "config", mark.config, nil),
        ])
    }

    /// A number in JSON: no trailing `.0`, and two decimals at most, so 1.1 stays 1.1 and 0.25 stays 0.25.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    // MARK: - output

    private static func usage(_ problem: String?) -> Int32 {
        Usage.error("bench", problem ?? "name a measure: idle, card <atom> or all")
    }
}
