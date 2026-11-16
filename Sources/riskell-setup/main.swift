import Foundation

// riskell-setup: the guided installer for riskell. One binary, several modes (see Cli.swift and docs/INSTALL.md).

setvbuf(stdout, nil, _IOLBF, 0)
Ink.mode = Ink.detectMode(env: ProcessInfo.processInfo.environment)

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let paths = Paths.fromEnvironment()
let repo = Detect.findRepo(flag: options.repo)

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("riskell-setup: \(message)\n".utf8))
    exit(code)
}

if !options.errors.isEmpty {
    fail(options.errors.joined(separator: "; ") + "\n" + "run riskell-setup --help")
}

switch options.mode {
case .help:
    print(Options.usage)
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
    let g = Snapshots.render(name, w: options.width, h: options.height)
    Term.write(options.ansi ? g.ansi() : g.plainText())
    exit(0)
case .snapshotDir:
    do {
        try Snapshots.writeAll(to: options.snapshotDirPath ?? "docs/installer-snapshots")
    } catch {
        fail("could not write the snapshots: \(error)", code: 1)
    }
    print("wrote \(Snapshots.names.count) screens at \(Snapshots.sizes.count) sizes")
    exit(0)
case .check:
    exit(Modes.check(paths: paths, label: "com.rish.riskell"))
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
    print(Modes.dryRun(app))
    print("riskell-setup needs a terminal for the guided flow; run it with --yes to install without questions.")
    exit(0)
}

let app = App(facts: Detect.gather(paths, label: "com.rish.riskell"), paths: paths, repo: repo)
app.noBuild = options.noBuild
app.noLaunch = options.noLaunch
app.dryRun = options.dryRun
Term.start()
let renderer = Renderer()
var size = Term.size()
Term.write(renderer.frame(app.render(w: size.w, h: size.h)))

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
        for m in Wake.drain() { app.handle(m) }
        dirty = true
    }
    let now = Term.size()
    if now.w != size.w || now.h != size.h {
        size = now
        renderer.invalidate()
        dirty = true
    }
    if dirty {
        Term.write(renderer.frame(app.render(w: size.w, h: size.h)))
    }
}
Term.stop()
