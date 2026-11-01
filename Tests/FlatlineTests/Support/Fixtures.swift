import FlatlineCore
import FlatlineProject
import FlatlineSwift
import Foundation
import IndexStore

/// A fixture project, built once per test run.
final class BuiltFixture: @unchecked Sendable {
    let project: PreparedProject
    let variants: [[IndexStore]]

    init(project: PreparedProject) throws {
        self.project = project
        let library = try IndexStoreLibrary(path: Toolchain.indexStoreLibrary(explicit: nil))
        variants = try project.indexStores.map { paths in
            try paths.map { try IndexStore(path: $0, library: library) }
        }
    }

    func analyze(
        explain: [String] = [],
        _ configure: (inout Configuration) -> Void = { _ in }
    ) throws -> AnalysisResult {
        var configuration = Configuration()
        configure(&configuration)
        var analyzer = SwiftAnalyzer(configuration: configuration, projectRoot: project.root, logger: Logger(level: .quiet))
        analyzer.testModules = project.testModules
        analyzer.explain = explain
        return try analyzer.analyze(variants: variants)
    }

    func findings(_ configure: (inout Configuration) -> Void = { _ in }) throws -> [Finding] {
        try analyze(configure).findings
    }
}

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func path(_ name: String) -> String {
        Paths.canonical(directory.appendingPathComponent(name).path)
    }

    /// Builds outside the source tree, so builds for different platforms don't mix.
    static func buildDirectory(_ name: String) -> String {
        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "linux"
        #endif
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("flatline-tests/\(name)-\(platform)")
            .path
    }

    static let swiftPackage: Result<BuiltFixture, FlatlineError> = build {
        var configuration = Configuration()
        configuration.buildArguments = ["--scratch-path", buildDirectory("SwiftPackage")]
        let driver = SwiftPackageDriver(directory: path("SwiftPackage"))
        return try driver.prepare(configuration: configuration, logger: Logger(level: .quiet))
    }

    /// The traits fixture built with its default traits only.
    static let packageTraitsDefault: Result<BuiltFixture, FlatlineError> = build {
        var configuration = Configuration()
        configuration.buildArguments = ["--scratch-path", buildDirectory("PackageTraits")]
        let driver = SwiftPackageDriver(directory: path("PackageTraits"))
        return try driver.prepare(configuration: configuration, logger: Logger(level: .quiet))
    }

    /// The traits fixture built twice, with the default traits and with Fancy.
    static let packageTraitsVariants: Result<BuiltFixture, FlatlineError> = build {
        var configuration = Configuration()
        configuration.buildArguments = ["--scratch-path", buildDirectory("PackageTraits")]
        configuration.buildVariants = [
            BuildVariant(name: "default", buildArguments: []),
            BuildVariant(commandLine: "--traits Fancy"),
        ]
        let driver = SwiftPackageDriver(directory: path("PackageTraits"))
        return try driver.prepare(configuration: configuration, logger: Logger(level: .quiet))
    }

    #if os(macOS)
    static let xcodeProject: Result<BuiltFixture, FlatlineError> = build {
        var configuration = Configuration()
        configuration.schemes = ["App"]
        configuration.derivedDataPath = buildDirectory("XcodeProject")
        let directory = path("XcodeProject")
        let driver = XcodeDriver(path: directory + "/FixtureApp.xcodeproj", kind: .project, root: directory)
        return try driver.prepare(configuration: configuration, logger: Logger(level: .quiet))
    }
    #endif

    private static func build(_ prepare: () throws -> PreparedProject) -> Result<BuiltFixture, FlatlineError> {
        Result {
            try BuiltFixture(project: prepare())
        }.mapError { FlatlineError("\($0)") }
    }
}

/// An expected result, written in fixture sources as `// expect: kind` or
/// `// expect: kind(name)` on the line where flatline should report it.
struct Expectation: Hashable, CustomStringConvertible {
    let file: String
    let line: Int
    let kind: Finding.Kind
    let name: String?

    var description: String {
        "\(file):\(line) \(kind.rawValue)" + (name.map { "(\($0))" } ?? "")
    }

    static func parse(in root: String, skipping skipped: [String] = []) -> [Expectation] {
        var expectations: [Expectation] = []
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let relative = enumerator?.nextObject() as? String {
            if relative.hasPrefix(".build") || skipped.contains(where: { relative.hasPrefix($0) }) {
                continue
            }
            guard relative.hasSuffix(".swift"), relative != "Package.swift",
                  let text = try? String(contentsOfFile: root + "/" + relative, encoding: .utf8)
            else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard let marker = line.range(of: "// expect: ") else { continue }
                for item in line[marker.upperBound...].split(separator: ",") {
                    let item = item.trimmingCharacters(in: .whitespaces)
                    let kindName = item.prefix { $0 != "(" }
                    guard let kind = Finding.Kind(rawValue: String(kindName)) else {
                        fatalError("unknown expectation '\(item)' in \(relative):\(index + 1)")
                    }
                    let name = item.contains("(") ? String(item.dropFirst(kindName.count + 1).dropLast()) : nil
                    expectations.append(Expectation(file: relative, line: index + 1, kind: kind, name: name))
                }
            }
        }
        return expectations
    }

    /// Pairs findings with expectations; returns what's left on either side.
    static func compare(
        _ findings: [Finding],
        with expectations: [Expectation],
        root: String
    ) -> (missing: [Expectation], unexpected: [String]) {
        var remaining = findings
        var missing: [Expectation] = []
        for expectation in expectations {
            let index = remaining.firstIndex { finding in
                Paths.relative(finding.location.file, to: root) == expectation.file
                    && finding.location.line == expectation.line
                    && finding.kind == expectation.kind
                    && (expectation.name == nil || expectation.name == finding.name)
            }
            if let index {
                remaining.remove(at: index)
            } else {
                missing.append(expectation)
            }
        }
        let unexpected = remaining.map {
            "\(Paths.relative($0.location.file, to: root)):\($0.location.line) \($0.kind.rawValue)(\($0.name))"
        }
        return (missing, unexpected)
    }
}

extension [Finding] {
    func named(_ name: String) -> [Finding] {
        filter { $0.name == name }
    }

    func `in`(_ file: String) -> [Finding] {
        filter { $0.location.file.hasSuffix("/" + file) }
    }
}
