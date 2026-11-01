import FlatlineCore

struct ReportFilter {
    let projectRoot: String
    /// Report only these modules; empty means all.
    let modules: Set<String>
    let include: [Glob]
    let exclude: [Glob]

    func includes(_ declaration: Declaration) -> Bool {
        if !modules.isEmpty, declaration.modules.isDisjoint(with: modules) {
            return false
        }
        let file = declaration.location.file
        if !include.isEmpty, !Glob.any(include, match: file, relativeTo: projectRoot) {
            return false
        }
        return !Glob.any(exclude, match: file, relativeTo: projectRoot)
    }
}

/// Turns the computed reachability into results.
extension SwiftGraphBuilder {
    func findings(filter: ReportFilter) -> [Finding] {
        let reportable = graph.declarations.map { isReportable($0, filter: filter) }
        var findings: [Finding] = []

        findings += unusedDeclarations(reportable: reportable)
        if !configuration.retainAssignOnlyProperties {
            findings += assignOnlyProperties(reportable: reportable)
        }
        if !configuration.disableUnusedParameterAnalysis {
            findings += unusedParameters(reportable: reportable)
        }
        if !configuration.retainPublic, !configuration.disableRedundantPublicAnalysis {
            findings += redundantPublicAccessibility(reportable: reportable)
        }
        return findings.sorted { ($0.location, $0.kind.rawValue, $0.name) < ($1.location, $1.kind.rawValue, $1.name) }
    }

    private func isReportable(_ declaration: Declaration, filter: ReportFilter) -> Bool {
        guard declaration.isReportable, !declaration.isImplicit,
              declaration.kind != .extension, declaration.kind != .associatedType,
              // Without the parsed declaration, attributes like @objc are unknown.
              syntax[declaration.id] != nil
        else { return false }
        return filter.includes(declaration)
    }

    private func finding(_ kind: Finding.Kind, _ id: Declaration.ID, name: String? = nil, at location: SourceLocation? = nil) -> Finding {
        let declaration = graph[id]
        return Finding(
            kind: kind,
            declarationKind: declaration.kind,
            name: name ?? declaration.name,
            location: location ?? declaration.location,
            modules: Array(declaration.modules),
            usrs: declaration.usrs,
            accessibility: kind == .redundantPublicAccessibility ? declaration.explicitAccessibility : nil
        )
    }

    // MARK: - Unused declarations

    /// The declaration that a result for `id` would be implied by: its parent,
    /// or the extended type for members of extensions.
    private func reportingParent(of id: Declaration.ID) -> Declaration.ID? {
        guard let parent = graph[id].parent else { return nil }
        if graph[parent].kind == .extension {
            return extendedType[parent]
        }
        return parent
    }

    private func unusedDeclarations(reportable: [Bool]) -> [Finding] {
        var findings: [Finding] = []
        for declaration in graph.declarations where reportable[declaration.id] && !graph.isReachable(declaration.id) {
            // Report only the outermost unused declaration; its members go with it.
            var ancestor = reportingParent(of: declaration.id)
            var isImplied = false
            while let current = ancestor {
                if reportable[current], !graph.isReachable(current) {
                    isImplied = true
                    break
                }
                ancestor = reportingParent(of: current)
            }
            guard !isImplied else { continue }

            let isRedundantProtocol = declaration.kind == .protocol && !(conformingTypes[declaration.id] ?? []).isEmpty
            findings.append(finding(isRedundantProtocol ? .redundantProtocol : .unused, declaration.id))
        }
        return findings
    }

    // MARK: - Assign-only properties

    private func assignOnlyProperties(reportable: [Bool]) -> [Finding] {
        let retainedTypes = Set(configuration.retainAssignOnlyPropertyTypes.map(normalizedType))
        var findings: [Finding] = []
        for declaration in graph.declarations where declaration.kind.isVariable && reportable[declaration.id] {
            let id = declaration.id
            guard graph.isReachable(id),
                  let info = syntax[id], info.isStored, !info.hasObservers,
                  // Wrappers like @Published or @AppStorage act on assignment.
                  declaration.attributes.isSubset(of: KnownSymbols.inertVariableAttributes),
                  !ruleRetained.contains(id), overrides[id] == nil, overriddenBy[id] == nil,
                  // Roots such as @objc or ignored declarations may be read from elsewhere.
                  !isRoot(id),
                  let stats = stats[id], stats.reads == 0, stats.writes + stats.other > 0
            else { continue }
            if let type = info.typeAnnotation, retainedTypes.contains(normalizedType(type)) {
                continue
            }
            findings.append(finding(.assignOnlyProperty, id))
        }
        return findings
    }

    private func isRoot(_ id: Declaration.ID) -> Bool {
        if case .root = graph.retentionReason(for: id) { true } else { false }
    }

    private func normalizedType(_ type: String) -> String {
        var type = type.filter { !$0.isWhitespace }
        while type.hasSuffix("?") || type.hasSuffix("!") {
            type.removeLast()
        }
        return type
    }

    // MARK: - Unused parameters

    private func unusedParameters(reportable: [Bool]) -> [Finding] {
        var findings: [Finding] = []
        for declaration in graph.declarations where declaration.kind.isFunction && reportable[declaration.id] {
            let id = declaration.id
            guard let info = syntax[id], !info.parameters.isEmpty, info.hasBody, !info.isStub,
                  graph.isReachable(id),
                  // The signature is dictated by something else: a protocol, a
                  // superclass, an override, Objective-C, or a closure type.
                  overrides[id] == nil, overriddenBy[id] == nil, !ruleRetained.contains(id),
                  !(declaration.parent.map { graph[$0].kind == .protocol } ?? false),
                  !isObjcAnnotated(id), !declaration.usrs.contains(where: { $0.hasPrefix("c:") }),
                  declaration.attributes.isDisjoint(with: KnownSymbols.exportAttributes),
                  stats[id]?.usedAsValue != true,
                  !(configuration.retainPublic && effectiveAccessibility(of: id) >= .public)
            else { continue }

            let ignoredNames = info.ignoredParameters
            for parameter in info.parameters where !parameter.isUsed && !ignoredNames.contains(parameter.name) {
                let location = SourceLocation(
                    file: declaration.location.file,
                    line: parameter.position.line,
                    column: parameter.position.column
                )
                findings.append(finding(.unusedParameter, id, name: parameter.name, at: location))
            }
        }
        return findings
    }

    // MARK: - Redundant public accessibility

    private func redundantPublicAccessibility(reportable: [Bool]) -> [Finding] {
        // Who references each declaration, to tell whether public API depends on it.
        var referrers: [[Declaration.ID]] = Array(repeating: [], count: graph.declarations.count)
        for source in graph.declarations.indices {
            for target in graph.referencedDeclarations(from: source) {
                referrers[target].append(source)
            }
        }

        var findings: [Finding] = []
        for declaration in graph.declarations where reportable[declaration.id] {
            let id = declaration.id
            guard let accessibility = declaration.explicitAccessibility, accessibility >= .public,
                  graph.isReachable(id), overrides[id] == nil,
                  // Members used by language features (property wrappers, result
                  // builders, ...) must be as accessible as their type.
                  !ruleRetained.contains(id) || syntax[id]?.isStored == true,
                  !(declaration.parent.map { graph[$0].kind == .protocol } ?? false),
                  !declaration.attributes.contains("usableFromInline")
            else { continue }

            var requiresPublic = false
            var stack = [id]
            var visited: Set<Declaration.ID> = []
            while let current = stack.popLast(), !requiresPublic {
                guard visited.insert(current).inserted else { continue }
                let modules = graph[current].modules
                if let referencing = stats[current]?.referencingModules, !referencing.isSubset(of: modules) {
                    requiresPublic = true
                }
                // Public API that mentions this declaration needs it to be public too.
                if referrers[current].contains(where: { $0 != current && effectiveAccessibility(of: $0) >= .public && !isInside($0, id) }) {
                    requiresPublic = true
                }
                stack.append(contentsOf: graph[current].kind.isType ? members(of: current) : graph[current].children)
                // Inherited initializers keep the accessibility of the initializer they inherit.
                stack.append(contentsOf: (overriddenBy[current] ?? []).filter { graph[$0].isImplicit })
            }
            if !requiresPublic {
                findings.append(finding(.redundantPublicAccessibility, id))
            }
        }
        return findings
    }

    private func isInside(_ id: Declaration.ID, _ ancestor: Declaration.ID) -> Bool {
        var current = graph[id].parent
        while let parent = current {
            if parent == ancestor { return true }
            current = graph[parent].kind == .extension ? extendedType[parent] : graph[parent].parent
        }
        return false
    }
}
