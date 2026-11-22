// swift-tools-version: 6.1

import PackageDescription

// Fixture for build variants. Code behind the Fancy trait is only compiled
// when it's enabled; the `// expect:` markers are for analyzing the default
// traits and Fancy together.
let package = Package(
    name: "PackageTraits",
    traits: [
        .default(enabledTraits: ["Basic"]),
        .trait(name: "Basic"),
        .trait(name: "Fancy"),
    ],
    targets: [
        .target(name: "Helpers"),
        // Tool/Value.swift is a symlink to Values/Value.swift.
        .target(name: "Values", swiftSettings: [.define("VALUES")]),
        .executableTarget(name: "Tool", dependencies: ["Helpers", "Values"]),
    ]
)
