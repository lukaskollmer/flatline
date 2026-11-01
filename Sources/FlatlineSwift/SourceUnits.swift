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

/// Chooses the units of an index store that belong to the project.
///
/// An index store accumulates units across builds, so it can hold several
/// units for one file (from other configurations or earlier builds). For each
/// file and module, the most recently written unit wins.
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

    public func select(from stores: [IndexStore], logger: Logger) throws -> [SourceUnit] {
        let root = Paths.canonical(projectRoot)
        var candidates: [String: (unit: IndexUnit, store: Int, file: String)] = [:]
        var canonicalPaths: [String: String?] = [:]

        for (storeIndex, store) in stores.enumerated() {
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

                let key = "\(unit.moduleName)\u{0}\(file)"
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

        for (unit, storeIndex, file) in candidates.values {
            let isTest = testModules.contains(unit.moduleName)
            if excludeTests, isTest { continue }
            guard let record = unit.dependencies.first(where: {
                $0.kind == .record && Paths.canonical($0.filePath) == file
            }) ?? unit.dependencies.first(where: { $0.kind == .record }) else { continue }
            units.append(SourceUnit(
                file: file,
                module: unit.moduleName,
                language: unit.providerIdentifier == "swift" ? .swift : .clang,
                storeIndex: storeIndex,
                recordName: record.name
            ))
        }
        return units.sorted { ($0.file, $0.module) < ($1.file, $1.module) }
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
