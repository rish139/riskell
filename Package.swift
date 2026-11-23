// swift-tools-version:5.9
import PackageDescription
// The extension packages linked into riskell. extensions.lock.json is the record (committed, edited by `risk ext add|remove`); the block
// below is generated from it by `risk ext sync`, because SwiftPM caches a manifest by its own text and would not see a changed lock file.
// The matching `import`s are in Sources/riskell/Generated/InstalledPackages.swift.
struct Locked { var module: String; var product: String; var package: String; var path: String?; var url: String?; var revision: String? }
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
    dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "0.7.0")] + locked.map { l in
        if let p = l.path { return .package(path: p) }
        return .package(url: l.url ?? "", revision: l.revision ?? "main")
    },
    targets: [
        .executableTarget(name: "riskell",
                          dependencies: [.product(name: "RiskellKit", package: "riskell-kit"), .target(name: "RiskellTTY"), .target(name: "RiskellWM")]
                              + locked.map { .product(name: $0.product, package: $0.package) },
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
    ]
)
