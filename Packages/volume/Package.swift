// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "volume",
    platforms: [.macOS(.v14)],
    products: [.library(name: "VolumeExt", targets: ["VolumeExt"])],
    dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "0.6.0")],
    targets: [.target(name: "VolumeExt", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")])]
)
