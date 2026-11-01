import FlatlineCore

/// Swift rules for declarations that are used without a visible reference:
/// entry points, tests, runtime and Objective-C entry points, and members
/// that synthesized code uses.
extension SwiftGraphBuilder {
    func applyRetentionRules(projectRoot: String, resourceClassNames: Set<String>, retainFiles: [Glob]) {
        for id in graph.declarations.indices {
            applyDeclarationRules(to: id, projectRoot: projectRoot, resourceClassNames: resourceClassNames, retainFiles: retainFiles)
        }
        for id in graph.declarations.indices where graph[id].kind.isType && graph[id].kind != .protocol {
            applyTypeRules(to: id)
        }
    }

    private func applyDeclarationRules(
        to id: Declaration.ID,
        projectRoot: String,
        resourceClassNames: Set<String>,
        retainFiles: [Glob]
    ) {
        let declaration = graph[id]

        if declaration.isImplicit || declaration.name.hasPrefix("$") {
            graph[id].isReportable = false
        }

        if syntaxByFile[declaration.location.file]?.ignoresAll == true {
            retainIgnored(id, reason: "the file has an ignore:all comment command")
        } else if syntax[id]?.isIgnored == true {
            retainIgnored(id, reason: "it has an ignore comment command")
        }
        if Glob.any(retainFiles, match: declaration.location.file, relativeTo: projectRoot) {
            graph.retain(id, reason: "its file matches retain_files")
        }

        let attributes = declaration.attributes
        if !attributes.isDisjoint(with: KnownSymbols.entryPointAttributes) {
            graph.retain(id, reason: "it is the program entry point")
        }
        if declaration.name == "main()", let parent = declaration.parent,
           !graph[parent].attributes.isDisjoint(with: KnownSymbols.entryPointAttributes) {
            graph.retain(id, reason: "it is the program entry point")
        }
        if attributes.contains("available(unavailable)") {
            graph.retain(id, reason: "it is marked unavailable")
            graph[id].isReportable = false
        }
        if !attributes.isDisjoint(with: KnownSymbols.exportAttributes) {
            graph.retain(id, reason: "it is exported to C or the runtime")
        }

        if configuration.retainObjcAnnotated, isObjcAnnotated(id) {
            graph.retain(id, reason: "it is exposed to Objective-C")
        }
        if configuration.retainObjcAccessible, declaration.usrs.contains(where: { $0.hasPrefix("c:") }) {
            graph.retain(id, reason: "it is accessible from Objective-C")
        }
        if configuration.retainPublic, effectiveAccessibility(of: id) >= .public {
            graph.retain(id, reason: "it is public")
        }
        // Swift Testing finds @Test functions and @Suite types through macro-generated code.
        if unitTests.contains(id) || !attributes.isDisjoint(with: ["Test", "Suite"]) {
            graph.retain(id, reason: "it is a test")
        }
        if declaration.kind == .class, resourceClassNames.contains(declaration.name) {
            graph.retain(id, reason: "it is referenced from Interface Builder or a property list")
        }

        switch declaration.kind {
        case .deinitializer:
            retainWithOwner(id, rule: "deinitializers run implicitly")
        case .typealias where isInProtocol(id):
            // Can satisfy associated types of conforming types, which the index doesn't record.
            retainWithOwner(id, rule: "typealiases in protocols can satisfy associated types")
        case .instanceMethod where declaration.name.hasPrefix("callAsFunction("):
            retainWithOwner(id, rule: "callAsFunction is called implicitly")
        default:
            break
        }
    }

    private func applyTypeRules(to type: Declaration.ID) {
        let declaration = graph[type]
        let members = members(of: type)
        let supertypes = allSupertypes(of: type, throughClasses: false)
        let usrs = Set(supertypes.map(\.usr))
        let names = Set(supertypes.map(\.name))

        // Tests and previews are run by tools, not by the program.
        let classHierarchy = allSupertypes(of: type, throughClasses: true)
        if classHierarchy.contains(where: {
            $0.usr == KnownSymbols.xcTestCase || configuration.externalTestCaseClasses.contains($0.name)
        }) {
            graph.retain(type, reason: "it is a test case")
            for member in members where graph[member].kind == .instanceMethod && graph[member].name.hasPrefix("test") {
                graph.retain(member, reason: "it is a test")
            }
        }
        // Swift Testing creates an instance of the suite for each test.
        if declaration.attributes.contains("Suite") || members.contains(where: { graph[$0].attributes.contains("Test") }) {
            for member in members where graph[member].kind == .initializer && graph[member].name == "init()" {
                graph.retain(member, reason: "Swift Testing creates suites with it")
            }
        }
        if configuration.retainSwiftUIPreviews, usrs.contains(KnownSymbols.previewProvider) {
            graph.retain(type, reason: "it is a SwiftUI preview")
        }

        // Members that attributes make the compiler call.
        let attributes = declaration.attributes
        for member in members {
            let name = graph[member].name
            let kind = graph[member].kind
            if attributes.contains("propertyWrapper"),
               name == "wrappedValue" || name == "projectedValue" || name.hasPrefix("init(wrappedValue:")
               || name.hasPrefix("subscript(_enclosingInstance:") {
                retainWithOwner(member, rule: "property wrappers use it implicitly")
            }
            if attributes.contains("resultBuilder"), kind == .staticMethod, name.hasPrefix("build") {
                retainWithOwner(member, rule: "result builders call it implicitly")
            }
            if attributes.contains("dynamicMemberLookup"), kind == .subscript, name.hasPrefix("subscript(dynamicMember:") {
                retainWithOwner(member, rule: "dynamic member lookup calls it implicitly")
            }
            if attributes.contains("dynamicCallable"), name.hasPrefix("dynamicallyCall(") {
                retainWithOwner(member, rule: "dynamic calls call it implicitly")
            }
            if configuration.retainObjcAnnotated, attributes.contains("objcMembers"),
               graph[member].usrs.contains(where: { $0.hasPrefix("c:") }) {
                graph.retain(member, reason: "it is exposed to Objective-C")
            }
        }

        let storedProperties = members.filter {
            graph[$0].kind == .instanceProperty && syntax[$0]?.isStored == true
        }
        let memberNames = Set(members.map { graph[$0].name })

        // Codable synthesizes `encode(to:)` and `init(from:)` from stored properties and `CodingKeys`.
        let isEncodable = usrs.contains(KnownSymbols.encodable)
            || !names.isDisjoint(with: configuration.externalEncodableProtocols)
            || !names.isDisjoint(with: configuration.externalCodableProtocols)
        let isDecodable = usrs.contains(KnownSymbols.decodable)
            || !names.isDisjoint(with: configuration.externalCodableProtocols)
        if isEncodable, configuration.retainEncodableProperties, !memberNames.contains("encode(to:)") {
            for property in storedProperties {
                retainWithOwner(property, rule: "synthesized Encodable conformance reads it")
            }
        }
        if isDecodable, configuration.retainCodableProperties {
            for property in storedProperties {
                retainWithOwner(property, rule: "synthesized Decodable conformance writes it")
            }
        }
        if isEncodable || isDecodable {
            for member in members where graph[member].name == "CodingKeys" && graph[member].kind.isType {
                retainWithOwner(member, rule: "synthesized Codable conformance uses it")
            }
        }

        // Synthesized Equatable and Hashable conformances compare and hash stored properties.
        if declaration.kind == .struct {
            let isHashable = usrs.contains(KnownSymbols.hashable)
            let synthesizesEquality = (isHashable || usrs.contains(KnownSymbols.equatable)) && !memberNames.contains("==(_:_:)")
            let synthesizesHashing = isHashable && !memberNames.contains("hash(into:)")
            if synthesizesEquality || synthesizesHashing {
                for property in storedProperties {
                    retainWithOwner(property, rule: "synthesized Equatable or Hashable conformance reads it")
                }
            }
        }

        // Enum cases that can be created without being named.
        if declaration.kind == .enum {
            let createsCasesDynamically = usrs.contains(KnownSymbols.caseIterable)
                || usrs.contains(KnownSymbols.codingKey)
                || isDecodable
                || (configuration.retainObjcAnnotated && attributes.contains("objc"))
                || rawValueInitializers.contains { usr in declaration.usrs.contains { usr.hasPrefix($0) } }
            if createsCasesDynamically {
                for member in members where graph[member].kind == .enumCase {
                    retainWithOwner(member, rule: "its cases are created dynamically (CaseIterable, Decodable or init(rawValue:))")
                }
            }
        }
    }

    /// Declared in a protocol or a protocol extension.
    private func isInProtocol(_ id: Declaration.ID) -> Bool {
        if case let .local(owner) = owner(of: id) {
            return graph[owner].kind == .protocol
        }
        return false
    }

    func isObjcAnnotated(_ id: Declaration.ID) -> Bool {
        let declaration = graph[id]
        return !declaration.attributes.isDisjoint(with: KnownSymbols.objcAttributes)
            || declaration.modifiers.contains("dynamic")
            || declaration.modifiers.contains("optional")
    }

    /// The accessibility a declaration has, considering `public extension` and protocol members.
    func effectiveAccessibility(of id: Declaration.ID) -> Accessibility {
        let declaration = graph[id]
        if let explicit = declaration.explicitAccessibility {
            return explicit
        }
        guard let parent = declaration.parent else { return .internal }
        let parentDeclaration = graph[parent]
        switch parentDeclaration.kind {
        case .extension:
            return parentDeclaration.explicitAccessibility ?? .internal
        case .protocol:
            return effectiveAccessibility(of: parent)
        case .enum where declaration.kind == .enumCase:
            return effectiveAccessibility(of: parent)
        default:
            return .internal
        }
    }

    /// Retains a declaration and everything inside it, and keeps it out of results.
    private func retainIgnored(_ id: Declaration.ID, reason: String) {
        var stack = [id]
        while let current = stack.popLast() {
            graph.retain(current, reason: reason)
            graph[current].isReportable = false
            ignored.insert(current)
            stack.append(contentsOf: graph[current].children)
        }
    }
}
