// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Darwin
import Dispatch
import Foundation
import RiskellTTY

/// `riskell-ext snap`: the picture set written down once, and the one command that draws it.
///
/// The app can photograph itself — `--snap` (the four bars), `--pop` (one hover card), `--settings` (the preferences panel), `--edit` (the bars
/// while the layout editor is open) and the `overview` / `overview-snap` socket words — and four scripts each drove those flags their own way.
/// This command is that seam. Every maker starts a scratch instance of the built app and writes its pictures into `--out`; nothing of the
/// owner's is read or written (its own config, layout, cache, event socket and wallpaper, and `--no-reserve`, so it never takes the running
/// bar's socket or OmniWM's gaps), and the instance is killed however the command ends.
///
/// `makers` below is the whole picture set. The final pictures in `docs/images` are composed from these files by `scripts/make-screenshots`
/// (Pillow draws the grids, the captions, the hero screen and the gif), so its makers are rows here too, each naming the snapshots it is made
/// from; `--list` reads the script's own maker list and fails when the two have drifted, so a picture can no longer appear in a script and
/// nowhere else.
enum Snap {
    static let schema = "riskell.snap/1"
    /// The scheme, display and card a picture is made with when the flags say nothing (the values `scripts/make-screenshots` uses).
    static let defaultTheme = "gruvbox-dark-medium"
    static let defaultDisplay = "2268x1473:notch=48,278"
    static let defaultCard = "date"
    /// The most scratch instances one invocation may start. Each is a few seconds of the app's own timing, so the whole set over every scheme
    /// (55 of them, about four minutes) is refused with its count rather than started.
    static let maxRuns = 24

    /// Who runs the makers of this picture.
    enum DrawnBy: String {
        case snap       // an instance `risk snap` starts
        case script     // scripts/make-screenshots, which composes the final picture
    }

    /// One picture of the set. `files` are the names that land in `--out`, in the order the app writes them; `<atom>` is the hover card's atom.
    /// `snap` is the same list in the app's own names when they differ (the layout editor writes plain `top.png`). `feeds` joins the two sides:
    /// for a script row, the snap rows it is composed from; for a snap row it is worked out the other way round (`--list` prints it).
    struct Maker {
        let id: String
        let summary: String
        let files: [String]
        let snap: [String]?
        let instance: Bool      // making this picture runs a scratch riskell, here or through the script
        let by: DrawnBy
        let feeds: [String]

        init(_ id: String, _ summary: String, by: DrawnBy = .script, instance: Bool = true, files: [String] = [], snap: [String]? = nil,
             feeds: [String] = []) {
            self.id = id
            self.summary = summary
            self.by = by
            self.instance = instance
            self.files = files
            self.snap = snap
            self.feeds = feeds
        }
    }

    /// The picture set. The five `by: .snap` rows are what this command draws; the rest are the pictures the scripts compose, named here so
    /// the set is in one place and `--list` can tell when it has grown.
    static let makers: [Maker] = [
        Maker("bars", "the four bars at rest, one picture each", by: .snap,
              files: ["left.png", "right.png", "top.png", "bottom.png"]),
        Maker("card", "one atom's hover card, and the bars lit around it", by: .snap,
              files: ["pop-<atom>-1.png", "top-lit.png", "left-lit.png", "bottom-lit.png"],
              snap: ["pop-<card>-1.png", "top-lit.png", "left-lit.png", "bottom-lit.png"]),
        Maker("edit", "the top and bottom bars in the layout editor", by: .snap,
              files: ["edit-top.png", "edit-bottom.png"], snap: ["top.png", "bottom.png"]),
        Maker("settings", "riskell preferences, as the panel draws it", by: .snap, files: ["settings.png"]),
        // only the panel: `overview-snap` also writes overview-screen.png, a capture of the whole screen, which on a fake display is the owner's own
        Maker("overview", "the workspace overview, over a made-up desktop", by: .snap, files: ["overview.png"]),

        Maker("hero", "the whole screen: the bars over a made-up desktop", files: ["hero.png"], feeds: ["bars"]),
        Maker("cards", "every built-in hover card on one sheet", files: ["cards.png"], feeds: ["card"]),
        Maker("themes", "every scheme, as a grid and a gif", files: ["themes.png", "themes.gif"], feeds: ["bars"]),
        Maker("editor", "the preferences panel above the editing bars", files: ["editor.png"], feeds: ["settings", "edit"]),
        Maker("pills", "script pills at rest, and their cards", files: ["pills.png"], feeds: ["bars", "card"]),
        Maker("scale", "the bars at three display sizes", files: ["scale.png"], feeds: ["bars"]),
        Maker("extension", "a compiled extension's atom, card and strip", files: ["extension.png"]),
        Maker("installer", "the installer's two screens, from their text", instance: false, files: ["installer.png"]),
        Maker("architecture", "the layers, drawn from text", instance: false, files: ["architecture.png"]),
    ]

    // MARK: - the command

    static func run(_ args: [String]) -> Int32 {
        var list = false, json = false, dryRun = false
        var out: String?, theme = defaultTheme, display = defaultDisplay, scale: Double?, cardFlag: String?
        var words: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--list": list = true
            case "--json": json = true
            case "--dry-run": dryRun = true
            case "--out":
                guard let v = value(&i, args) else { return usage("--out needs a directory") }
                out = v
            case "--theme":
                guard let v = value(&i, args) else { return usage("--theme needs a scheme id, or all") }
                theme = v
            case "--display":
                guard let v = value(&i, args) else { return usage("--display needs WxH, e.g. 1920x1080") }
                guard matches(v, #"^\d+x\d+(:\w+=.*)?$"#) else { return usage("--display takes WxH, e.g. 1920x1080 or 1512x982:notch=32,185") }
                display = v
            case "--scale":
                guard let v = value(&i, args) else { return usage("--scale needs a number, e.g. 1.5") }
                guard let n = Double(v), n > 0 else { return usage("--scale takes a number, e.g. 1.5") }
                scale = n
            case "--card":
                guard let v = value(&i, args) else { return usage("--card needs an atom id, e.g. clock") }
                cardFlag = v
            default:
                guard !arg.hasPrefix("-") else { return usage("no flag \"\(arg)\"") }
                words.append(arg)
            }
            i += 1
        }

        if list {
            guard words.isEmpty, out == nil, cardFlag == nil else { return usage("--list takes no maker: it prints them all") }
            return printList(json: json)
        }

        // The makers: a word is a maker id, `all` is every picture this command draws, and a word after `card` is that card's atom.
        var picked: [Maker] = []
        var atom: String?
        for word in words {
            if let maker = makers.first(where: { $0.id == word }) {
                if !picked.contains(where: { $0.id == maker.id }) { picked.append(maker) }
            } else if word == "all" {
                for maker in makers where maker.by == .snap && !picked.contains(where: { $0.id == maker.id }) { picked.append(maker) }
            } else if atom == nil, cardFlag == nil, picked.contains(where: { $0.id == "card" }) {
                atom = word
            } else {
                return usage("no maker \"\(word)\": snap --list prints them all (a hover card's atom goes after it: risk snap card clock)")
            }
        }
        guard !picked.isEmpty else { return usage("name a maker, or all: snap --list prints them all") }
        let card = cardFlag ?? atom ?? defaultCard

        guard let root = checkout() else { return fail("run it inside the riskell checkout (no extensions.lock.json above here)") }
        let binary = root + "/.build/release/riskell"
        guard fm.isExecutableFile(atPath: binary) else { return fail("build first (swift build -c release)") }

        // A picture a script draws is not something this command can make: say which one, and which snapshots it is made from.
        let composed = picked.filter { $0.by == .script }
        if !composed.isEmpty {
            for maker in composed {
                let from = maker.feeds.isEmpty
                    ? "scripts/make-screenshots draws it from text alone, so there is no snapshot to take"
                    : "scripts/make-screenshots composes it from \(maker.feeds.map { "risk snap \($0)" }.joined(separator: ", "))"
                FileHandle.standardError.write(Data("risk snap: \(maker.id): \(from)\n".utf8))
            }
            return 1
        }

        var schemes = [theme]
        guard let bundled = bundledThemes(binary), !bundled.isEmpty else {
            return fail("could not read the schemes from \(binary) --list-themes")
        }
        if theme == "all" {
            schemes = bundled
        } else {
            guard bundled.contains(theme) else { return usage("no scheme \"\(theme)\": risk theme list prints them all") }
        }
        if picked.count * schemes.count > maxRuns {
            return usage("that is \(picked.count * schemes.count) scratch instances (\(picked.count) makers × \(schemes.count) schemes, a few seconds each). "
                         + "Name fewer makers — risk snap bars --theme all is \(bundled.count) — or one scheme.")
        }
        guard out != nil || dryRun else { return usage("--out DIR says where the pictures go") }

        return draw(picked, schemes: schemes, themeAll: theme == "all", card: card, display: display, scale: scale, out: out,
                    binary: binary, dryRun: dryRun, json: json)
    }

    /// The value of a flag: the next argument, unless it is another flag.
    private static func value(_ i: inout Int, _ args: [String]) -> String? {
        guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
        i += 1
        return args[i]
    }

    // MARK: - --list

    /// Every picture of the set: what this command draws, what the scripts compose, and what the script's maker list and this table disagree
    /// about. Findings mean the set has drifted, so they exit 1 like any other finding.
    private static func printList(json: Bool) -> Int32 {
        let script = scriptMakers()
        let findings = script.map { problems(in: $0) } ?? []
        if json {
            var rows: [String] = []
            for maker in makers {
                let join = maker.by == .snap
                    ? "\"feeds\": [" + makers.filter { $0.feeds.contains(maker.id) }.map { jsonQuoted($0.id) }.joined(separator: ", ") + "]"
                    : "\"from\": [" + maker.feeds.map(jsonQuoted).joined(separator: ", ") + "]"
                rows.append("{\"id\": \(jsonQuoted(maker.id)), \"summary\": \(jsonQuoted(maker.summary)), \"by\": \(jsonQuoted(maker.by.rawValue)), "
                            + "\"instance\": \(maker.instance), \"files\": [" + maker.files.map(jsonQuoted).joined(separator: ", ") + "], " + join + "}")
            }
            print("{\"schema\": \(jsonQuoted(schema)), \"makers\": [\n  " + rows.joined(separator: ",\n  ") + "\n], \"findings\": ["
                  + findings.map(jsonQuoted).joined(separator: ", ") + "]}")
            return findings.isEmpty ? 0 : 1
        }

        let tty = Terminal.tty(), pad = makers.map(\.id.count).max() ?? 0
        func line(_ id: String, _ text: String) -> String { "  " + tty.bold(id.padding(toLength: pad, withPad: " ", startingAt: 0)) + "  " + text }
        var lines = [tty.heading("snap") + tty.dim("  \(makers.count) pictures; \(makers.filter { $0.by == .snap }.count) drawn here")]
        lines.append("")
        lines.append("  " + tty.dim("risk snap <maker> --out DIR: one scratch instance per maker, killed however the command ends"))
        for maker in makers where maker.by == .snap {
            lines.append(line(maker.id, maker.summary))
            let from = makers.filter { $0.feeds.contains(maker.id) }.map(\.id)
            let target = maker.files.joined(separator: " ")
            lines.append("      " + tty.dim(target + (from.isEmpty ? "" : "  → " + from.joined(separator: ", "))))
        }
        lines.append("")
        lines.append("  " + tty.dim("scripts/make-screenshots composes these from the files above (Pillow: grids, captions, the hero screen, the gif)"))
        for maker in makers where maker.by == .script {
            lines.append(line(maker.id, maker.summary))
            let from = maker.feeds.isEmpty ? "no snapshot: drawn from text" : maker.feeds.map { "risk snap \($0)" }.joined(separator: ", ")
            lines.append("      " + tty.dim(maker.files.joined(separator: " ") + "  ← " + from))
        }
        for finding in findings {
            lines.append("")
            lines.append("  " + tty.tone("✗ ", .crit) + finding)      // not `mark`: a finding is longer than the terminal and must not be cut
        }
        lines.append("")
        print(lines.joined(separator: "\n"))
        return findings.isEmpty ? 0 : 1
    }

    /// The makers of `scripts/make-screenshots`, read from its `MAKERS` dict: the script needs Pillow, so its own list is the only record of
    /// what it draws. nil outside a checkout, or if the dict is not there, and then there is nothing to compare.
    private static func scriptMakers() -> [String]? {
        guard let root = checkout(), let text = read(root + "/scripts/make-screenshots") else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("MAKERS = {") }) else { return nil }
        var dict = ""
        for line in lines[start...] {      // the dict is a plain literal, one row a line; it closes on the first line with a `}`
            dict += line
            if line.contains("}") { break }
        }
        let parts = dict.split(separator: "\"", omittingEmptySubsequences: false)
        return stride(from: 1, to: parts.count, by: 2).map { String(parts[$0]) }
    }

    /// How the script's maker list and this table disagree: a maker the script has and no row names (the picture could be added to a script and
    /// forgotten), or a row claiming a picture the script no longer draws.
    private static func problems(in script: [String]) -> [String] {
        let named = Set(makers.map(\.id)), made = Set(script)
        var out = script.filter { !named.contains($0) }.map {
            "scripts/make-screenshots has a maker \"\($0)\" this table does not name: add it to Snap.makers, or drop it from the script"
        }
        out += makers.filter { $0.by == .script && !made.contains($0.id) }.map {
            "this table has \"\($0.id)\" as a picture scripts/make-screenshots draws, and the script has no such maker"
        }
        return out
    }

    // MARK: - drawing

    /// One scratch instance per maker (and per scheme), each picture moved into `--out` under the name the table gives it. The scratch folder
    /// is this process's alone (`/tmp/risk-snap-<pid>`) and goes away however the command ends.
    private static func draw(_ picked: [Maker], schemes: [String], themeAll: Bool, card: String, display: String, scale: Double?, out: String?,
                             binary: String, dryRun: Bool, json: Bool) -> Int32 {
        let tty = Terminal.tty()
        scratch = "/tmp/risk-snap-\(getpid())"
        if !dryRun {
            watchSignals()
            guard prepare(scratch, theme: schemes[0]) else { return fail("could not write the scratch files in \(scratch)") }
        }
        defer { stopEverything() }

        var manifest: [(String, [String])] = []
        var runs: [String] = []
        for maker in picked {
            for scheme in schemes {
                let label = maker.id + (schemes.count > 1 ? " \(scheme)" : "")
                let shots = scratch + "/" + maker.id + (schemes.count > 1 ? "-" + scheme : "")
                let prefix = namePrefix(scheme: scheme, all: themeAll, display: display, scale: scale)
                let names = maker.files.map { $0.replacingOccurrences(of: "<atom>", with: card) }
                let targets = names.map { name in out.map { $0 + "/" + prefix + name } ?? prefix + name }
                guard let args = arguments(maker, card: card, shots: shots) else { return fail("no runner for \"\(maker.id)\"") }
                let env = environment(scratch: scratch, shots: shots, display: display, scale: scale,
                                      layout: maker.id == "card" ? "card-layout.json" : "layout.json")
                let command = commandLine(binary, args, env)

                if dryRun {
                    runs.append(run(maker: maker, theme: scheme, command: command, files: targets))
                    if !json {
                        print(tty.bold(label))
                        print("  " + command)
                        print("  " + tty.dim("writes " + targets.joined(separator: " ")))
                    }
                    continue
                }
                if maker.id == "card", !put(layout(atom: card), scratch + "/card-layout.json") { return fail("could not write the card's layout") }
                if let problem = shoot(maker, binary: binary, args: args, env: env, shots: shots) { return fail(problem) }

                let written = (maker.snap ?? maker.files).map {
                    $0.replacingOccurrences(of: "<atom>", with: card).replacingOccurrences(of: "<card>", with: cardID(for: card))
                }
                for (index, target) in targets.enumerated() {
                    let from = shots + "/" + written[index]
                    guard fm.fileExists(atPath: from) else {
                        return fail("\(maker.id): the instance wrote no \(written[index])"
                                    + (maker.id == "card" ? " (does \"\(card)\" open a card?)" : ""))
                    }
                    if let out {
                        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
                        if fm.fileExists(atPath: target) { try? fm.removeItem(atPath: target) }
                    }
                    do { try fm.moveItem(atPath: from, toPath: target) } catch { return fail("could not write \(target)") }
                }
                manifest.append((label, targets))
                runs.append(run(maker: maker, theme: scheme, command: command, files: targets))
            }
        }
        if json {
            print("{\"schema\": \(jsonQuoted(schema)), \"out\": \(jsonQuoted(out ?? "")), \"dryRun\": \(dryRun), \"runs\": [\n  "
                  + runs.joined(separator: ",\n  ") + "\n]}")
            return 0
        }
        if dryRun { return 0 }      // nothing was written, and nothing says it was
        let pad = manifest.map(\.0.count).max() ?? 0
        for (label, files) in manifest {
            print(tty.bold(label.padding(toLength: pad, withPad: " ", startingAt: 0)) + "  " + files.joined(separator: " "))
        }
        let count = manifest.reduce(0) { $0 + $1.1.count }
        print("")
        print(tty.dim("\(count) file\(count == 1 ? "" : "s") in \(out ?? "the current directory")"))
        return 0
    }

    /// One line of the JSON manifest: what ran, the command it ran, and the files it wrote.
    private static func run(maker: Maker, theme: String, command: String, files: [String]) -> String {
        "{\"maker\": \(jsonQuoted(maker.id)), \"theme\": \(jsonQuoted(theme)), \"command\": \(jsonQuoted(command)), "
            + "\"files\": [" + files.map(jsonQuoted).joined(separator: ", ") + "]}"
    }

    /// The flags of one maker: the canonical scratch-instance set (`scripts/make-screenshots`), then what that picture needs and how long the
    /// app needs before it has drawn it (each flag writes its PNG on a delay: see Sources/riskell/main.swift).
    private static func arguments(_ maker: Maker, card: String, shots: String) -> [String]? {
        var args = ["--no-usage", "--no-reserve", "--fake-usage", "--fake-media", "--fake-heat", "--snap", shots]
        switch maker.id {
        case "bars": args += ["--stay", "4"]
        case "card": args += ["--stay", "9", "--pop", cardID(for: card)]      // the card is snapped 6 s after it opens
        case "edit": args += ["--stay", "5", "--edit"]
        case "settings": args += ["--stay", "6", "--settings"]   // the panel is snapped at 4.5 s
        case "overview": args += ["--stay", "12"]                // the socket words below take about 9 s
        default: return nil
        }
        return args
    }

    /// The app's card id for an atom (`--pop` takes the card's id, not the atom's): `Packages/*/Sources/…` declares it with `Card(id:)`, and
    /// only the clock's and the cpu's differ from their atom's id. An id that is not one of them is passed as it is, so a card id works too.
    private static func cardID(for atom: String) -> String {
        switch atom {
        case "clock": return "date"
        case "cpu": return "vitals"
        default: return atom.replacingOccurrences(of: "pill:", with: "pill.")
        }
    }

    /// The scratch instance's environment: everything the caller had except its own RISKELL_ variables, then the scratch ones. A stray
    /// `RISKELL_FORCE_HOT` or `RISKELL_SNAP_DIR` in the shell therefore cannot point an instance at a real file.
    private static func environment(scratch: String, shots: String, display: String, scale: Double?, layout: String = "layout.json") -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("RISKELL_") }
        env["RISKELL_CONFIG"] = scratch + "/config.json"
        env["RISKELL_LAYOUT"] = scratch + "/" + layout
        env["RISKELL_FAKE_DISPLAY"] = display
        env["RISKELL_CACHE_DIR"] = scratch + "/cache"
        env["RISKELL_EVENT_SOCKET"] = scratch + "/ev.sock"      // a unix socket path is at most 104 characters: /tmp keeps it short
        env["RISKELL_DEMO"] = "1"                               // placeholder names for devices, volumes, processes and addresses
        env["RISKELL_SNAP_DIR"] = shots                         // where `overview-snap` writes
        env["RISKELL_WALLPAPER"] = scratch + "/wallpaper.bmp"   // a made-up desktop, so the overview shows no one's own
        if let scale { env["RISKELL_SCALE"] = number(scale) }
        return env
    }

    /// The command as it would be typed: `env`, the RISKELL_ variables this command sets, the binary, its flags.
    private static func commandLine(_ binary: String, _ args: [String], _ env: [String: String]) -> String {
        let keys = env.keys.filter { $0.hasPrefix("RISKELL_") }.sorted()
        return (["env"] + keys.map { "\($0)=\(shell(env[$0] ?? ""))" } + [shell(binary)] + args.map(shell)).joined(separator: " ")
    }

    private static func shell(_ text: String) -> String {
        let plain = text.allSatisfy { $0.isLetter || $0.isNumber || "/._-:=,+".contains($0) }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The name a picture gets when the run is not the plain one: the scheme (always, with `--theme all`), the display and the scale, in that
    /// order, so two runs into the same `--out` cannot overwrite each other's picture.
    private static func namePrefix(scheme: String, all: Bool, display: String, scale: Double?) -> String {
        var parts: [String] = []
        if all || scheme != defaultTheme { parts.append(scheme) }
        if display != defaultDisplay {
            parts.append(display.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: ",", with: "x"))
        }
        if let scale { parts.append("scale" + number(scale)) }
        return parts.isEmpty ? "" : parts.joined(separator: "-") + "-"
    }

    private static func number(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : "\(value)" }

    // MARK: - the scratch instance

    /// The scratch folder of this run, and the one instance it has running: both go however the command ends, and `--stay` is the last resort.
    private static var scratch = ""
    private static var child: Process?
    private static var signalSources: [DispatchSourceSignal] = []

    /// Runs one maker's instance and waits for it. nil when it ended cleanly, otherwise what went wrong; nothing is left running either way.
    private static func shoot(_ maker: Maker, binary: String, args: [String], env: [String: String], shots: String) -> String? {
        try? fm.createDirectory(atPath: shots, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        child = process
        do { try process.run() } catch {
            child = nil
            return "could not start \(binary): \(error)"
        }
        if maker.id == "overview" { overviewWords(env["RISKELL_EVENT_SOCKET"] ?? "") }
        process.waitUntilExit()
        child = nil
        return process.terminationStatus == 0 ? nil : "the instance exited \(process.terminationStatus) making \(maker.id)"
    }

    /// The overview is opened and photographed through the app's own socket words, as `scripts/overview-check` does: after the instance has
    /// laid the bars out, open, snap, close. The snap is sent twice because the first capture can come back empty while the panel settles.
    private static func overviewWords(_ socket: String) {
        for _ in 0..<80 {
            if fm.fileExists(atPath: socket) { break }
            pause(0.1)
        }
        pause(1.5)
        try? Ctl.send("overview\n", to: socket)
        pause(3)
        try? Ctl.send("overview-snap\n", to: socket)
        pause(1.5)
        try? Ctl.send("overview-snap\n", to: socket)
        pause(1)
        try? Ctl.send("overview\n", to: socket)
    }

    /// The instance, then the folder: what a ^C, a kill or a failed picture must never leave behind. (`exit` in a signal handler skips the
    /// `defer` in `draw`, so the handler calls this itself.)
    private static func stopEverything() {
        if let process = child, process.isRunning {
            process.terminate()      // SIGTERM: the app shuts down cleanly, and --stay is the way out if it does not
            process.waitUntilExit()
        }
        child = nil
        if !scratch.isEmpty { try? fm.removeItem(atPath: scratch) }
    }

    /// ^C or a kill must not leave the instance behind: the signal source terminates it on a queue that runs without a run loop, then exits.
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

    /// The scratch config: the theme in force, the `command` window manager over four made-up workspaces, the same made-up city as
    /// `scripts/make-screenshots`, and usage on so its atom is drawn (`--no-usage` keeps it from reading anything).
    private static let stateScript = """
        #!/bin/sh
        echo '{"spaces":[{"id":1,"focused":true,"windows":2},{"id":2,"windows":2},{"id":3,"windows":1},{"id":4,"windows":0}],"windows":[{"id":101,"pid":1,"app":"Notes","title":"Shopping list","space":1,"focused":true},{"id":102,"pid":2,"app":"Terminal","title":"build","space":1},{"id":103,"pid":3,"app":"Browser","title":"Docs","space":2},{"id":104,"pid":4,"app":"Editor","title":"main.swift","space":2},{"id":105,"pid":5,"app":"Music","title":"Playlist","space":3}]}'

        """

    /// The layout the pictures show: the atoms `scripts/make-screenshots` places, on every bar (the app leaves the right strip empty), each
    /// bar opening flush cards. The card picture keeps the top bar to the one atom it opens from — and the right strip off, which would
    /// otherwise sit where the card hangs — so nothing else on that bar can take the pointer and open a different card.
    private static func layout(atom: String?) -> String {
        let topEnd = atom.map { "[{\"id\": \"card\", \"atoms\": [\(jsonQuoted(layoutAtom($0)))]}]" }
            ?? "[{\"id\": \"status\", \"atoms\": [\"ext:bat\", \"ext:clock\"]}]"
        return """
            {"top": {"start": [], "center": [], "end": \(topEnd)},
             "bottom": {"start": [], "center": [{"id": "cpu", "atoms": ["ext:cpu"]}], "end": [{"id": "sky", "atoms": ["ext:weather"]}]},
             "left": {"start": [{"id": "workspaces", "atoms": ["ext:workspaces"]}], "center": [],
                      "end": [{"id": "system", "atoms": ["ext:usage", "ext:fan"]}]},
             "right": {"start": [], "center": [], "end": [{"id": "link", "atoms": ["ext:net", "ext:vol"]}]},
             "hugTop": false, "hugBottom": false, "hugLeft": false, "hugRight": true, "gap": 8,
             "on": {"top": true, "bottom": true, "left": true, "right": \(atom == nil)},
             "spill": {"top": "fill", "bottom": "fill", "left": "fill", "right": "fill"}}

            """
    }

    /// The atom as the layout names it: a package atom is `ext:<id>` and a script pill `pill:<id>`.
    private static func layoutAtom(_ atom: String) -> String {
        atom.hasPrefix("ext:") || atom.hasPrefix("pill:") ? atom : "ext:" + atom
    }

    private static func prepare(_ scratch: String, theme: String) -> Bool {
        guard (try? fm.createDirectory(atPath: scratch + "/cache", withIntermediateDirectories: true)) != nil else { return false }
        guard put(stateScript, scratch + "/state.sh"), put(layout(atom: nil), scratch + "/layout.json"),
              putWallpaper(scratch + "/wallpaper.bmp") else { return false }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch + "/state.sh")
        return put(config(theme, scratch), scratch + "/config.json")
    }

    private static func config(_ theme: String, _ scratch: String) -> String {
        "{\"theme\": \(jsonQuoted(theme)), \"wm\": \"command\", \"wmCommand\": {\"state\": \(jsonQuoted(scratch + "/state.sh"))}, "
            + "\"location\": {\"name\": \"Hamburg\", \"lat\": 53.55, \"lon\": 10.0}, \"usage\": {\"claude\": true}}"
    }

    private static func put(_ text: String, _ path: String) -> Bool {
        write(text, path)
        return fm.fileExists(atPath: path)
    }

    /// A made-up desktop picture for the overview's tiles: a 24-bit BMP, which ImageIO reads and which needs no compressor (the app is the only
    /// thing here that may draw, and this tool links no graphics library). Eight pixels wide and 256 tall: the overview scales it, so all it is
    /// is a dark gradient.
    private static func putWallpaper(_ path: String) -> Bool {
        let width = 8, height = 256
        var body = Data()
        for y in stride(from: height - 1, through: 0, by: -1) {          // BMP rows are bottom-up, in BGR
            let t = Double(y) / Double(height - 1)
            let pixel = [UInt8(58 + 40 * t), UInt8(38 + 22 * (1 - t)), UInt8(34 + 26 * t)]
            for _ in 0..<width { body.append(contentsOf: pixel) }
            for _ in 0..<(4 - (width * 3) % 4) % 4 { body.append(0) }     // a row is padded to four bytes
        }
        var out = Data("BM".utf8)
        out.append(le32(14 + 40 + body.count))      // the file's size
        out.append(le32(0))                         // reserved
        out.append(le32(0))                         // reserved
        out.append(le32(14 + 40))                   // where the pixels start
        out.append(le32(40))                        // the header's size
        out.append(le32(width))
        out.append(le32(height))
        out.append(le16(1))                         // planes
        out.append(le16(24))                        // bits per pixel
        out.append(le32(0))                         // no compression
        out.append(le32(body.count))                // the pixels' size
        out.append(le32(2835))                      // pixels per metre, x and y
        out.append(le32(2835))
        out.append(le32(0))                         // colours used
        out.append(le32(0))                         // important colours
        out.append(body)
        try? out.write(to: URL(fileURLWithPath: path))
        return fm.fileExists(atPath: path)
    }

    private static func le16(_ value: Int) -> Data { Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]) }
    private static func le32(_ value: Int) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
    }

    /// The bundled schemes, asked of the built app: the one place that knows them (`riskell --list-themes`).
    private static func bundledThemes(_ binary: String) -> [String]? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--list-themes"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return rows.compactMap { $0["id"] as? String }
    }

    // MARK: - output

    private static func usage(_ problem: String) -> Int32 {
        FileHandle.standardError.write(Data("""
            risk snap: \(problem)
            usage: risk snap --list [--json]
                   risk snap <maker> [<maker>…] | all --out DIR [--theme ID|all] [--scale N] [--display WxH] [--card ATOM] [--dry-run] [--json]

            """.utf8))
        return 2
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data(("risk snap: " + message + "\n").utf8))
        return 1
    }
}
