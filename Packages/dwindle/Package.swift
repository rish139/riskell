// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dwindle",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DwindleExt", targets: ["DwindleExt"])],
    dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "0.7.0")],
    targets: [
        .target(name: "DwindleExt", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")]),
        .testTarget(name: "DwindleExtTests", dependencies: ["DwindleExt"]),
    ]
)
