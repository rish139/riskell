import Foundation
import RiskellKit

/// One riskell owns the bars, the event socket, the trackpad and the window manager's gaps. A second full instance (a double launch, a typo'd
/// flag, a test run) would take over the socket, read the trackpad twice and rewrite the gaps, so it refuses to start: it takes an exclusive
/// lock on ~/.cache/riskell/riskell.lock, held for the life of the process (the system releases it when the process dies, however it dies).
/// A restart (`risk restart` kills the old one first) waits up to 3 s for the lock.
/// Not locked: the snapshot, dump and test runs (they use their own socket and never write the window manager's gaps), and any run with its own
/// RISKELL_CONFIG or RISKELL_LAYOUT (a scratch instance), or RISKELL_NO_LOCK=1.
enum InstanceLock {
    private static var fd: Int32 = -1
    private static let scratchFlags: Set<String> = ["--snap", "--dump", "--no-reserve", "--settings", "--pop", "--edit", "--edit-test"]

    /// `riskell --lock-test hold|try <lock file>`: the same flock logic on a scratch file, without starting anything (hold: take it and keep it 8 s; try: report).
    static func selfTest(_ args: [String]) {
        guard let i = args.firstIndex(of: "--lock-test"), i + 2 < args.count else { return }
        let f = open(args[i + 2], O_CREAT | O_RDWR, 0o600)
        let got = flock(f, LOCK_EX | LOCK_NB) == 0
        if args[i + 1] == "hold" { print(got ? "hold: acquired" : "hold: FAILED"); fflush(stdout); if got { sleep(8) }; exit(got ? 0 : 1) }
        print(got ? "try: acquired (nobody holds it)" : "try: refused (held by another process)"); exit(got ? 0 : 3)
    }

    static func acquireOrExit(_ args: [String]) {
        let env = ProcessInfo.processInfo.environment
        if !scratchFlags.isDisjoint(with: args) || env["RISKELL_CONFIG"] != nil || env["RISKELL_LAYOUT"] != nil || env["RISKELL_NO_LOCK"] != nil { return }
        let dir = NSHomeDirectory() + "/.cache/riskell"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = open(dir + "/riskell.lock", O_CREAT | O_RDWR, 0o600)
        guard f >= 0 else { return }      // cannot lock: run rather than refuse
        for attempt in 0..<30 {
            if flock(f, LOCK_EX | LOCK_NB) == 0 { fd = f; return }
            if attempt < 29 { usleep(100_000) }
        }
        print("riskell: another instance is already running (use `risk restart`); this one exits"); fflush(stdout)
        exit(0)
    }
}
