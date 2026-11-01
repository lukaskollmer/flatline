import FlatlineCore
import Testing

struct SourceGraphTests {
    private let graph = SourceGraph()

    private func add(_ name: String, kind: DeclarationKind = .function) -> Declaration.ID {
        graph.addDeclaration(
            kind: kind,
            name: name,
            usr: "usr:\(name)",
            location: SourceLocation(file: "/f.swift", line: 1, column: 1),
            module: "M"
        )
    }

    @Test func followsReferencesFromRoots() {
        let root = add("root")
        let used = add("used")
        let unused = add("unused")
        graph.addReference(from: root, to: used)
        graph.addReference(from: unused, to: used)
        graph.retain(root, reason: "entry point")
        graph.computeReachability()

        #expect(graph.isReachable(root))
        #expect(graph.isReachable(used))
        #expect(!graph.isReachable(unused))
        #expect(graph.retentionReason(for: used) == .referenced(by: root))
    }

    @Test func usedMembersKeepTheirParent() {
        let type = add("Type", kind: .struct)
        let member = add("member")
        let other = add("other")
        graph.setParent(type, of: member)
        graph.setParent(type, of: other)
        graph.addTopLevelReference(to: member)
        graph.computeReachability()

        #expect(graph.isReachable(type))
        #expect(!graph.isReachable(other))
        #expect(graph.retentionReason(for: type) == .containsUsedMember(member))
    }

    @Test func conditionalRetentionNeedsAllRequirements() {
        let requirement = add("requirement")
        let owner = add("Owner", kind: .struct)
        let witness = add("witness")
        let otherOwner = add("OtherOwner", kind: .struct)
        let otherWitness = add("otherWitness")
        graph.retain(witness, when: [requirement, owner], rule: "witness")
        graph.retain(otherWitness, when: [requirement, otherOwner], rule: "witness")
        graph.addTopLevelReference(to: requirement)
        graph.addTopLevelReference(to: owner)
        graph.computeReachability()

        #expect(graph.isReachable(witness))
        #expect(!graph.isReachable(otherWitness))
        #expect(!graph.isReachable(otherOwner))
    }

    @Test func resolvesAliases() {
        let property = add("property", kind: .instanceProperty)
        graph.addAlias("usr:getter", for: property)
        graph.addUSR("usr:property-in-other-module", module: "N", to: property)
        #expect(graph.declaration(forUSR: "usr:getter") == property)
        #expect(graph[property].modules == ["M", "N"])
        #expect(graph[property].usrs == ["usr:property", "usr:property-in-other-module"])
    }
}
