// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "usage",
    platforms: [.macOS(.v14)],
    products: [.library(name: "UsageExt", targets: ["UsageExt"])],
    dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "0.3.0")],
    targets: [.target(name: "UsageExt", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")])]
)
