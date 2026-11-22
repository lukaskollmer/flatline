import FlatlineCore
import IndexStore

/// Finds imports that a file doesn't use.
///
/// An import is used when the file refers to a declaration of the imported
/// module, or of a module that it re-exports with `@_exported import`. The
/// index doesn't record uses of conformances, so a module that adds a
/// conformance to a type counts as used where the type or its members are.
///
/// Once one file of a module imports another module, Swift makes the extension
/// members and conformances of the imported module visible in all files of the
/// module. So an import isn't reported when another file of the same module
/// uses the imported module without importing it: removing the import would
/// break that file.
///
/// Only imports of the project's own modules are analyzed. For other modules
/// (the SDK, dependencies), the index doesn't tell which declarations they hold.
struct ImportAnalysis {
    private let builder: SwiftGraphBuilder
    private let configuration: Configuration
    private let syntax: [String: FileSyntaxInfo]
    private let files: [IndexedFile]
    /// Modules whose declarations are all known: Swift only, every file read and parsed.
    let analyzableModules: Set<String>
    /// Modules with a Swift file that couldn't be read or parsed, so their uses are unknown.
    private let modulesWithUnknownFiles: Set<String>
    /// The modules of declarations in auxiliary files (generated or excluded), by USR.
    private let auxiliaryModules: [String: Set<String>]
    private let auxiliaryFiles: [IndexedFile]

    init(
        builder: SwiftGraphBuilder,
        configuration: Configuration,
        syntax: [String: FileSyntaxInfo],
        files: [(SourceUnit, IndexedFile?)],
        auxiliaryFiles: [(SourceUnit, IndexedFile?)]
    ) {
        self.builder = builder
        self.configuration = configuration
        self.syntax = syntax
        self.files = files.compactMap(\.1)
        self.auxiliaryFiles = auxiliaryFiles.compactMap(\.1)

        var swiftModules: Set<String> = []
        var incomplete: Set<String> = []
        var unknown: Set<String> = []
        for (unit, file) in files {
            if unit.language == .clang {
                incomplete.insert(unit.module)
            } else if file == nil || syntax[unit.file] == nil {
                unknown.insert(unit.module)
            } else {
                swiftModules.insert(unit.module)
            }
        }
        for (unit, file) in auxiliaryFiles where unit.language == .clang || file == nil {
            incomplete.insert(unit.module)
        }
        analyzableModules = swiftModules.subtracting(incomplete).subtracting(unknown)
        modulesWithUnknownFiles = unknown

        var auxiliaryModules: [String: Set<String>] = [:]
        for case let (unit, file?) in auxiliaryFiles {
            for occurrence in file.occurrences where !occurrence.roles.isDisjoint(with: [.definition, .declaration]) {
                auxiliaryModules[occurrence.symbol.usr, default: []].insert(unit.module)
            }
        }
        self.auxiliaryModules = auxiliaryModules
    }

    /// What one source file imports and uses, across all modules and build
    /// variants it's compiled in.
    private struct FileUses {
        var modules: Set<String> = []
        /// Module positions of the imports that were compiled.
        var compiledImports: Set<Position> = []
        var referencedUSRs: Set<String> = []
        /// Modules named in qualified references like `Module.Type`.
        var qualifiedModules: Set<String> = []
        /// Declarations named by imports of single declarations, by module position.
        var scopedUSRs: [Position: Set<String>] = [:]
    }

    func findings(filter: ReportFilter) -> [Finding] {
        let retained = Set(configuration.retainUnusedImportedModules)
        let uses = collectUses()
        let conformances = conformanceModules()

        // The modules each file needs: those of the declarations it refers
        // to, and those that may provide conformances it relies on.
        var needed: [String: Set<String>] = [:]
        for (path, entry) in uses {
            var modules = entry.qualifiedModules
            for usr in entry.referencedUSRs {
                modules.formUnion(self.modules(of: usr) ?? [])
                modules.formUnion(conformances[usr] ?? [])
                for type in enclosingDeclarations(of: usr) {
                    for usr in builder.graph[type].usrs {
                        modules.formUnion(conformances[usr] ?? [])
                    }
                }
            }
            needed[path] = modules.subtracting(entry.modules)
        }

        var exports: [String: Set<String>] = [:]
        for (path, entry) in uses {
            for declaration in compiledImports(of: path, uses: entry) where declaration.isExported {
                for module in entry.modules {
                    exports[module, default: []].insert(declaration.module)
                }
            }
        }
        var closures: [String: Set<String>] = [:]
        /// The modules that importing `module` makes visible.
        func visible(through module: String) -> Set<String> {
            if let cached = closures[module] { return cached }
            var result: Set<String> = [module]
            var queue = [module]
            while let current = queue.popLast() {
                for exported in exports[current] ?? [] where result.insert(exported).inserted {
                    queue.append(exported)
                }
            }
            closures[module] = result
            return result
        }

        // Modules that a file uses without importing them, by the module the
        // file is in: imports of them elsewhere in that module are load-bearing.
        var leaked: [String: Set<String>] = [:]
        for (path, entry) in uses {
            let visibleModules = compiledImports(of: path, uses: entry)
                .reduce(into: Set<String>()) { $0.formUnion(visible(through: $1.module)) }
            let missing = needed[path, default: []].subtracting(visibleModules)
            for module in entry.modules {
                leaked[module, default: []].formUnion(missing)
            }
        }

        var findings: [Finding] = []
        for (path, entry) in uses {
            guard let fileSyntax = syntax[path], !fileSyntax.ignoresAll,
                  entry.modules.isDisjoint(with: modulesWithUnknownFiles),
                  filter.includes(file: path, modules: entry.modules)
            else { continue }
            let imports = compiledImports(of: path, uses: entry)
            for declaration in imports {
                let module = declaration.module
                guard !declaration.isExported, !declaration.isIgnored, !retained.contains(module),
                      analyzableModules.contains(module)
                else { continue }
                let visibleModules = visible(through: module)
                // Uses of a re-exported module that isn't analyzed can't be
                // seen, unless another import makes it visible too.
                let otherModules = imports.filter { $0.module != module }
                    .reduce(into: Set<String>()) { $0.formUnion(visible(through: $1.module)) }
                guard visibleModules.allSatisfy({ analyzableModules.contains($0) || otherModules.contains($0) }) else {
                    continue
                }
                let isUsed = declaration.kind == nil
                    ? !needed[path, default: []].isDisjoint(with: visibleModules)
                    : usesScopedImport(entry.scopedUSRs[declaration.modulePosition] ?? [], entry.referencedUSRs)
                guard !isUsed,
                      entry.modules.allSatisfy({ leaked[$0, default: []].isDisjoint(with: visibleModules) })
                else { continue }
                findings.append(Finding(
                    kind: .unusedImport,
                    declarationKind: .import,
                    name: declaration.name,
                    location: SourceLocation(file: path, line: declaration.range.start.line, column: declaration.range.start.column),
                    modules: Array(entry.modules),
                    usrs: []
                ))
            }
        }
        return findings
    }

    // MARK: - Collecting uses

    private func collectUses() -> [String: FileUses] {
        var uses: [String: FileUses] = [:]
        for file in files where file.unit.language == .swift {
            let path = file.unit.file
            let imports = syntax[path]?.imports ?? []
            let importsEnd = imports.map(\.range.end).max()
            var entry = uses[path, default: FileUses()]
            entry.modules.insert(file.unit.module)
            for occurrence in file.occurrences {
                let position = Position(line: occurrence.line, column: occurrence.column)
                if let importsEnd, position < importsEnd,
                   let declaration = imports.first(where: { $0.range.contains(position) }) {
                    if occurrence.symbol.kind == .module {
                        if position == declaration.modulePosition {
                            entry.compiledImports.insert(position)
                        }
                    } else {
                        entry.scopedUSRs[declaration.modulePosition, default: []].insert(occurrence.symbol.usr)
                    }
                    continue
                }
                if occurrence.symbol.kind == .module {
                    entry.qualifiedModules.insert(occurrence.symbol.name)
                    continue
                }
                // Not only references: an implicit protocol witness, for
                // example, is an occurrence of a default implementation.
                entry.referencedUSRs.insert(occurrence.symbol.usr)
                for relation in occurrence.relations {
                    entry.referencedUSRs.insert(relation.symbol.usr)
                }
            }
            uses[path] = entry
        }
        return uses
    }

    private func compiledImports(of path: String, uses: FileUses) -> [ImportSyntaxInfo] {
        (syntax[path]?.imports ?? []).filter { uses.compiledImports.contains($0.modulePosition) }
    }

    private func modules(of usr: String) -> Set<String>? {
        if let id = builder.resolve(usr) {
            return builder.graph[id].modules
        }
        return auxiliaryModules[usr]
    }

    /// Modules that declare conformances in extensions, by the USRs of the extended type.
    private func conformanceModules() -> [String: Set<String>] {
        var extendedTypes: [String: String] = [:]
        var conformingExtensions: Set<String> = []
        for file in files + auxiliaryFiles where file.unit.language == .swift {
            for occurrence in file.occurrences where occurrence.roles.contains(.reference) {
                for relation in occurrence.relations {
                    if relation.roles.contains(.extendedBy) {
                        extendedTypes[relation.symbol.usr] = occurrence.symbol.usr
                    }
                    if relation.roles.contains(.baseOf), relation.symbol.kind == .extension {
                        conformingExtensions.insert(relation.symbol.usr)
                    }
                }
            }
        }

        var result: [String: Set<String>] = [:]
        for ext in conformingExtensions {
            guard let type = extendedTypes[ext], let extensionModules = modules(of: ext) else { continue }
            for usr in builder.resolve(type).map({ builder.graph[$0].usrs }) ?? [type] {
                result[usr, default: []].formUnion(extensionModules)
            }
        }
        return result
    }

    /// The declarations that the declaration of `usr` is nested in, looking
    /// through extensions to the extended types.
    private func enclosingDeclarations(of usr: String) -> [Declaration.ID] {
        var result: [Declaration.ID] = []
        var current = builder.resolve(usr).flatMap { builder.graph[$0].parent }
        while let id = current {
            if builder.graph[id].kind == .extension {
                current = builder.extendedType[id]
                continue
            }
            result.append(id)
            current = builder.graph[id].parent
        }
        return result
    }

    /// Whether the file uses a declaration that `import struct Module.Name`
    /// imports, or one of its members.
    private func usesScopedImport(_ imported: Set<String>, _ referenced: Set<String>) -> Bool {
        // Without the imported declaration, its uses can't be told apart.
        guard !imported.isEmpty else { return true }
        if !imported.isDisjoint(with: referenced) { return true }
        let importedIDs = Set(imported.compactMap(builder.resolve))
        return referenced.contains { usr in
            enclosingDeclarations(of: usr).contains(where: importedIDs.contains)
        }
    }
}
