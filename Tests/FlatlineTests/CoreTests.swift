import FlatlineCore
import FlatlineProject
import Foundation
import Testing

struct GlobTests {
    @Test(arguments: [
        ("Sources/*.swift", "Sources/A.swift", true),
        ("Sources/*.swift", "Sources/Sub/A.swift", false),
        ("Sources/**/*.swift", "Sources/A.swift", true),
        ("Sources/**/*.swift", "Sources/Sub/Deep/A.swift", true),
        ("**/Generated/**", "Sources/Generated/A.swift", true),
        ("**/Generated/**", "Sources/NotGenerated/A.swift", false),
        ("File?.swift", "File1.swift", true),
        ("File?.swift", "File12.swift", false),
        ("a.b+c.swift", "a.b+c.swift", true),
        ("a.b+c.swift", "aXb+c.swift", false),
    ])
    func matches(pattern: String, path: String, expected: Bool) throws {
        #expect(try Glob(pattern).matches(path) == expected)
    }

    @Test func matchesRelativeToRoot() throws {
        let globs = [try Glob("Sources/**")]
        #expect(Glob.any(globs, match: "/project/Sources/A.swift", relativeTo: "/project"))
        #expect(!Glob.any(globs, match: "/other/Sources/A.swift", relativeTo: "/project"))
    }
}

struct OutputTests {
    private let findings = [
        Finding(
            kind: .unused,
            declarationKind: .class,
            name: "Foo",
            location: SourceLocation(file: "/project/Sources/A.swift", line: 3, column: 7),
            modules: ["App"],
            usrs: ["s:3App3FooC"]
        ),
        Finding(
            kind: .unusedParameter,
            declarationKind: .function,
            name: "value",
            location: SourceLocation(file: "/project/Sources/B, \"C\".swift", line: 10, column: 12),
            modules: ["App"],
            usrs: ["s:3App3baryySiF"]
        ),
    ]

    private let context = OutputContext(projectRoot: "/project", relativePaths: false)

    @Test func xcode() throws {
        let output = try OutputFormat.xcode.formatter().format(findings, context: context)
        #expect(output.split(separator: "\n").first == "/project/Sources/A.swift:3:7: warning: Class 'Foo' is unused")
        let relative = try OutputFormat.xcode.formatter().format(findings, context: .init(projectRoot: "/project", relativePaths: true))
        #expect(relative.hasPrefix("Sources/A.swift:3:7:"))
    }

    @Test func json() throws {
        let output = try OutputFormat.json.formatter().format(findings, context: context)
        let entries = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        #expect(entries.count == 2)
        #expect(entries[0]["kind"] as? String == "unused")
        #expect(entries[0]["declaration_kind"] as? String == "class")
        #expect(entries[1]["message"] as? String == "Parameter 'value' is unused")
    }

    @Test func csvEscapesFields() throws {
        let lines = try OutputFormat.csv.formatter().format(findings, context: context).split(separator: "\n")
        #expect(lines[0] == "kind,declaration_kind,name,modules,file,line,column,message")
        #expect(lines[2].contains(#""/project/Sources/B, ""C"".swift""#))
    }

    @Test func checkstyleEscapesXML() throws {
        let output = try OutputFormat.checkstyle.formatter().format(findings, context: context)
        #expect(output.contains(#"<file name="/project/Sources/A.swift">"#))
        #expect(output.contains("Class &apos;Foo&apos; is unused"))
        #expect(output.contains("&quot;C&quot;"))
    }

    @Test func githubActionsUsesRelativePaths() throws {
        let output = try OutputFormat.githubActions.formatter().format(findings, context: context)
        #expect(output.split(separator: "\n").first
            == "::warning file=Sources/A.swift,line=3,col=7,title=flatline%3A unused::Class 'Foo' is unused")
    }

    @Test func codeClimateFingerprintsAreStable() throws {
        let first = try OutputFormat.codeclimate.formatter().format(findings, context: context)
        let moved = findings.map {
            Finding(
                kind: $0.kind,
                declarationKind: $0.declarationKind,
                name: $0.name,
                location: SourceLocation(file: $0.location.file, line: $0.location.line + 5, column: 1),
                modules: $0.modules,
                usrs: $0.usrs
            )
        }
        let second = try OutputFormat.codeclimate.formatter().format(moved, context: context)
        let fingerprints = { (text: String) throws -> [String] in
            let issues = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
            return issues.compactMap { $0["fingerprint"] as? String }
        }
        #expect(try fingerprints(first) == fingerprints(second))
    }

    @Test func baselineIgnoresLocations() {
        let baseline = Baseline(findings: findings)
        let moved = Finding(
            kind: .unused,
            declarationKind: .class,
            name: "Foo",
            location: SourceLocation(file: "/project/Sources/Moved.swift", line: 99, column: 1),
            modules: ["App"],
            usrs: ["s:3App3FooC"]
        )
        #expect(baseline.filter([moved]).isEmpty)
    }
}

struct ConfigurationTests {
    private func load(_ yaml: String) throws -> Configuration {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flatline-config-\(UUID())").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try yaml.write(toFile: directory + "/.flatline.yml", atomically: true, encoding: .utf8)
        return try ConfigurationLoader.load(path: nil, directory: directory, logger: Logger(level: .quiet)).0
    }

    @Test func defaults() throws {
        let configuration = try load("")
        #expect(configuration == Configuration())
        #expect(configuration.retainObjcAnnotated)
        #expect(configuration.retainEncodableProperties)
        #expect(!configuration.retainPublic)
        #expect(configuration.format == .xcode)
    }

    @Test func readsPeripheryStyleKeys() throws {
        let configuration = try load("""
        workspace: App.xcworkspace
        schemes:
          - App
          - Widget
        retain_public: true
        retain_objc_annotated: false
        report_exclude: "**/Generated/**"
        build_arguments: [-destination, "generic/platform=iOS Simulator"]
        format: github-actions
        disable_update_check: true
        """)
        #expect(configuration.project == "App.xcworkspace")
        #expect(configuration.schemes == ["App", "Widget"])
        #expect(configuration.retainPublic)
        #expect(!configuration.retainObjcAnnotated)
        #expect(configuration.reportExclude == ["**/Generated/**"])
        #expect(configuration.buildArguments == ["-destination", "generic/platform=iOS Simulator"])
        #expect(configuration.format == .githubActions)
    }

    @Test func rejectsInvalidValues() {
        #expect(throws: FlatlineError.self) {
            try load("format: html")
        }
    }

    @Test func roundTripsThroughCoding() throws {
        var configuration = Configuration()
        configuration.project = "App.xcodeproj"
        configuration.retainFiles = ["Generated/**"]
        configuration.format = .json
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(Configuration.self, from: data) == configuration)
    }
}

struct ProjectDetectionTests {
    private func directory(with entries: [String]) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flatline-detect-\(UUID())").path
        for entry in entries {
            let path = directory + "/" + entry
            if entry.hasSuffix(".swift") {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path, contents: Data())
            } else {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
        }
        return directory
    }

    @Test func prefersWorkspaces() throws {
        let directory = try directory(with: ["App.xcodeproj", "App.xcworkspace", "Package.swift"])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(try ProjectDetector.detect(configuration: Configuration(), directory: directory)
            == .xcodeWorkspace(directory + "/App.xcworkspace"))
    }

    @Test func fallsBackToPackages() throws {
        let directory = try directory(with: ["Package.swift"])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(try ProjectDetector.detect(configuration: Configuration(), directory: directory)
            == .swiftPackage(directory: directory))
    }

    @Test func rejectsAmbiguousProjects() throws {
        let directory = try directory(with: ["A.xcodeproj", "B.xcodeproj"])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(throws: FlatlineError.self) {
            try ProjectDetector.detect(configuration: Configuration(), directory: directory)
        }
    }

    @Test func usesPrebuiltIndexStores() throws {
        var configuration = Configuration()
        configuration.skipBuild = true
        configuration.indexStorePath = ["/store"]
        #expect(try ProjectDetector.detect(configuration: configuration, directory: "/project") == .indexStore(root: "/project"))
    }
}
