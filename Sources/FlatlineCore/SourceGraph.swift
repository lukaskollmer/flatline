/// Why a declaration is considered used.
public enum RetentionReason: Sendable, Equatable {
    /// Retained unconditionally, e.g. an entry point or an ignored declaration.
    case root(String)
    /// Referenced from the body or signature of another used declaration.
    case referenced(by: Declaration.ID)
    /// Referenced from code outside any declaration, e.g. top-level code.
    case referencedFromTopLevel
    /// One of its members is used, so the declaration itself must stay.
    case containsUsedMember(Declaration.ID)
    /// Retained by a language rule once all of its requirements were used,
    /// e.g. a protocol witness whose requirement and owner are both used.
    case rule(String, requirements: [Declaration.ID])
}

/// The declarations of a project and the "uses" relationships between them.
///
/// Front ends (one per language) add declarations and edges; the graph then
/// computes which declarations are reachable from the roots. Unreachable
/// declarations are unused.
public final class SourceGraph {
    public private(set) var declarations: [Declaration] = []
    private var idsByUSR: [String: Declaration.ID] = [:]
    private var references: [[Declaration.ID]] = []
    private var roots: [(Declaration.ID, RetentionReason)] = []
    private var topLevelReferences: [Declaration.ID] = []
    private var conditionalEdges: [ConditionalEdge] = []
    private var conditionalEdgesByRequirement: [Declaration.ID: [Int]] = [:]
    private var reasons: [RetentionReason?] = []
    private var isComputed = false

    private struct ConditionalEdge {
        let target: Declaration.ID
        let requirements: [Declaration.ID]
        let rule: String
    }

    public init() {}

    // MARK: - Building

    @discardableResult
    public func addDeclaration(
        kind: DeclarationKind,
        name: String,
        usr: String,
        location: SourceLocation,
        module: String,
        isImplicit: Bool = false
    ) -> Declaration.ID {
        let id = declarations.count
        declarations.append(Declaration(
            id: id,
            kind: kind,
            name: name,
            usrs: [usr],
            location: location,
            modules: [module],
            isImplicit: isImplicit
        ))
        references.append([])
        idsByUSR[usr] = id
        isComputed = false
        return id
    }

    /// Makes `usr` resolve to `id`, e.g. for an accessor of a property or for
    /// the same declaration compiled into a second module.
    public func addAlias(_ usr: String, for id: Declaration.ID) {
        idsByUSR[usr] = id
    }

    public func addUSR(_ usr: String, module: String, to id: Declaration.ID) {
        if !declarations[id].usrs.contains(usr) {
            declarations[id].usrs.append(usr)
        }
        declarations[id].modules.insert(module)
        idsByUSR[usr] = id
    }

    public func declaration(forUSR usr: String) -> Declaration.ID? {
        idsByUSR[usr]
    }

    public subscript(id: Declaration.ID) -> Declaration {
        get { declarations[id] }
        set { declarations[id] = newValue }
    }

    public func setParent(_ parent: Declaration.ID, of child: Declaration.ID) {
        guard parent != child, declarations[child].parent == nil else { return }
        declarations[child].parent = parent
        declarations[parent].children.append(child)
    }

    /// Records that `source` uses `target`: if `source` is used, so is `target`.
    public func addReference(from source: Declaration.ID, to target: Declaration.ID) {
        guard source != target else { return }
        references[source].append(target)
        isComputed = false
    }

    /// Records a use of `target` from code that always runs, such as top-level code.
    public func addTopLevelReference(to target: Declaration.ID) {
        topLevelReferences.append(target)
        isComputed = false
    }

    public func retain(_ id: Declaration.ID, reason: String) {
        roots.append((id, .root(reason)))
        isComputed = false
    }

    /// Retains `target` once every declaration in `requirements` is used.
    public func retain(_ target: Declaration.ID, when requirements: [Declaration.ID], rule: String) {
        let requirements = Array(Set(requirements)).filter { $0 != target }
        guard !requirements.isEmpty else {
            retain(target, reason: rule)
            return
        }
        let index = conditionalEdges.count
        conditionalEdges.append(ConditionalEdge(target: target, requirements: requirements, rule: rule))
        for requirement in requirements {
            conditionalEdgesByRequirement[requirement, default: []].append(index)
        }
        isComputed = false
    }

    // MARK: - Reachability

    public func computeReachability() {
        reasons = Array(repeating: nil, count: declarations.count)
        var remainingRequirements = conditionalEdges.map(\.requirements.count)
        var worklist: [Declaration.ID] = []

        func mark(_ id: Declaration.ID, _ reason: RetentionReason) {
            guard reasons[id] == nil else { return }
            reasons[id] = reason
            worklist.append(id)
        }

        for (id, reason) in roots {
            mark(id, reason)
        }
        for id in topLevelReferences {
            mark(id, .referencedFromTopLevel)
        }

        while let id = worklist.popLast() {
            for target in references[id] {
                mark(target, .referenced(by: id))
            }
            if let parent = declarations[id].parent {
                mark(parent, .containsUsedMember(id))
            }
            for index in conditionalEdgesByRequirement[id] ?? [] {
                remainingRequirements[index] -= 1
                if remainingRequirements[index] == 0 {
                    let edge = conditionalEdges[index]
                    mark(edge.target, .rule(edge.rule, requirements: edge.requirements))
                }
            }
        }
        isComputed = true
    }

    public func isReachable(_ id: Declaration.ID) -> Bool {
        precondition(isComputed, "computeReachability() must be called first")
        return reasons[id] != nil
    }

    public func retentionReason(for id: Declaration.ID) -> RetentionReason? {
        precondition(isComputed, "computeReachability() must be called first")
        return reasons[id]
    }

    /// The outgoing "uses" edges of a declaration.
    public func referencedDeclarations(from id: Declaration.ID) -> [Declaration.ID] {
        references[id]
    }
}
