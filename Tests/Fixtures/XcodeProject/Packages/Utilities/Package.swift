// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Utilities",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Utilities", targets: ["Utilities"])],
    targets: [.target(name: "Utilities")]
)
