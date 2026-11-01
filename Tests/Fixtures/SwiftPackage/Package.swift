// swift-tools-version: 5.10

import PackageDescription

// Fixture for flatline's tests. Expected results are marked in the sources
// with `// expect: <kind>` comments on the line of the declaration.

var targets: [Target] = [
    .target(name: "Core"),
    .executableTarget(name: "App", dependencies: ["Core"]),
    .testTarget(name: "CoreTests", dependencies: ["Core"]),
]

#if os(macOS)
targets.append(.target(name: "AppleOnly", dependencies: ["Core"]))
#endif

let package = Package(
    name: "Fixture",
    platforms: [.macOS(.v14)],
    targets: targets
)
