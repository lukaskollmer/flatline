import ArgumentParser
import FlatlineCore
import FlatlineProject
import FlatlineSwift
import Foundation
import IndexStore

extension OutputFormat: ExpressibleByArgument {}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build the project and report unused code.",
        discussion: """
        Options can also be set in .flatline.yml in the current directory (an existing \
        .periphery.yml is read too). Command-line options override the file.

        Arguments after `--` are passed to `swift build` or `xcodebuild`, e.g.
          flatline scan --schemes App -- -destination 'generic/platform=iOS Simulator'

        Exit status: 0 on success, 1 if --strict is set and there are results, 2 on errors.
        """
    )

    // MARK: Project

    @Option(help: "Path to the configuration file. (default: .flatline.yml)")
    var config: String?

    @Option(help: "The .xcworkspace, .xcodeproj, or Swift package directory to analyze.")
    var project: String?

    @Option(help: "Xcode schemes to build (comma-separated or repeated).")
    var schemes: [String] = []

    @Option(help: "Only report results in these modules.")
    var targets: [String] = []

    @Option(help: "Leave these modules out of the analysis entirely.")
    var excludeTargets: [String] = []

    @Flag(inversion: .prefixedNo, help: "Don't build or analyze test targets.")
    var excludeTests: Bool?

    @Flag(inversion: .prefixedNo, help: "Use the existing index store instead of building.")
    var skipBuild: Bool?

    @Flag(inversion: .prefixedNo, help: "Clean before building.")
    var cleanBuild: Bool?

    @Option(help: "Index store to read (repeatable). Detected automatically by default.")
    var indexStorePath: [String] = []

    @Option(help: "Derived data directory for Xcode builds.")
    var derivedDataPath: String?

    @Option(help: "Path to libIndexStore. Detected from the active toolchain by default.")
    var indexStoreLibrary: String?

    @Argument(parsing: .postTerminator, help: "Arguments for swift build or xcodebuild.")
    var buildArguments: [String] = []

    @Option(
        name: .customLong("variant"),
        parsing: .unconditionalSingleValue,
        help: ArgumentHelp(
            "Build arguments of a variant, e.g. --variant '--traits Postgres' (repeatable).",
            discussion: "Each variant is built separately; code is unused only if it's unused in all of them."
        )
    )
    var variants: [String] = []

    // MARK: Retention

    @Flag(inversion: .prefixedNo, help: "Treat public declarations as used (for libraries).")
    var retainPublic: Bool?

    @Flag(inversion: .prefixedNo, help: "Treat @objc, @IBAction, @IBOutlet, … declarations as used. (default: on)")
    var retainObjcAnnotated: Bool?

    @Flag(inversion: .prefixedNo, help: "Treat everything visible to Objective-C as used.")
    var retainObjcAccessible: Bool?

    @Option(help: "Treat declarations in files matching these globs as used.")
    var retainFiles: [String] = []

    @Flag(inversion: .prefixedNo, help: "Count #Preview and PreviewProvider content as a use. (default: on)")
    var retainSwiftUIPreviews: Bool?

    @Flag(inversion: .prefixedNo, help: "Treat stored properties of Decodable types as used.")
    var retainCodableProperties: Bool?

    @Flag(inversion: .prefixedNo, help: "Treat stored properties of Encodable types as used. (default: on)")
    var retainEncodableProperties: Bool?

    @Flag(inversion: .prefixedNo, help: "Don't report properties that are assigned but never read.")
    var retainAssignOnlyProperties: Bool?

    @Option(help: "Property types that may be assign-only, e.g. AnyCancellable.")
    var retainAssignOnlyPropertyTypes: [String] = []

    @Option(help: "External protocols that refine Encodable.")
    var externalEncodableProtocols: [String] = []

    @Option(help: "External protocols that refine Codable or Decodable.")
    var externalCodableProtocols: [String] = []

    @Option(help: "External test case base classes, besides XCTestCase.")
    var externalTestCaseClasses: [String] = []

    @Flag(inversion: .prefixedNo, help: "Don't report unused function parameters.")
    var disableUnusedParameterAnalysis: Bool?

    @Flag(inversion: .prefixedNo, help: "Don't report public declarations that are only used in their own module.")
    var disableRedundantPublicAnalysis: Bool?

    // MARK: Reporting

    @Option(help: "Don't report results in files matching these globs.")
    var reportExclude: [String] = []

    @Option(help: "Only report results in files matching these globs.")
    var reportInclude: [String] = []

    @Option(help: "Don't analyze files matching these globs at all.")
    var indexExclude: [String] = []

    @Option(help: "Output format.")
    var format: OutputFormat?

    @Flag(inversion: .prefixedNo, help: "Print paths relative to the project root.")
    var relativeResults: Bool?

    @Flag(inversion: .prefixedNo, help: "Exit with status 1 if there are results.")
    var strict: Bool?

    @Option(help: "Don't report results recorded in this baseline file.")
    var baseline: String?

    @Option(help: "Record the results to this baseline file.")
    var writeBaseline: String?

    @Option(help: "Explain why a declaration is or isn't used (repeatable).")
    var explain: [String] = []

    @Flag(name: .shortAndLong, help: "Show build output and details.")
    var verbose = false

    @Flag(name: .shortAndLong, help: "Only print results.")
    var quiet = false

    func run() throws {
        let workingDirectory = Paths.canonical(FileManager.default.currentDirectoryPath)
        var logger = Logger(level: verbose ? .verbose : quiet ? .quiet : .normal)
        do {
            let (fileConfiguration, file) = try ConfigurationLoader.load(path: config, directory: workingDirectory, logger: logger)
            let configuration = merged(into: fileConfiguration)
            if file != nil, configuration.verbose != verbose || configuration.quiet != quiet {
                logger = Logger(level: configuration.verbose ? .verbose : configuration.quiet ? .quiet : .normal)
            }
            if let file {
                logger.debug("Read configuration from \(file)")
            }
            let findingCount = try scan(configuration: configuration, workingDirectory: workingDirectory, logger: logger)
            if configuration.strict, findingCount > 0 {
                throw ExitCode(1)
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            logger.error("\(error)")
            throw ExitCode(2)
        }
    }

    private func scan(configuration: Configuration, workingDirectory: String, logger: Logger) throws -> Int {
        let start = Date()
        let kind = try ProjectDetector.detect(configuration: configuration, directory: workingDirectory)
        let driver = ProjectDetector.driver(for: kind, configuration: configuration, workingDirectory: workingDirectory)
        let project = try driver.prepare(configuration: configuration, logger: logger)
        let root = Paths.canonical(project.root)

        let libraryPath = try Toolchain.indexStoreLibrary(explicit: configuration.indexStoreLibrary)
        logger.debug("Using \(libraryPath)")
        let library = try IndexStoreLibrary(path: libraryPath)
        let variants = try project.indexStores.map { paths in
            try paths.map { path in
                logger.debug("Reading index store \(path)")
                do {
                    return try IndexStore(path: path, library: library)
                } catch {
                    throw FlatlineError("could not open the index store at \(path): \(error)")
                }
            }
        }

        var analyzer = SwiftAnalyzer(configuration: configuration, projectRoot: root, logger: logger)
        analyzer.testModules = project.testModules
        analyzer.explain = explain
        let result = try analyzer.analyze(variants: variants)
        let statistics = result.statistics
        logger.debug(
            "Indexed \(statistics.declarations) declarations in \(statistics.files) files"
                + (statistics.unreadableRecords > 0 ? ", \(statistics.unreadableRecords) unreadable index records" : "")
                + (statistics.unparseableFiles > 0 ? ", \(statistics.unparseableFiles) unreadable source files" : "")
        )

        var findings = result.findings
        if let path = configuration.writeBaseline {
            try Baseline(findings: findings).write(to: Paths.absolute(path, base: workingDirectory))
            logger.info("Wrote \(findings.count) results to the baseline \(path)")
        }
        if let path = configuration.baseline {
            let baseline = try Baseline.load(from: Paths.absolute(path, base: workingDirectory))
            let total = findings.count
            findings = baseline.filter(findings)
            logger.debug("The baseline suppressed \(total - findings.count) results")
        }

        for explanation in result.explanations {
            FileHandle.standardError.write(Data((explanation + "\n").utf8))
        }

        let context = OutputContext(projectRoot: root, relativePaths: configuration.relativeResults)
        let output = try configuration.format.formatter().format(findings, context: context)
        if !output.isEmpty || configuration.format != .xcode {
            FileHandle.standardOutput.write(Data((output + "\n").utf8))
        }

        let duration = String(format: "%.1f", Date().timeIntervalSince(start))
        if findings.isEmpty {
            logger.info("No unused code found (\(duration)s)")
        } else {
            let counts = Dictionary(grouping: findings, by: \.kind).mapValues(\.count)
            let summary = Finding.Kind.allCases.compactMap { kind in
                counts[kind].map { "\($0) \(kind.summaryName(count: $0))" }
            }.joined(separator: ", ")
            logger.info("Found \(findings.count) result\(findings.count == 1 ? "" : "s"): \(summary) (\(duration)s)")
        }
        return findings.count
    }

    /// Applies command-line options on top of the configuration file.
    private func merged(into base: Configuration) -> Configuration {
        var c = base
        func list(_ values: [String]) -> [String] {
            values.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        }
        func set<T>(_ keyPath: WritableKeyPath<Configuration, T>, _ value: T?) {
            if let value { c[keyPath: keyPath] = value }
        }
        func set<T>(_ keyPath: WritableKeyPath<Configuration, T?>, _ value: T?) {
            if let value { c[keyPath: keyPath] = value }
        }
        func set(_ keyPath: WritableKeyPath<Configuration, [String]>, _ values: [String]) {
            if !values.isEmpty { c[keyPath: keyPath] = list(values) }
        }

        set(\.project, project)
        set(\.schemes, schemes)
        set(\.targets, targets)
        set(\.excludeTargets, excludeTargets)
        set(\.excludeTests, excludeTests)
        set(\.skipBuild, skipBuild)
        set(\.cleanBuild, cleanBuild)
        set(\.indexStorePath, indexStorePath)
        set(\.derivedDataPath, derivedDataPath)
        set(\.indexStoreLibrary, indexStoreLibrary)
        if !buildArguments.isEmpty { c.buildArguments = buildArguments }
        if !variants.isEmpty { c.buildVariants = variants.map { BuildVariant(commandLine: $0) } }
        set(\.retainPublic, retainPublic)
        set(\.retainObjcAnnotated, retainObjcAnnotated)
        set(\.retainObjcAccessible, retainObjcAccessible)
        set(\.retainFiles, retainFiles)
        set(\.retainSwiftUIPreviews, retainSwiftUIPreviews)
        set(\.retainCodableProperties, retainCodableProperties)
        set(\.retainEncodableProperties, retainEncodableProperties)
        set(\.retainAssignOnlyProperties, retainAssignOnlyProperties)
        set(\.retainAssignOnlyPropertyTypes, retainAssignOnlyPropertyTypes)
        set(\.externalEncodableProtocols, externalEncodableProtocols)
        set(\.externalCodableProtocols, externalCodableProtocols)
        set(\.externalTestCaseClasses, externalTestCaseClasses)
        set(\.disableUnusedParameterAnalysis, disableUnusedParameterAnalysis)
        set(\.disableRedundantPublicAnalysis, disableRedundantPublicAnalysis)
        set(\.reportExclude, reportExclude)
        set(\.reportInclude, reportInclude)
        set(\.indexExclude, indexExclude)
        set(\.format, format)
        set(\.relativeResults, relativeResults)
        set(\.strict, strict)
        set(\.baseline, baseline)
        set(\.writeBaseline, writeBaseline)
        if verbose { c.verbose = true }
        if quiet { c.quiet = true }
        return c
    }
}

extension Finding.Kind {
    func summaryName(count: Int) -> String {
        let plural = count != 1
        return switch self {
        case .unused: "unused"
        case .redundantProtocol: plural ? "redundant protocols" : "redundant protocol"
        case .assignOnlyProperty: plural ? "assign-only properties" : "assign-only property"
        case .unusedParameter: plural ? "unused parameters" : "unused parameter"
        case .redundantPublicAccessibility: "redundant public"
        }
    }
}
