import FlatlineCore
import Foundation
import IndexStore

/// One indexed source file of one module.
public struct SourceUnit: Sendable {
    public enum Language: Sendable {
        case swift
        /// C, Objective-C and C++: only their references to Swift code are used.
        case clang
    }

    public let file: String
    public let module: String
    public let language: Language
    let storeIndex: Int
    let recordName: String
    /// The build variants that compiled the file to this record.
    public internal(set) var variants: Set<Int>
}

/// The units chosen from index stores.
public struct UnitSelection: Sendable {
    /// The project files to analyze.
    public var units: [SourceUnit]
    /// Other files compiled into the project's modules: generated sources, or
    /// files excluded with `index_exclude`. They aren't analyzed; their
    /// declarations only tell which module a referenced declaration is in.
    public var auxiliaryUnits: [SourceUnit]
}

/// Chooses the units of index stores that belong to the project.
///
/// An index store accumulates units across builds, so it can hold several
/// units for one file (from other configurations or earlier builds). Within
/// one build variant, the most recently written unit of each file and module
/// wins. The units of different variants are all kept, so that code compiled
/// only in some variants is analyzed too.
public struct UnitSelector: Sendable {
    public var projectRoot: String
    public var excludedModules: Set<String> = []
    public var testModules: Set<String> = []
    public var excludeTests = false
    public var indexExclude: [Glob] = []

    /// Directories under the project root that hold third-party or generated sources.
    static let ignoredDirectories = [".build", "DerivedData", "SourcePackages", "Pods", "Carthage", ".swiftpm"]

    public init(projectRoot: String) {
        self.projectRoot = projectRoot
    }

    /// `variants` holds the index stores of each build variant;
    /// `SourceUnit.storeIndex` indexes into them flattened.
    public func select(from variants: [[IndexStore]], logger: Logger) throws -> UnitSelection {
        let root = Paths.canonical(projectRoot)
        typealias Candidate = (unit: IndexUnit, store: Int, file: String, variant: Int)
        var candidates: [String: Candidate] = [:]
        var otherCandidates: [String: Candidate] = [:]
        var classifications: [String: FileClass] = [:]
        func keepNewest(_ candidates: inout [String: Candidate], _ key: String, _ candidate: Candidate) {
            if let existing = candidates[key], existing.unit.modificationTime >= candidate.unit.modificationTime {
                return
            }
            candidates[key] = candidate
        }

        let stores = variants.enumerated().flatMap { variant, stores in stores.map { (variant, $0) } }
        for (storeIndex, (variant, store)) in stores.enumerated() {
            for name in store.unitNames() {
                let unit: IndexUnit
                do {
                    unit = try store.unit(named: name)
                } catch {
                    logger.debug("Skipping unreadable unit \(name): \(error)")
                    continue
                }
                guard !unit.isSystem, let mainFile = unit.mainFile, !mainFile.isEmpty,
                      unit.providerIdentifier == "swift" || unit.providerIdentifier == "clang",
                      !excludedModules.contains(unit.moduleName)
                else { continue }

                let classification = classifications[mainFile] ?? {
                    let path = Paths.canonical(mainFile)
                    let result: FileClass = !FileManager.default.fileExists(atPath: path)
                        ? .missing
                        : isProjectFile(path, root: root) ? .project(path) : .other(path)
                    classifications[mainFile] = result
                    return result
                }()
                let file: String
                switch classification {
                case .missing:
                    continue
                case let .project(path), let .other(path):
                    file = path
                }
                let key = "\(variant)\u{0}\(unit.moduleName)\u{0}\(file)"
                if case .project = classification {
                    keepNewest(&candidates, key, (unit, storeIndex, file, variant))
                } else {
                    keepNewest(&otherCandidates, key, (unit, storeIndex, file, variant))
                }
            }
        }

        let stale = Set(candidates.values.filter { candidate in
            let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.file)
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            return modified > candidate.unit.modificationTime
        }.map(\.file))
        if !stale.isEmpty {
            logger.warning(
                "\(stale.count) file\(stale.count == 1 ? " was" : "s were") modified after being indexed; "
                    + "results for \(stale.count == 1 ? "it" : "them") may be wrong. Build again (without --skip-build)."
            )
            for file in stale.sorted() {
                logger.debug("Stale index: \(file)")
            }
        }

        var heuristicTestModules: Set<String> = []
        for (unit, _, _, _) in candidates.values where unit.dependencies.contains(where: {
            $0.moduleName == "XCTest" || $0.moduleName == "Testing"
        }) {
            heuristicTestModules.insert(unit.moduleName)
        }
        let testModules = testModules.union(heuristicTestModules)

        // Variants that compiled a file identically share its record; read it once.
        func sourceUnits(_ candidates: some Sequence<Candidate>) -> [SourceUnit] {
            var units: [SourceUnit] = []
            var unitsByRecord: [String: Int] = [:]
            for (unit, storeIndex, file, variant) in candidates {
                guard let record = unit.dependencies.first(where: {
                    $0.kind == .record && Paths.canonical($0.filePath) == file
                }) ?? unit.dependencies.first(where: { $0.kind == .record }) else { continue }
                let key = "\(unit.moduleName)\u{0}\(file)\u{0}\(record.name)"
                if let index = unitsByRecord[key] {
                    units[index].variants.insert(variant)
                    continue
                }
                unitsByRecord[key] = units.count
                units.append(SourceUnit(
                    file: file,
                    module: unit.moduleName,
                    language: unit.providerIdentifier == "swift" ? .swift : .clang,
                    storeIndex: storeIndex,
                    recordName: record.name,
                    variants: [variant]
                ))
            }
            return units.sorted { ($0.file, $0.module, $0.storeIndex) < ($1.file, $1.module, $1.storeIndex) }
        }

        let units = sourceUnits(candidates.values.filter { !(excludeTests && testModules.contains($0.unit.moduleName)) })
        // Files outside the project, generated or excluded, that are compiled
        // into its modules (e.g. resource accessors or plugin output).
        let projectModules = Set(units.map(\.module))
        let auxiliaryUnits = sourceUnits(otherCandidates.values.filter { projectModules.contains($0.unit.moduleName) })
        return UnitSelection(units: units, auxiliaryUnits: auxiliaryUnits)
    }

    private enum FileClass {
        case project(String)
        /// Exists, but isn't a project file to analyze.
        case other(String)
        case missing
    }

    private func isProjectFile(_ path: String, root: String) -> Bool {
        guard Paths.isInside(path, root) else { return false }
        let relative = Paths.relative(path, to: root)
        let components = relative.split(separator: "/").dropLast()
        if components.contains(where: { Self.ignoredDirectories.contains(String($0)) }) {
            return false
        }
        return !indexExclude.contains { $0.matches(relative) || $0.matches(path) }
    }
}
