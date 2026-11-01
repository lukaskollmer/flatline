import FlatlineCore
import Foundation
import Testing

/// Package traits as an example of build variants: code compiled only with
/// some traits must be analyzed with each of them.
@Suite(.serialized)
struct BuildVariantTests {
    @Test func aSingleBuildMissesCodeBehindOtherTraits() throws {
        let findings = try Fixtures.packageTraitsDefault.get().findings()
        // Only used behind the Fancy trait, so the default build can't see the uses.
        #expect(Set(findings.map(\.name)) == ["fancyGreeting()", "decorate(_:)", "unusedInEveryVariant()"])
    }

    @Test func variantsAreAnalyzedTogether() throws {
        let fixture = try Fixtures.packageTraitsVariants.get()
        #expect(fixture.project.indexStores.count == 2)
        let root = fixture.project.root
        let findings = try fixture.findings()
        let (missing, unexpected) = Expectation.compare(findings, with: Expectation.parse(in: root), root: root)
        #expect(missing.isEmpty, "Expected but not reported:\n\(missing.map(\.description).joined(separator: "\n"))")
        #expect(unexpected.isEmpty, "Reported but not expected:\n\(unexpected.joined(separator: "\n"))")
    }

    @Test func variantsBuildIntoSeparateDirectories() throws {
        let stores = try Fixtures.packageTraitsVariants.get().project.indexStores.flatMap { $0 }
        #expect(stores.contains { $0.contains("/flatline-variants/1-default/") })
        #expect(stores.contains { $0.contains("/flatline-variants/2-traits-Fancy/") })
    }

    @Test(arguments: [
        ("--traits Fancy", ["--traits", "Fancy"]),
        ("-destination 'generic/platform=iOS Simulator'", ["-destination", "generic/platform=iOS Simulator"]),
        (#"  -c   release "--traits=A,B"  "#, ["-c", "release", "--traits=A,B"]),
        ("", []),
    ])
    func splitsCommandLines(commandLine: String, arguments: [String]) {
        #expect(BuildVariant(commandLine: commandLine).buildArguments == arguments)
    }

    @Test func namesDirectoriesAfterTheVariant() {
        #expect(BuildVariant(name: "watchOS", buildArguments: []).directoryName(index: 1) == "2-watchOS")
        #expect(BuildVariant(commandLine: "-destination 'generic/platform=iOS'").directoryName(index: 0)
            == "1-destination-generic-platform-iOS")
        #expect(BuildVariant(buildArguments: []).directoryName(index: 2) == "3")
    }
}
