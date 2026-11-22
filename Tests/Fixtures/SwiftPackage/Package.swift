// swift-tools-version: 5.10

import PackageDescription

// Fixture for flatline's tests. Expected results are marked in the sources
// with `// expect: <kind>` comments on the line of the declaration.

var targets: [Target] = [
    .target(name: "Core"),
    .executableTarget(name: "App", dependencies: ["Core"]),
    .testTarget(name: "CoreTests", dependencies: ["Core"]),
    // Unused imports: each file in Imports and ImportLeaks tests one case.
    .target(name: "Shapes"),
    .target(name: "ShapeExtras", dependencies: ["Shapes"]),
    .target(name: "ShapeKit", dependencies: ["Shapes"]),
    .executableTarget(name: "Imports", dependencies: ["Shapes", "ShapeExtras", "ShapeKit"]),
    .executableTarget(name: "ImportLeaks", dependencies: ["Shapes", "ShapeExtras"]),
]

#if os(macOS)
targets.append(.target(name: "AppleOnly", dependencies: ["Core"]))
#endif

let package = Package(
    name: "Fixture",
    platforms: [.macOS(.v14)],
    targets: targets
)
