import Foundation
import RiskellTTY

// riskell-setup: the guided installer for riskell. One binary, several modes (see Cli.swift and docs/INSTALL.md).

setvbuf(stdout, nil, _IOLBF, 0)

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let paths = Paths.fromEnvironment()
let repo = Detect.findRepo(flag: options.repo)

/// The usage line a wrong flag is shown against, and the page that prints every option.
let setupSynopsis = "riskell-setup [options]"
let setupTries: [(cmd: String, note: String)] = [("risk help setup", "every option, with its values")]

/// A wrong flag or a failed run: the kit's error block on stderr, the same shape every command uses. The exit status is the caller's.
func fail(_ message: String, code: Int32 = 2) -> Never {
    let tty = Tty.themed()
    let lines = tty.errorBlock(title: message, detail: setupSynopsis, tries: setupTries)
    FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    exit(code)
}

if !options.errors.isEmpty {
    fail(options.errors.joined(separator: "; "))
}

switch options.mode {
case .help:
    print(Options.help(Tty.themed()).joined(separator: "\n"))
    exit(0)
case .version:
    print("riskell-setup \(riskellVersion)")
    exit(0)
case .selfTest:
    exit(SelfTest.run(repo: repo))
case .snapshot:
    guard let name = options.snapshotName, Snapshots.names.contains(name) else {
        fail("--snapshot wants one of: \(Snapshots.names.joined(separator: ", "))")
    }
    Term.write(Snapshots.text(name, w: options.width, h: options.height, ansi: options.ansi))
    exit(0)
case .snapshotDir:
    do {
        try Snapshots.writeAll(to: options.snapshotDirPath ?? "docs/installer-snapshots")
    } catch {
        fail("could not write the snapshots: \(error)", code: 1)
    }
    print(Tty.themed().checks([(.ok, "snapshots", "wrote \(Snapshots.names.count) screens at \(Snapshots.sizes.count) sizes", nil)]).joined(separator: "\n"))
    exit(0)
case .check:
    // --json and --bundle ask for the grouped report; without them the installer's checklist is the kit's checks, and the status it always had
    exit(options.json || options.bundle != nil ? Doctor.run(options, paths: paths, repo: repo, label: "com.rish.riskell")
                                               : Modes.check(paths: paths, label: "com.rish.riskell"))
case .doctor:
    exit(Doctor.run(options, paths: paths, repo: repo, label: "com.rish.riskell"))
case .uninstall:
    exit(Modes.uninstall(options, paths: paths, label: "com.rish.riskell", repo: repo))
case .yes:
    exit(Modes.yes(options, paths: paths, repo: repo))
case .tui:
    break
}

// The guided flow needs a terminal. Without one, print the plan and point at --yes.
guard isatty(1) == 1, isatty(0) == 1 else {
    let app = Modes.makeApp(options, paths: paths, repo: repo)
    let tty = Tty.themed()
    print(Modes.dryRun(app, tty: tty))
    print(tty.empty("the guided flow needs a terminal", hint: (cmd: "risk setup --yes", text: "install with the detected defaults, without questions")).joined(separator: "\n"))
    exit(0)
}

let app = App(facts: Detect.gather(paths, label: "com.rish.riskell"), paths: paths, repo: repo)
app.noBuild = options.noBuild
app.noLaunch = options.noLaunch
app.dryRun = options.dryRun
Term.start()
var size = Term.size()
var live: RiskellTTY.Progress?
var liveFinished = false

func installTty() -> Tty {
    App.liveTty(width: Term.size().w)
}

/// Draws the whole frame in place: every line overwrites its own, and the rest of the screen is erased. The kit's lines carry their
/// own colour and width, so nothing here decides either.
func paint() {
    let tty = App.liveTty(width: size.w)
    let lines = app.screen(tty, height: size.h)
    var out = "\u{1b}[H"
    for (i, line) in lines.enumerated() {
        out += line + "\u{1b}[K"
        if i < lines.count - 1 { out += "\r\n" }
    }
    out += "\u{1b}[J"
    Term.write(out)
}

/// The install screen: the kit's header, then `Progress` owns the line and prints each step as it finishes.
func startLive() {
    let tty = installTty()
    var out = "\u{1b}[H"
    for line in app.installHeaderLines(tty) { out += line + "\u{1b}[K\r\n" }
    Term.write(out)
    live = RiskellTTY.Progress(tty: tty, steps: stepNames)
    liveFinished = false
    Term.restoreSignals()
}

func handleJob(_ event: JobEvent) {
    switch event {
    case .stepStart(let i):
        if live == nil || liveFinished { startLive() }
        live?.begin(i)
    case .stepLog:
        break
    case .stepDone(let i, let detail):
        live?.finish(i, .ok, detail: detail)
    case .stepSkipped(let i, let detail):
        live?.finish(i, .note, detail: detail)
    case .failed(let i, let message, let tail):
        live?.finish(i, .crit, detail: message)
        liveFinished = true
        let tty = installTty()
        var out = "\r\n"
        out += tty.errorBlock(title: message, detail: nil,
                              tries: [(cmd: "enter", note: "try again; finished steps are not repeated"),
                                      (cmd: "esc", note: "back to the review")]).joined(separator: "\r\n")
        for line in tail.suffix(5) { out += "\r\n" + tty.paragraph(line).joined(separator: "\r\n") }
        Term.write(out + "\r\n")
    case .finished:
        liveFinished = true
    }
}

paint()

while !app.quit {
    let r = Term.wait(timeoutMs: app.timeoutMs ?? -1)
    if r.closed { break }
    var dirty = false
    if r.timedOut {
        app.tick()
        dirty = true
    }
    for k in r.keys {
        app.key(k)
        dirty = true
    }
    if r.woke {
        for m in Wake.drain() {
            if case .job(let event) = m, app.stage == .install { handleJob(event) }
            app.handle(m)
        }
        dirty = true
    }
    if app.stage == .install, live == nil { startLive() }
    if app.stage != .install, live != nil {
        live = nil
        liveFinished = false
        dirty = true
    }
    let now = Term.size()
    if now.w != size.w || now.h != size.h {
        size = now
        dirty = true
    }
    // While the install runs, `Progress` writes its own lines; the frame would erase them.
    if dirty, app.stage != .install { paint() }
}
Term.stop()
