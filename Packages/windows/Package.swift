// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "windows",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WindowsExt", targets: ["WindowsExt"])],
    dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "0.6.0")],
    targets: [.target(name: "WindowsExt", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")])]
)
