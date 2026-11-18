// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation

/// The riskell checkout this tool runs from: RISKELL_ROOT when scripts/risk sets it, else the nearest parent of the working directory or
/// of the executable holding VERSION and extensions.lock.json. nil when the binary has been copied out of a checkout.
func checkout() -> String? {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["RISKELL_ROOT"], fm.fileExists(atPath: env + "/extensions.lock.json") { return env }
    var starts = [fm.currentDirectoryPath]
    if let executable = Bundle.main.executablePath {
        starts.append((executable as NSString).deletingLastPathComponent)
    }
    for start in starts {
        var dir = start
        while true {
            if fm.fileExists(atPath: dir + "/VERSION"), fm.fileExists(atPath: dir + "/extensions.lock.json") { return dir }
            if dir == "/" { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }
    return nil
}

/// The one version number, from VERSION at the root of the checkout; nil outside a checkout.
func version() -> String? {
    guard let root = checkout() else { return nil }
    return (try? String(contentsOfFile: root + "/VERSION", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
}
