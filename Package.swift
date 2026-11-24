// swift-tools-version:5.9
import Foundation
import PackageDescription
// The extension packages linked into riskell. Two records: extensions.lock.json is what ships (committed, written only by `risk ext add
// --ship|remove --ship`), and extensions.local.json is what this checkout installed for itself (git-ignored, written by `risk ext add`), with
// the module it generates in Local/. SwiftPM caches a manifest by its own text, so a build that reads the local record passes
// `--manifest-cache none`; `scripts/risk` does. The matching `import`s are in Sources/riskell/Generated/InstalledPackages.swift and in
// Local/Sources/RiskellLocal/.
struct Locked: Codable { var module: String; var product: String; var package: String; var path: String?; var url: String?; var revision: String? }
// BEGIN generated
let locked: [Locked] = [
    Locked(module: "ClockExt", product: "ClockExt", package: "clock", path: "Packages/clock", url: nil, revision: nil),
    Locked(module: "WeatherExt", product: "WeatherExt", package: "weather", path: "Packages/weather", url: nil, revision: nil),
    Locked(module: "UsageExt", product: "UsageExt", package: "usage", path: "Packages/usage", url: nil, revision: nil),
    Locked(module: "SystemExt", product: "SystemExt", package: "system", path: "Packages/system", url: nil, revision: nil),
    Locked(module: "NetworkExt", product: "NetworkExt", package: "network", path: "Packages/network", url: nil, revision: nil),
    Locked(module: "VolumeExt", product: "VolumeExt", package: "volume", path: "Packages/volume", url: nil, revision: nil),
    Locked(module: "WindowsExt", product: "WindowsExt", package: "windows", path: "Packages/windows", url: nil, revision: nil)
]
// END generated

/// The local record beside this manifest: the same entries as the lock, or none when the file is absent (a clean clone, or a checkout with no
/// local package). A malformed one stops the build with what is wrong with it instead of a decoder's complaint about a key.
func localLocked() -> [Locked] {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("extensions.local.json").path
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    do { return try JSONDecoder().decode([Locked].self, from: data) }
    catch { fatalError("extensions.local.json is not a list of packages: \(error). Fix: delete it; `risk ext sync` writes it again.") }
}
let local = localLocked()

let package = Package(
    name: "riskell",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "riskell", targets: ["riskell"]),
        // validate, scaffold and install extensions (docs/EXTENSION-KIT.md)
        .executable(name: "riskell-ext", targets: ["riskell-ext"]),
        // the guided installer: its own small target, Foundation only, no dependency on riskell (see docs/INSTALL.md)
        .executable(name: "riskell-setup", targets: ["riskell-setup"]),
        // loaded by /usr/bin/perl, not linked: see Services/NowPlaying.swift
        .library(name: "nowplaying", type: .dynamic, targets: ["nowplaying"]),
    ],
    dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "0.7.0")] + (locked + local).map { l in
        if let p = l.path { return .package(path: p) }
        return .package(url: l.url ?? "", revision: l.revision ?? "main")
    },
    targets: [
        .executableTarget(name: "riskell",
                          dependencies: [.product(name: "RiskellKit", package: "riskell-kit"), .target(name: "RiskellTTY"), .target(name: "RiskellWM")]
                              + locked.map { .product(name: $0.product, package: $0.package) }
                              + (local.isEmpty ? [] : [.target(name: "RiskellLocal")]),
                          path: "Sources/riskell"),
        .executableTarget(name: "riskell-ext", dependencies: [.target(name: "RiskellTTY")], path: "Sources/riskell-ext"),
        .executableTarget(name: "riskell-setup", dependencies: [.target(name: "RiskellTTY")], path: "Sources/riskell-setup"),
        .target(name: "nowplaying", path: "Sources/nowplaying"),
        // the terminal vocabulary the command line prints with: colours, mode detection, aligned rows (Foundation only)
        // the terminal vocabulary the command line prints with: colours, mode detection, aligned rows (Foundation only)
        .target(name: "RiskellTTY", path: "Sources/RiskellTTY"),
        // the window managers' wire formats and the decisions read from them, without a window: no process, no socket, no screen, so a
        // payload recorded from a real install can be replayed on CI. The kit is here for the plain value types a hook is handed.
        .target(name: "RiskellWM", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")], path: "Sources/RiskellWM"),
        // the fixtures are read by path (#filePath), not copied into a bundle, so they stay out of the target's sources
        .testTarget(name: "RiskellWMTests", dependencies: ["RiskellWM", .product(name: "RiskellKit", package: "riskell-kit")],
                    path: "Tests/RiskellWMTests", exclude: ["fixtures"]),
    ] + (local.isEmpty ? [] : [
        // the packages this checkout installed for itself, generated by `risk ext sync` into the git-ignored Local/: the app depends on the
        // module only when it is there, so nothing a local install writes is a tracked file
        .target(name: "RiskellLocal",
                dependencies: [.product(name: "RiskellKit", package: "riskell-kit")] + local.map { .product(name: $0.product, package: $0.package) },
                path: "Local/Sources/RiskellLocal"),
    ])
)
