#if os(macOS)
import FlatlineCore
import FlatlineProject
import Foundation
import Testing

@Suite(.serialized)
struct XcodeFixtureTests {
    @Test func reportsExactlyTheExpectedResults() throws {
        let fixture = try Fixtures.xcodeProject.get()
        let root = fixture.project.root
        let findings = try fixture.findings()
        let (missing, unexpected) = Expectation.compare(findings, with: Expectation.parse(in: root), root: root)
        #expect(missing.isEmpty, "Expected but not reported:\n\(missing.map(\.description).joined(separator: "\n"))")
        #expect(unexpected.isEmpty, "Reported but not expected:\n\(unexpected.joined(separator: "\n"))")
    }

    @Test func classesReferencedFromResourcesAreRetained() throws {
        let findings = try Fixtures.xcodeProject.get().findings()
        #expect(findings.named("CustomApplication").isEmpty)
        #expect(findings.named("XibView").isEmpty)
    }

    @Test func rejectsUnknownSchemesBeforeBuilding() throws {
        let directory = Fixtures.path("XcodeProject")
        let driver = XcodeDriver(path: directory + "/FixtureApp.xcodeproj", kind: .project, root: directory)
        var configuration = Configuration()
        configuration.schemes = ["App", "AppTests", "Missing"]
        let derivedData = Fixtures.buildDirectory("XcodeProject-unknown-schemes")
        configuration.derivedDataPath = derivedData

        let error = try #require(throws: FlatlineError.self) {
            try driver.prepare(configuration: configuration, logger: Logger(level: .quiet))
        }
        #expect(error.description.contains("'AppTests' is a target, not a scheme"))
        #expect(error.description.contains("there is no scheme named 'Missing'"))
        #expect(error.description.contains("Available schemes: App"))
        // Nothing was built, not even the valid scheme.
        #expect(!FileManager.default.fileExists(atPath: derivedData))
    }

    @Test func codeOnlyUsedByTestsIsReportedWhenTestsAreExcluded() throws {
        let findings = try Fixtures.xcodeProject.get().findings { $0.excludeTests = true }
        #expect(findings.named("onlyUsedByTests()").map(\.kind) == [.unused])
    }
}
#endif
