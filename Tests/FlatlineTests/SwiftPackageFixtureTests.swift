import FlatlineCore
import Foundation
import Testing

/// End-to-end tests: build the fixture package, analyze it, and compare with
/// the `// expect:` markers in its sources.
@Suite(.serialized)
struct SwiftPackageFixtureTests {
    let fixture: BuiltFixture

    init() throws {
        fixture = try Fixtures.swiftPackage.get()
    }

    private var root: String { fixture.project.root }

    private var skippedDirectories: [String] {
        #if os(macOS)
        []
        #else
        ["Sources/AppleOnly"]
        #endif
    }

    @Test func reportsExactlyTheExpectedResults() throws {
        let findings = try fixture.findings()
        let expectations = Expectation.parse(in: root, skipping: skippedDirectories)
        let (missing, unexpected) = Expectation.compare(findings, with: expectations, root: root)
        #expect(missing.isEmpty, "Expected but not reported:\n\(missing.map(\.description).joined(separator: "\n"))")
        #expect(unexpected.isEmpty, "Reported but not expected:\n\(unexpected.joined(separator: "\n"))")
    }

    @Test func detectsTestModules() {
        #expect(fixture.project.testModules == ["CoreTests"])
    }

    @Test func excludingTestsReportsCodeOnlyUsedByTests() throws {
        let findings = try fixture.findings { $0.excludeTests = true }
        #expect(findings.named("onlyUsedByTests()").map(\.kind) == [.unused])
        #expect(findings.filter { Paths.relative($0.location.file, to: root).hasPrefix("Tests/") }.isEmpty)
    }

    @Test func retainPublicKeepsPublicDeclarations() throws {
        let findings = try fixture.findings { $0.retainPublic = true }
        #expect(findings.named("unusedPublicFunction()").isEmpty)
        #expect(findings.filter { $0.kind == .redundantPublicAccessibility }.isEmpty)
        // Internal declarations are still reported.
        #expect(!findings.named("unusedMethod()").isEmpty)
    }

    @Test func analysesCanBeDisabled() throws {
        let findings = try fixture.findings {
            $0.retainAssignOnlyProperties = true
            $0.disableUnusedParameterAnalysis = true
            $0.disableRedundantPublicAnalysis = true
        }
        let kinds = Set(findings.map(\.kind))
        #expect(kinds.isDisjoint(with: [.assignOnlyProperty, .unusedParameter, .redundantPublicAccessibility]))
        #expect(kinds.contains(.unused))
    }

    @Test func targetsLimitReportedModules() throws {
        let findings = try fixture.findings { $0.targets = ["App"] }
        #expect(Set(findings.flatMap(\.modules)) == ["App"])
        #expect(Set(findings.map(\.name)) == ["unusedTopLevel", "unusedInMain()"])
    }

    @Test func excludedTargetsAreNotAnalyzed() throws {
        let findings = try fixture.findings { $0.excludeTargets = ["App", "CoreTests"] }
        #expect(findings.filter { $0.modules.contains("App") }.isEmpty)
        // Without App and the tests, nothing uses Core's public API.
        #expect(!findings.named("Greeter").isEmpty)
    }

    @Test func reportExcludeAndIncludeFilterFiles() throws {
        let excluded = try fixture.findings { $0.reportExclude = ["Sources/Core/**"] }
        #expect(excluded.filter { $0.location.file.contains("/Sources/Core/") }.isEmpty)
        #expect(!excluded.isEmpty)

        let included = try fixture.findings { $0.reportInclude = ["**/Enums.swift"] }
        #expect(Set(included.map(\.name)) == ["unusedCase", "two"])
    }

    @Test func retainFilesTreatsDeclarationsAsUsed() throws {
        let findings = try fixture.findings { $0.retainFiles = ["Sources/Core/Basics.swift"] }
        #expect(findings.in("Basics.swift").isEmpty)
    }

    @Test func decodablePropertiesCanBeRetained() throws {
        let findings = try fixture.findings { $0.retainCodableProperties = true }
        #expect(findings.named("ignoredField").isEmpty)
    }

    @Test func encodablePropertiesAreReportedWhenNotRetained() throws {
        let findings = try fixture.findings { $0.retainEncodableProperties = false }
        #expect(findings.named("theme").map(\.kind) == [.assignOnlyProperty])
    }

    @Test func assignOnlyPropertyTypesCanBeRetained() throws {
        let findings = try fixture.findings { $0.retainAssignOnlyPropertyTypes = ["Int"] }
        // `notEncoded: Int` is declared with a type annotation; `lastUpdated = 0` is inferred.
        #expect(findings.named("notEncoded").isEmpty)
        #expect(findings.named("lastUpdated").map(\.kind) == [.assignOnlyProperty])
    }

    @Test func explainsRetention() throws {
        let result = try fixture.analyze(explain: ["Square", "NeverConstructed", "testGreeter"])
        let text = result.explanations.joined(separator: "\n")
        #expect(text.contains("Struct 'Square'"))
        #expect(text.contains("is used by function 'internalRun()'"))
        #expect(text.contains("Struct 'NeverConstructed'"))
        #expect(text.contains("is unused"))
        #expect(text.contains("is used because it is a test"))
    }

    @Test func baselineSuppressesKnownResults() throws {
        let findings = try fixture.findings()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("flatline-baseline-\(UUID()).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Baseline(findings: Array(findings.dropFirst())).write(to: path)
        let remaining = try Baseline.load(from: path).filter(findings)
        #expect(remaining == [findings[0]])
    }

    #if os(macOS)
    @Test func previewsCanBeIgnored() throws {
        let findings = try fixture.findings { $0.retainSwiftUIPreviews = false }
        let names = Set(findings.in("AppleOnly.swift").map(\.name))
        #expect(names.isSuperset(of: ["ContentView", "LegacyPreview", "PreviewedView", "Model"]))
    }

    @Test func objcAccessibleDeclarationsCanBeRetained() throws {
        let findings = try fixture.findings { $0.retainObjcAccessible = true }
        #expect(findings.named("PlainObject").isEmpty)
        #expect(!findings.named("swiftOnly()").isEmpty)
    }

    @Test func objcAnnotatedDeclarationsCanBeReported() throws {
        let findings = try fixture.findings { $0.retainObjcAnnotated = false }
        #expect(!findings.named("ObjCTarget").isEmpty)
    }
    #endif
}
