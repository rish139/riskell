// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dwindle-aerospace",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DwindleAerospaceExt", targets: ["DwindleAerospaceExt"])],
    dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "0.8.0")],
    targets: [
        .target(name: "DwindleAerospaceExt", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")]),
        .testTarget(name: "DwindleAerospaceExtTests", dependencies: ["DwindleAerospaceExt"]),
    ]
)
