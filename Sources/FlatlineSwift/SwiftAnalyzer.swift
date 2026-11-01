import FlatlineCore
import Foundation
import IndexStore

public struct AnalysisResult: Sendable {
    public struct Statistics: Sendable {
        public var modules = 0
        public var files = 0
        public var declarations = 0
        public var unreadableRecords = 0
        public var unparseableFiles = 0
    }

    public let findings: [Finding]
    public let statistics: Statistics
    /// Requested explanations of why declarations are or aren't used.
    public let explanations: [String]
}

/// Finds unused Swift code from an index store produced by building the project.
public struct SwiftAnalyzer: Sendable {
    public let configuration: Configuration
    public let projectRoot: String
    public let logger: Logger
    /// Modules known to be test modules (in addition to those importing XCTest or Testing).
    public var testModules: Set<String> = []
    /// Names of declarations to explain the retention of.
    public var explain: [String] = []

    public init(configuration: Configuration, projectRoot: String, logger: Logger) {
        self.configuration = configuration
        self.projectRoot = projectRoot
        self.logger = logger
    }

    public func analyze(stores: [IndexStore]) throws -> AnalysisResult {
        var statistics = AnalysisResult.Statistics()

        var selector = UnitSelector(projectRoot: projectRoot)
        selector.excludedModules = Set(configuration.excludeTargets)
        selector.excludeTests = configuration.excludeTests
        selector.testModules = testModules
        selector.indexExclude = try configuration.indexExclude.map(Glob.init)
        let units = try selector.select(from: stores, logger: logger)
        guard !units.isEmpty else {
            throw FlatlineError(
                "the index store has no units for files in \(projectRoot). "
                    + "Make sure the project was built with indexing enabled, or pass --index-store-path."
            )
        }
        statistics.modules = Set(units.map(\.module)).count
        statistics.files = Set(units.map(\.file)).count
        logger.info("Analyzing \(statistics.files) files in \(statistics.modules) modules")
        logger.debug("Modules: \(Set(units.map(\.module)).sorted().joined(separator: ", "))")

        // Read index records and parse sources concurrently.
        let files = units.concurrentMap { unit -> IndexedFile? in
            do {
                return IndexedFile(unit: unit, occurrences: try stores[unit.storeIndex].occurrences(inRecord: unit.recordName))
            } catch {
                logger.debug("Could not read the index record for \(unit.file): \(error)")
                return nil
            }
        }
        statistics.unreadableRecords = files.count { $0 == nil }

        let swiftFiles = Array(Set(units.filter { $0.language == .swift }.map(\.file))).sorted()
        let parsed = swiftFiles.concurrentMap { path -> FileSyntaxInfo? in
            do {
                return try SyntaxCollector.collect(path: path)
            } catch {
                logger.debug("Could not read \(path): \(error)")
                return nil
            }
        }
        statistics.unparseableFiles = parsed.count { $0 == nil }
        let syntax = Dictionary(uniqueKeysWithValues: parsed.compactMap { $0.map { ($0.path, $0) } })

        let builder = SwiftGraphBuilder(configuration: configuration, syntax: syntax)
        builder.build(files.compactMap { $0 })
        statistics.declarations = builder.graph.declarations.count

        let resourceClassNames = ResourceScanner.classNames(
            in: projectRoot,
            exclude: try configuration.indexExclude.map(Glob.init)
        )
        builder.applyRetentionRules(
            projectRoot: projectRoot,
            resourceClassNames: resourceClassNames,
            retainFiles: try configuration.retainFiles.map(Glob.init)
        )
        builder.graph.computeReachability()

        let filter = ReportFilter(
            projectRoot: projectRoot,
            modules: Set(configuration.targets),
            include: try configuration.reportInclude.map(Glob.init),
            exclude: try configuration.reportExclude.map(Glob.init)
        )
        let findings = builder.findings(filter: filter)
        let explanations = explain.flatMap { builder.explain($0, projectRoot: projectRoot) }
        return AnalysisResult(findings: findings, statistics: statistics, explanations: explanations)
    }
}

extension SwiftGraphBuilder {
    /// Describes, for each declaration named `name`, the chain of uses that keeps it alive.
    func explain(_ name: String, projectRoot: String) -> [String] {
        let matches = graph.declarations.filter {
            !$0.isImplicit && ($0.name == name || $0.name.hasPrefix(name + "("))
        }
        guard !matches.isEmpty else {
            return ["No declaration named '\(name)' was found."]
        }
        return matches.map { declaration in
            var lines = ["\(declaration.kind.displayName) '\(declaration.name)' at \(describe(declaration.id, projectRoot))"]
            var current = declaration.id
            var visited: Set<Declaration.ID> = []
            while visited.insert(current).inserted {
                guard let reason = graph.retentionReason(for: current) else {
                    lines.append("  is unused")
                    break
                }
                switch reason {
                case let .root(why):
                    lines.append("  is used because \(why)")
                    current = -1
                case .referencedFromTopLevel:
                    lines.append("  is used by top-level code")
                    current = -1
                case let .referenced(by: source):
                    lines.append("  is used by \(graph[source].kind.displayName.lowercased()) '\(graph[source].name)' at \(describe(source, projectRoot))")
                    current = source
                case let .containsUsedMember(member):
                    lines.append("  contains used \(graph[member].kind.displayName.lowercased()) '\(graph[member].name)'")
                    current = member
                case let .rule(why, requirements):
                    let names = requirements.map { "'\(graph[$0].name)'" }.joined(separator: " and ")
                    lines.append("  is used because \(why) (\(names))")
                    current = requirements.first ?? -1
                }
                if current < 0 { break }
            }
            return lines.joined(separator: "\n")
        }
    }

    private func describe(_ id: Declaration.ID, _ projectRoot: String) -> String {
        let location = graph[id].location
        return "\(Paths.relative(location.file, to: projectRoot)):\(location.line):\(location.column)"
    }
}
