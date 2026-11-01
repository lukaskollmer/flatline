import FlatlineCore
import IndexStore

struct IndexedFile: Sendable {
    let unit: SourceUnit
    let occurrences: [SymbolOccurrence]
}

/// How a declaration is referenced across the project.
struct ReferenceStats {
    var reads = 0
    var writes = 0
    /// References that neither read nor write, e.g. memberwise initializer labels.
    var other = 0
    var referencingModules: Set<String> = []
    /// A function referenced without being called, e.g. passed as a closure.
    var usedAsValue = false
}

struct InheritedType: Hashable {
    let usr: String
    let name: String
}

enum Owner {
    /// A type in the project.
    case local(Declaration.ID)
    /// A type from a dependency or the SDK, via an extension.
    case external
    /// A global declaration.
    case none
}

/// Builds the declaration graph from index occurrences, and records what the
/// rules and analyses need beyond plain references.
final class SwiftGraphBuilder {
    let graph = SourceGraph()
    let configuration: Configuration
    let syntaxByFile: [String: FileSyntaxInfo]

    private(set) var syntax: [Declaration.ID: DeclarationSyntaxInfo] = [:]
    private(set) var stats: [Declaration.ID: ReferenceStats] = [:]
    /// USRs that a declaration overrides or implements.
    private(set) var overrides: [Declaration.ID: Set<String>] = [:]
    private(set) var overriddenBy: [Declaration.ID: [Declaration.ID]] = [:]
    /// Supertypes named in the inheritance clauses of a type and its extensions.
    private(set) var inheritance: [Declaration.ID: Set<InheritedType>] = [:]
    /// Types that conform to a protocol in the project, keyed by protocol.
    private(set) var conformingTypes: [Declaration.ID: Set<Declaration.ID>] = [:]
    private(set) var extendedType: [Declaration.ID: Declaration.ID] = [:]
    private(set) var extensionsByType: [Declaration.ID: [Declaration.ID]] = [:]
    private(set) var extensionsOfExternalTypes: Set<Declaration.ID> = []
    /// Declarations used implicitly by language rules (synthesized code, runtime).
    private(set) var ruleRetained: Set<Declaration.ID> = []
    /// USRs of synthesized `init(rawValue:)` initializers that are called somewhere.
    private(set) var rawValueInitializers: Set<String> = []
    /// Test classes and methods, as marked by the compiler.
    private(set) var unitTests: Set<Declaration.ID> = []
    /// Declarations excluded by comment commands.
    var ignored: Set<Declaration.ID> = []

    private var idsByLocation: [SourceLocation: Declaration.ID] = [:]
    private var idsByLocationKey: [LocationKey: Declaration.ID] = [:]
    private var pendingParents: [(child: Declaration.ID, parent: String)] = []
    private var pendingAccessors: [(accessor: String, property: String)] = []
    private var pendingExtensions: [(extension: String, type: String)] = []

    private struct LocationKey: Hashable {
        let location: SourceLocation
        let kind: DeclarationKind
        let name: String
    }

    init(configuration: Configuration, syntax: [String: FileSyntaxInfo]) {
        self.configuration = configuration
        syntaxByFile = syntax
    }

    func build(_ files: [IndexedFile]) {
        for file in files where file.unit.language == .swift {
            collectDeclarations(in: file)
        }
        resolvePendingRelations()
        for file in files {
            collectReferences(in: file)
        }
        resolveOverrides()
    }

    func resolve(_ usr: String) -> Declaration.ID? {
        graph.declaration(forUSR: usr)
    }

    // MARK: - Declarations

    private func collectDeclarations(in file: IndexedFile) {
        let fileSyntax = syntaxByFile[file.unit.file]
        for occurrence in file.occurrences {
            if occurrence.roles.contains(.reference) {
                for relation in occurrence.relations where relation.roles.contains(.extendedBy) {
                    pendingExtensions.append((relation.symbol.usr, occurrence.symbol.usr))
                }
                continue
            }
            guard !occurrence.roles.isDisjoint(with: [.definition, .declaration]) else { continue }

            switch occurrence.symbol.classification {
            case .ignored:
                continue
            case .accessor:
                // Some generated accessors (e.g. `modify` from @Observable) only have `childOf`.
                if let property = occurrence.relations.first(where: { $0.roles.contains(.accessorOf) })
                    ?? occurrence.relations.first(where: { $0.roles.contains(.childOf) }) {
                    pendingAccessors.append((occurrence.symbol.usr, property.symbol.usr))
                }
            case let .declaration(kind):
                let id = declare(occurrence, kind: kind, unit: file.unit, fileSyntax: fileSyntax)
                for relation in occurrence.relations {
                    if relation.roles.contains(.childOf) {
                        pendingParents.append((id, relation.symbol.usr))
                    }
                    if relation.roles.contains(.overrideOf) {
                        overrides[id, default: []].insert(relation.symbol.usr)
                    }
                }
            }
        }
    }

    private func declare(
        _ occurrence: SymbolOccurrence,
        kind: DeclarationKind,
        unit: SourceUnit,
        fileSyntax: FileSyntaxInfo?
    ) -> Declaration.ID {
        let usr = occurrence.symbol.usr
        if occurrence.symbol.properties.contains(.unitTest), let existing = resolve(usr) {
            unitTests.insert(existing)
        }
        if let existing = resolve(usr) {
            graph.addUSR(usr, module: unit.module, to: existing)
            return existing
        }

        let location = SourceLocation(file: unit.file, line: occurrence.line, column: occurrence.column)
        let isImplicit = occurrence.roles.contains(.implicit)
        let key = LocationKey(location: location, kind: kind, name: occurrence.symbol.name)
        // The same source compiled into another module has other USRs.
        if !isImplicit, let existing = idsByLocationKey[key] {
            graph.addUSR(usr, module: unit.module, to: existing)
            return existing
        }

        let info = isImplicit ? nil : fileSyntax?.declarations[Position(line: location.line, column: location.column)]
        var kind = kind
        if kind == .class, case .type(isActor: true) = info?.kind {
            kind = .actor
        }

        let id = graph.addDeclaration(
            kind: kind,
            name: occurrence.symbol.name,
            usr: usr,
            location: location,
            module: unit.module,
            isImplicit: isImplicit
        )
        if let objcUSR = usr.objcUSRWithoutModule {
            graph.addAlias(objcUSR, for: id)
        }
        if occurrence.symbol.properties.contains(.unitTest) {
            unitTests.insert(id)
        }
        if !isImplicit {
            idsByLocationKey[key] = id
            idsByLocation[location] = id
        }
        if let info {
            syntax[id] = info
            graph[id].attributes = info.attributes
            graph[id].modifiers = info.modifiers
            graph[id].explicitAccessibility = info.accessibility
        }
        return id
    }

    private func resolvePendingRelations() {
        for (accessor, property) in pendingAccessors {
            if let id = resolve(property) {
                graph.addAlias(accessor, for: id)
            }
        }
        for (child, parent) in pendingParents {
            if let parent = resolve(parent) {
                graph.setParent(parent, of: child)
            }
        }
        for (extensionUSR, typeUSR) in pendingExtensions {
            guard let ext = resolve(extensionUSR), graph[ext].kind == .extension,
                  extendedType[ext] == nil, !extensionsOfExternalTypes.contains(ext)
            else { continue }
            if let type = resolve(typeUSR) {
                extendedType[ext] = type
                extensionsByType[type, default: []].append(ext)
                // A used extension member keeps the extended type alive.
                graph.addReference(from: ext, to: type)
            } else {
                extensionsOfExternalTypes.insert(ext)
            }
        }
        pendingAccessors = []
        pendingParents = []
        pendingExtensions = []
    }

    // MARK: - References

    private func collectReferences(in file: IndexedFile) {
        let fileSyntax = syntaxByFile[file.unit.file]
        for occurrence in file.occurrences where occurrence.roles.contains(.reference) {
            let symbol = occurrence.symbol
            guard symbol.kind != .module else { continue }

            // Objective-C and C code isn't analyzed, but its references to Swift count.
            if file.unit.language == .clang {
                if let target = resolve(symbol.usr) {
                    recordStats(of: occurrence, target: target, module: file.unit.module)
                    graph.addTopLevelReference(to: target)
                }
                continue
            }

            // Inheritance clauses: superclasses are uses, protocol conformances are not.
            if let base = occurrence.relations.first(where: { $0.roles.contains(.baseOf) }) {
                guard let subtype = resolve(base.symbol.usr) else { continue }
                let owner = extendedType[subtype] ?? subtype
                inheritance[owner, default: []].insert(InheritedType(usr: symbol.usr, name: symbol.name))
                if let target = resolve(symbol.usr) {
                    recordStats(of: occurrence, target: target, module: file.unit.module)
                    if graph[target].kind == .protocol {
                        conformingTypes[target, default: []].insert(owner)
                        // Typealiases of a protocol can satisfy the conforming type's
                        // associated types, so the conformance can't be removed.
                        if members(of: target).contains(where: { graph[$0].kind == .typealias }) {
                            graph.addReference(from: subtype, to: target)
                        }
                    } else {
                        graph.addReference(from: subtype, to: target)
                    }
                }
                continue
            }
            // The extended type of an extension; handled when collecting declarations.
            if occurrence.relations.contains(where: { $0.roles.contains(.extendedBy) }) {
                continue
            }

            guard let target = resolve(symbol.usr) else {
                if symbol.name == "init(rawValue:)" {
                    rawValueInitializers.insert(symbol.usr)
                }
                continue
            }
            recordStats(of: occurrence, target: target, module: file.unit.module)

            let position = Position(line: occurrence.line, column: occurrence.column)
            if let source = container(of: occurrence, at: position, file: file.unit.file, syntax: fileSyntax) {
                if isEagerlyInitializedGlobal(source, fileSyntax: fileSyntax) {
                    graph.addTopLevelReference(to: target)
                } else {
                    graph.addReference(from: source, to: target)
                }
            } else {
                if !configuration.retainSwiftUIPreviews, fileSyntax?.isInPreview(position) == true {
                    continue
                }
                graph.addTopLevelReference(to: target)
            }
        }
    }

    /// The declaration whose body or signature contains a reference.
    private func container(
        of occurrence: SymbolOccurrence,
        at position: Position,
        file: String,
        syntax fileSyntax: FileSyntaxInfo?
    ) -> Declaration.ID? {
        for role in [SymbolRoles.containedBy, .calledBy] {
            for relation in occurrence.relations where relation.roles.contains(role) {
                if let id = resolve(relation.symbol.usr) {
                    return id
                }
            }
        }
        // Not every reference has a container relation, e.g. in typealiases.
        for scope in fileSyntax?.declarations(containing: position) ?? [] {
            let location = SourceLocation(file: file, line: scope.namePosition.line, column: scope.namePosition.column)
            if let id = idsByLocation[location] {
                return id
            }
        }
        return nil
    }

    /// Global variables in files with top-level code are initialized when the
    /// code runs, so their initializers always execute.
    private func isEagerlyInitializedGlobal(_ id: Declaration.ID, fileSyntax: FileSyntaxInfo?) -> Bool {
        graph[id].kind == .globalVariable && syntax[id]?.isTopLevel == true && fileSyntax?.hasTopLevelCode == true
    }

    private func recordStats(of occurrence: SymbolOccurrence, target: Declaration.ID, module: String) {
        let roles = occurrence.roles
        var entry = stats[target, default: ReferenceStats()]
        entry.referencingModules.insert(module)
        // Implicit accessor calls duplicate the property reference next to them.
        if case .accessor = occurrence.symbol.classification {
            stats[target] = entry
            return
        }
        if roles.contains(.read) { entry.reads += 1 }
        if roles.contains(.write) { entry.writes += 1 }
        if roles.isDisjoint(with: [.read, .write]) { entry.other += 1 }
        if graph[target].kind.isFunction, !roles.contains(.call), !roles.contains(.implicit) {
            entry.usedAsValue = true
        }
        stats[target] = entry
    }

    // MARK: - Overrides and protocol witnesses

    private func resolveOverrides() {
        for (id, bases) in overrides {
            for base in bases {
                guard let baseID = resolve(base), baseID != id else {
                    retainWithOwner(id, rule: "implements or overrides an external declaration")
                    continue
                }
                overriddenBy[baseID, default: []].append(id)
                let isRequirement = graph[baseID].parent.map { graph[$0].kind == .protocol } ?? false
                if !isRequirement {
                    // Removing the base would break the `override`.
                    graph.addReference(from: id, to: baseID)
                }
                var requirements = [baseID]
                if case let .local(owner) = owner(of: id) {
                    requirements.append(owner)
                }
                graph.retain(
                    id,
                    when: requirements,
                    rule: isRequirement ? "implements a used protocol requirement" : "overrides a used declaration"
                )
            }
        }
    }

    // MARK: - Helpers

    /// The type a member belongs to, looking through extensions.
    func owner(of id: Declaration.ID) -> Owner {
        guard let parent = graph[id].parent else { return .none }
        if graph[parent].kind == .extension {
            if let type = extendedType[parent] {
                return .local(type)
            }
            return .external
        }
        return .local(parent)
    }

    /// Retains `id` whenever the type it belongs to is used.
    func retainWithOwner(_ id: Declaration.ID, rule: String) {
        ruleRetained.insert(id)
        switch owner(of: id) {
        case let .local(owner):
            graph.retain(id, when: [owner], rule: rule)
        case .external, .none:
            graph.retain(id, reason: rule)
        }
    }

    func markRuleRetained(_ id: Declaration.ID) {
        ruleRetained.insert(id)
    }

    /// Supertypes of a type, including those inherited through protocols and
    /// classes in the project.
    func allSupertypes(of id: Declaration.ID, throughClasses: Bool) -> Set<InheritedType> {
        var result: Set<InheritedType> = []
        var visited: Set<Declaration.ID> = []
        var queue = [id]
        while let current = queue.popLast() {
            guard visited.insert(current).inserted else { continue }
            for inherited in inheritance[current] ?? [] {
                result.insert(inherited)
                if let local = resolve(inherited.usr),
                   graph[local].kind == .protocol || (throughClasses && graph[local].kind == .class) {
                    queue.append(local)
                }
            }
        }
        return result
    }

    /// Members of a type, including those declared in extensions.
    func members(of id: Declaration.ID) -> [Declaration.ID] {
        graph[id].children + (extensionsByType[id] ?? []).flatMap { graph[$0].children }
    }
}
