// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "flatline",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "flatline", targets: ["flatline"]),
        .library(name: "FlatlineCore", targets: ["FlatlineCore"]),
        .library(name: "FlatlineSwift", targets: ["FlatlineSwift"]),
        .library(name: "FlatlineProject", targets: ["FlatlineProject"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "603.0.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.0.0"),
    ],
    targets: [
        // Function table for libIndexStore, loaded at runtime with dlopen.
        .target(
            name: "CIndexStore",
            linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]
        ),
        // Swift wrapper around the index store C API.
        .target(
            name: "IndexStore",
            dependencies: ["CIndexStore"]
        ),
        // Language-agnostic declaration graph, reachability and reporting.
        .target(
            name: "FlatlineCore"
        ),
        // Swift frontend: builds the graph from the index store and SwiftSyntax.
        .target(
            name: "FlatlineSwift",
            dependencies: [
                "FlatlineCore",
                "IndexStore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        // Project drivers: SwiftPM, Xcode, and prebuilt index stores.
        .target(
            name: "FlatlineProject",
            dependencies: ["FlatlineCore"]
        ),
        .executableTarget(
            name: "flatline",
            dependencies: [
                "FlatlineCore",
                "FlatlineSwift",
                "FlatlineProject",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "FlatlineTests",
            dependencies: ["FlatlineCore", "FlatlineSwift", "FlatlineProject", "IndexStore"]
        ),
    ]
)
