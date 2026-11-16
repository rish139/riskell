// swift-tools-version:5.9
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari
import PackageDescription

let package = Package(
    name: "load-ext",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LoadExt", targets: ["LoadExt"])],
    // an extension depends on the kit alone
    dependencies: [.package(url: "https://github.com/rish139/riskell-kit", from: "0.1.0")],
    targets: [.target(name: "LoadExt", dependencies: [.product(name: "RiskellKit", package: "riskell-kit")])]
)
