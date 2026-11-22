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
/// break that file. Generated and excluded files of the module count too.
///
/// Each build variant, and each module a file is compiled into, has its own
/// imports and uses, so an import is reported only if it can be removed in
/// every variant and module that compiles it.
///
/// Only imports of the project's own modules are analyzed. For other modules
/// (the SDK, dependencies), the index doesn't tell which declarations they hold.
struct ImportAnalysis {
    private let builder: SwiftGraphBuilder
    private let configuration: Configuration
    /// Parsed project and auxiliary files.
    private let syntax: [String: FileSyntaxInfo]
    private let files: [IndexedFile]
    /// Generated or excluded files of the project's modules. Their uses
    /// count, but their imports aren't reported.
    private let auxiliaryFiles: [IndexedFile]
    /// Modules whose declarations are all known: Swift only, every file read and parsed.
    let analyzableModules: Set<String>
    /// Modules with a Swift file that couldn't be read or parsed, so their uses are unknown.
    private let modulesWithUnknownFiles: Set<String>
    /// The module that declares each USR. Unlike the graph, which merges the
    /// copies of a file compiled into several modules, a USR names one copy.
    private let declarationModules: [String: Set<String>]

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
        for (unit, file) in files + auxiliaryFiles {
            if unit.language == .clang {
                incomplete.insert(unit.module)
            } else if file == nil || syntax[unit.file] == nil {
                unknown.insert(unit.module)
            } else {
                swiftModules.insert(unit.module)
            }
        }
        analyzableModules = swiftModules.subtracting(incomplete).subtracting(unknown)
        modulesWithUnknownFiles = unknown

        var declarationModules: [String: Set<String>] = [:]
        for case let (unit, file?) in files + auxiliaryFiles {
            for occurrence in file.occurrences where !occurrence.roles.isDisjoint(with: [.definition, .declaration]) {
                declarationModules[occurrence.symbol.usr, default: []].insert(unit.module)
            }
        }
        self.declarationModules = declarationModules
    }

    /// One source file as compiled into one module in one build variant.
    private struct FileKey: Hashable {
        let path: String
        let module: String
        let variant: Int
    }

    /// What a file imports and uses in one compilation.
    private struct FileUses {
        /// Module positions of the imports that were compiled.
        var compiledImports: Set<Position> = []
        var referencedUSRs: Set<String> = []
        /// Modules named in qualified references like `Module.Type`.
        var qualifiedModules: Set<String> = []
        /// Declarations named by imports of single declarations, by module position.
        var scopedUSRs: [Position: Set<String>] = [:]

        mutating func merge(_ other: FileUses) {
            compiledImports.formUnion(other.compiledImports)
            referencedUSRs.formUnion(other.referencedUSRs)
            qualifiedModules.formUnion(other.qualifiedModules)
            scopedUSRs.merge(other.scopedUSRs) { $0.union($1) }
        }
    }

    /// The modules a file needs, other than its own.
    private struct Needs {
        /// Modules of the declarations it refers to, and modules that may
        /// provide conformances it relies on.
        var all: Set<String> = []
        /// Modules of extension members and conformances it relies on. Any
        /// import of such a module provides them, even of a single declaration.
        var throughExtensions: Set<String> = []
    }

    func findings(filter: ReportFilter) -> [Finding] {
        let uses = collectUses()
        let conformances = conformanceModules()

        var needs: [FileKey: Needs] = [:]
        for (key, entry) in uses {
            var result = Needs()
            result.all = entry.qualifiedModules
            for usr in entry.referencedUSRs {
                let declarationModules = modules(of: usr) ?? []
                result.all.formUnion(declarationModules)
                if isDeclaredInExtension(usr) {
                    result.throughExtensions.formUnion(declarationModules)
                }
                var conformingModules = conformances[usr] ?? []
                for type in enclosingDeclarations(of: usr) {
                    for usr in builder.graph[type].usrs {
                        conformingModules.formUnion(conformances[usr] ?? [])
                    }
                }
                result.all.formUnion(conformingModules)
                result.throughExtensions.formUnion(conformingModules)
            }
            result.all.remove(key.module)
            result.throughExtensions.remove(key.module)
            needs[key] = result
        }

        // Re-exports, by variant and exporting module. A re-export of a single
        // declaration (`@_exported import struct Module.Name`) makes the
        // module's extension members visible, but not the whole module.
        struct ExportKey: Hashable {
            let variant: Int
            let module: String
        }
        var exports: [ExportKey: (wholeModules: Set<String>, declarations: Set<String>)] = [:]
        for (key, entry) in uses {
            for declaration in compiledImports(of: key.path, uses: entry) where declaration.isExported {
                let exportKey = ExportKey(variant: key.variant, module: key.module)
                if declaration.kind == nil {
                    exports[exportKey, default: ([], [])].wholeModules.insert(declaration.module)
                } else {
                    exports[exportKey, default: ([], [])].declarations.insert(declaration.module)
                }
            }
        }
        var closures: [ExportKey: (wholeModules: Set<String>, any: Set<String>)] = [:]
        /// The modules that importing `module` makes visible in `variant`:
        /// either the modules it makes visible as a whole, or every module it
        /// makes any declaration of visible.
        func visible(through module: String, in variant: Int, wholeModulesOnly: Bool) -> Set<String> {
            let key = ExportKey(variant: variant, module: module)
            if let cached = closures[key] {
                return wholeModulesOnly ? cached.wholeModules : cached.any
            }
            func closure(_ edges: (ExportKey) -> Set<String>) -> Set<String> {
                var result: Set<String> = [module]
                var queue = [module]
                while let current = queue.popLast() {
                    for exported in edges(ExportKey(variant: variant, module: current)) where result.insert(exported).inserted {
                        queue.append(exported)
                    }
                }
                return result
            }
            let wholeModules = closure { exports[$0]?.wholeModules ?? [] }
            let any = closure { exports[$0].map { $0.wholeModules.union($0.declarations) } ?? [] }
            closures[key] = (wholeModules, any)
            return wholeModulesOnly ? wholeModules : any
        }
        func visible(through imports: [ImportSyntaxInfo], in variant: Int, wholeModulesOnly: Bool) -> Set<String> {
            imports.reduce(into: Set<String>()) {
                $0.formUnion(visible(through: $1.module, in: variant, wholeModulesOnly: wholeModulesOnly))
            }
        }

        // Modules that a file uses without importing them, by variant and by
        // the module the file is in: imports of them elsewhere in that module
        // are load-bearing.
        var leaked: [ExportKey: Set<String>] = [:]
        for (key, entry) in uses {
            let imported = visible(through: compiledImports(of: key.path, uses: entry), in: key.variant, wholeModulesOnly: false)
            let missing = needs[key, default: Needs()].all.subtracting(imported)
            leaked[ExportKey(variant: key.variant, module: key.module), default: []].formUnion(missing)
        }

        /// Whether `declaration` can be removed from the file in one variant.
        func isRemovable(_ declaration: ImportSyntaxInfo, from key: FileKey) -> Bool {
            let entry = uses[key, default: FileUses()]
            let fileNeeds = needs[key, default: Needs()]
            let visibleModules = visible(through: declaration.module, in: key.variant, wholeModulesOnly: false)
            // Uses of a re-exported module that isn't analyzed can't be seen,
            // unless other imports make the whole module visible too.
            let otherImports = compiledImports(of: key.path, uses: entry).filter {
                $0.module != declaration.module && $0.kind == nil
            }
            let otherModules = visible(through: otherImports, in: key.variant, wholeModulesOnly: true)
            guard visibleModules.allSatisfy({ analyzableModules.contains($0) || otherModules.contains($0) }) else {
                return false
            }
            let isUsed = declaration.kind == nil
                ? !fileNeeds.all.isDisjoint(with: visibleModules)
                : !fileNeeds.throughExtensions.isDisjoint(with: visibleModules)
                    || usesScopedImport(entry.scopedUSRs[declaration.modulePosition] ?? [], entry.referencedUSRs)
            let leakedModules = leaked[ExportKey(variant: key.variant, module: key.module), default: []]
            return !isUsed && leakedModules.isDisjoint(with: visibleModules)
        }

        let retained = Set(configuration.retainUnusedImportedModules)
        let auxiliaryPaths = Set(auxiliaryFiles.map(\.unit.file))
        let keysByPath = Dictionary(grouping: uses.keys.filter { !auxiliaryPaths.contains($0.path) }, by: \.path)
        var findings: [Finding] = []
        for (path, keys) in keysByPath {
            let modules = Set(keys.map(\.module))
            guard let fileSyntax = syntax[path], !fileSyntax.ignoresAll,
                  modules.isDisjoint(with: modulesWithUnknownFiles),
                  filter.includes(file: path, modules: modules)
            else { continue }
            for declaration in fileSyntax.imports {
                guard !declaration.isExported, !declaration.isIgnored, !retained.contains(declaration.module),
                      analyzableModules.contains(declaration.module)
                else { continue }
                let compiledIn = keys.filter { uses[$0]?.compiledImports.contains(declaration.modulePosition) == true }
                guard !compiledIn.isEmpty, compiledIn.allSatisfy({ isRemovable(declaration, from: $0) }) else { continue }
                findings.append(Finding(
                    kind: .unusedImport,
                    declarationKind: .import,
                    name: declaration.name,
                    location: SourceLocation(file: path, line: declaration.range.start.line, column: declaration.range.start.column),
                    modules: Array(modules),
                    usrs: []
                ))
            }
        }
        return findings
    }

    // MARK: - Collecting uses

    private func collectUses() -> [FileKey: FileUses] {
        var uses: [FileKey: FileUses] = [:]
        for file in files + auxiliaryFiles where file.unit.language == .swift {
            let entry = fileUses(of: file)
            for variant in file.unit.variants {
                uses[FileKey(path: file.unit.file, module: file.unit.module, variant: variant), default: FileUses()].merge(entry)
            }
        }
        return uses
    }

    private func fileUses(of file: IndexedFile) -> FileUses {
        let imports = syntax[file.unit.file]?.imports ?? []
        let importsEnd = imports.map(\.range.end).max()
        var entry = FileUses()
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
        return entry
    }

    private func compiledImports(of path: String, uses: FileUses) -> [ImportSyntaxInfo] {
        (syntax[path]?.imports ?? []).filter { uses.compiledImports.contains($0.modulePosition) }
    }

    private func modules(of usr: String) -> Set<String>? {
        declarationModules[usr] ?? builder.resolve(usr).map { builder.graph[$0].modules }
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

    /// Whether `usr` is declared in an extension, directly or nested. A
    /// declaration that isn't in the graph, e.g. of an auxiliary file, might be.
    private func isDeclaredInExtension(_ usr: String) -> Bool {
        guard let id = builder.resolve(usr) else { return declarationModules[usr] != nil }
        var current = builder.graph[id].parent
        while let parent = current {
            if builder.graph[parent].kind == .extension { return true }
            current = builder.graph[parent].parent
        }
        return false
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
