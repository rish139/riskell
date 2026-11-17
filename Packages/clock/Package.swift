// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "clock",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ClockExt", targets: ["ClockExt"])],
    dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "0.5.0")],
    targets: [.target(name: "ClockExt", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")])]
)
