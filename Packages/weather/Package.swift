// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "weather",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WeatherExt", targets: ["WeatherExt"])],
    dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "0.3.0")],
    targets: [.target(name: "WeatherExt", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")])]
)
