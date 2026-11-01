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
    public func select(from variants: [[IndexStore]], logger: Logger) throws -> [SourceUnit] {
        let root = Paths.canonical(projectRoot)
        var candidates: [String: (unit: IndexUnit, store: Int, file: String)] = [:]
        var canonicalPaths: [String: String?] = [:]

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

                let resolved = canonicalPaths[mainFile] ?? {
                    let path = Paths.canonical(mainFile)
                    let keep = FileManager.default.fileExists(atPath: path) && isProjectFile(path, root: root)
                    canonicalPaths[mainFile] = keep ? path : nil
                    return keep ? path : nil
                }()
                guard let file = resolved else { continue }

                let key = "\(variant)\u{0}\(unit.moduleName)\u{0}\(file)"
                if let existing = candidates[key], existing.unit.modificationTime >= unit.modificationTime {
                    continue
                }
                candidates[key] = (unit, storeIndex, file)
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

        var units: [SourceUnit] = []
        var heuristicTestModules: Set<String> = []
        for (unit, _, _) in candidates.values where unit.dependencies.contains(where: {
            $0.moduleName == "XCTest" || $0.moduleName == "Testing"
        }) {
            heuristicTestModules.insert(unit.moduleName)
        }
        let testModules = testModules.union(heuristicTestModules)

        // Variants that compiled a file identically share its record; read it once.
        var seenRecords: Set<String> = []
        for (unit, storeIndex, file) in candidates.values {
            let isTest = testModules.contains(unit.moduleName)
            if excludeTests, isTest { continue }
            guard let record = unit.dependencies.first(where: {
                $0.kind == .record && Paths.canonical($0.filePath) == file
            }) ?? unit.dependencies.first(where: { $0.kind == .record }) else { continue }
            guard seenRecords.insert("\(unit.moduleName)\u{0}\(file)\u{0}\(record.name)").inserted else { continue }
            units.append(SourceUnit(
                file: file,
                module: unit.moduleName,
                language: unit.providerIdentifier == "swift" ? .swift : .clang,
                storeIndex: storeIndex,
                recordName: record.name
            ))
        }
        return units.sorted { ($0.file, $0.module, $0.storeIndex) < ($1.file, $1.module, $1.storeIndex) }
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
