// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "network",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NetworkExt", targets: ["NetworkExt"])],
    dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "0.5.0")],
    targets: [.target(name: "NetworkExt", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")])]
)
