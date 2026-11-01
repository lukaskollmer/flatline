#if os(macOS)
import FlatlineCore
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

    @Test func codeOnlyUsedByTestsIsReportedWhenTestsAreExcluded() throws {
        let findings = try Fixtures.xcodeProject.get().findings { $0.excludeTests = true }
        #expect(findings.named("onlyUsedByTests()").map(\.kind) == [.unused])
    }
}
#endif
