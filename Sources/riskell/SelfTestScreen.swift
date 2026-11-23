// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellTTY

/// How the package self-tests (`--usage-selftest`, `--weather-selftest`) are shown: the kit's table, one row per case with PASS or FAIL
/// in it, then a result line. Exits 1 when any case failed, as the plain-text versions did.
enum SelfTestScreen {
    static func show(_ title: String, _ cases: [(name: String, ok: Bool, detail: String?)]) -> Never {
        let tty = terminal()
        let ok = cases.allSatisfy(\.ok)
        let rows = cases.map { c in [tty.statusDot(c.ok ? .ok : .crit), Cell(c.name), Cell(c.ok ? "PASS" : "FAIL"), Cell(c.detail ?? "")] }
        print(tty.table(title: "\(title)-selftest", meta: "\(rows.count) cases",
                        columns: [Column(priority: 9), Column(priority: 9), Column(priority: 5)], rows: rows).joined(separator: "\n"))
        print("")
        print(tty.check(ok ? .ok : .crit, "result", ok ? "PASS" : "FAIL", keyWidth: 7).joined(separator: "\n"))
        fflush(stdout)
        exit(ok ? 0 : 1)
    }
}
