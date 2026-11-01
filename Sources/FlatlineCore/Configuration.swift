/// All settings, as read from `.flatline.yml` and overridden by command-line flags.
///
/// Keys use snake_case in YAML. Where Periphery had an equivalent option, the
/// key has the same name and meaning, so an existing `.periphery.yml` keeps working.
public struct Configuration: Codable, Sendable, Equatable {
    // MARK: Project

    /// `.xcworkspace`, `.xcodeproj`, or a directory containing `Package.swift`.
    public var project: String?
    /// Xcode schemes to build.
    public var schemes: [String] = []
    /// Modules to report results for. Empty means every module of the project.
    public var targets: [String] = []
    /// Modules to leave out of the analysis entirely.
    public var excludeTargets: [String] = []
    /// Skip building and analyzing test targets.
    public var excludeTests: Bool = false
    /// Extra arguments for `swift build` or `xcodebuild`.
    public var buildArguments: [String] = []
    /// Use an existing index store instead of building.
    public var skipBuild: Bool = false
    /// Clean before building.
    public var cleanBuild: Bool = false
    /// Index store directories to read. Detected automatically when empty.
    public var indexStorePath: [String] = []
    /// Derived data directory for Xcode builds.
    public var derivedDataPath: String?
    /// Path to libIndexStore. Detected from the active toolchain when unset.
    public var indexStoreLibrary: String?

    // MARK: Retention

    /// Treat `public` and `open` declarations as used (for libraries and frameworks).
    public var retainPublic: Bool = false
    /// Treat declarations marked `@objc`, `@objcMembers`, `@IBAction`, etc. as used.
    public var retainObjcAnnotated: Bool = true
    /// Treat everything exposed to Objective-C as used, including NSObject subclass members.
    public var retainObjcAccessible: Bool = false
    /// Treat every declaration in matching files as used.
    public var retainFiles: [String] = []
    /// Don't report unused parameters of protocol requirement implementations.
    public var retainUnusedProtocolFuncParams: Bool = false
    /// Treat `#Preview` and `PreviewProvider` content as a use.
    public var retainSwiftUIPreviews: Bool = true
    /// Treat all stored properties of `Decodable` types as used.
    public var retainCodableProperties: Bool = false
    /// Treat stored properties of `Encodable` types as used (they are read by `encode(to:)`).
    public var retainEncodableProperties: Bool = true
    /// Don't report properties that are assigned but never read.
    public var retainAssignOnlyProperties: Bool = false
    /// Property types that are commonly kept only to be retained, e.g. `AnyCancellable`.
    public var retainAssignOnlyPropertyTypes: [String] = Configuration.defaultAssignOnlyPropertyTypes
    /// External protocols that refine `Encodable`.
    public var externalEncodableProtocols: [String] = []
    /// External protocols that refine `Codable` or `Decodable`.
    public var externalCodableProtocols: [String] = []
    /// External base classes of test cases, besides `XCTestCase`.
    public var externalTestCaseClasses: [String] = []

    // MARK: Analyses

    public var disableUnusedParameterAnalysis: Bool = false
    public var disableRedundantPublicAnalysis: Bool = false

    // MARK: Reporting

    /// Don't report results in matching files.
    public var reportExclude: [String] = []
    /// Only report results in matching files.
    public var reportInclude: [String] = []
    /// Don't index matching files at all; their references don't count.
    public var indexExclude: [String] = []
    public var format: OutputFormat = .xcode
    /// Print paths relative to the project root.
    public var relativeResults: Bool = false
    /// Exit with a non-zero status when there are results.
    public var strict: Bool = false
    /// Suppress results recorded in this baseline file.
    public var baseline: String?
    /// Record the current results to this baseline file.
    public var writeBaseline: String?
    public var verbose: Bool = false
    public var quiet: Bool = false

    public static let defaultAssignOnlyPropertyTypes = [
        "AnyCancellable",
        "Set<AnyCancellable>",
        "[AnyCancellable]",
        "Cancellable",
        "NSKeyValueObservation",
        "NSObjectProtocol",
    ]

    public init() {}

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case project
        case workspace
        case schemes
        case targets
        case excludeTargets = "exclude_targets"
        case excludeTests = "exclude_tests"
        case buildArguments = "build_arguments"
        case skipBuild = "skip_build"
        case cleanBuild = "clean_build"
        case indexStorePath = "index_store_path"
        case derivedDataPath = "derived_data_path"
        case indexStoreLibrary = "index_store_library"
        case retainPublic = "retain_public"
        case retainObjcAnnotated = "retain_objc_annotated"
        case retainObjcAccessible = "retain_objc_accessible"
        case retainFiles = "retain_files"
        case retainUnusedProtocolFuncParams = "retain_unused_protocol_func_params"
        case retainSwiftUIPreviews = "retain_swift_ui_previews"
        case retainCodableProperties = "retain_codable_properties"
        case retainEncodableProperties = "retain_encodable_properties"
        case retainAssignOnlyProperties = "retain_assign_only_properties"
        case retainAssignOnlyPropertyTypes = "retain_assign_only_property_types"
        case externalEncodableProtocols = "external_encodable_protocols"
        case externalCodableProtocols = "external_codable_protocols"
        case externalTestCaseClasses = "external_test_case_classes"
        case disableUnusedParameterAnalysis = "disable_unused_parameter_analysis"
        case disableRedundantPublicAnalysis = "disable_redundant_public_analysis"
        case reportExclude = "report_exclude"
        case reportInclude = "report_include"
        case indexExclude = "index_exclude"
        case format
        case relativeResults = "relative_results"
        case strict
        case baseline
        case writeBaseline = "write_baseline"
        case verbose
        case quiet
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Configuration()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }

        // A single string is accepted wherever a list is expected.
        func list(_ key: CodingKeys, _ fallback: [String]) throws -> [String] {
            if let single = try? c.decodeIfPresent(String.self, forKey: key) {
                return [single]
            }
            return try value(key, fallback)
        }

        project = try c.decodeIfPresent(String.self, forKey: .project)
            ?? c.decodeIfPresent(String.self, forKey: .workspace)
        schemes = try list(.schemes, defaults.schemes)
        targets = try list(.targets, defaults.targets)
        excludeTargets = try list(.excludeTargets, defaults.excludeTargets)
        excludeTests = try value(.excludeTests, defaults.excludeTests)
        buildArguments = try list(.buildArguments, defaults.buildArguments)
        skipBuild = try value(.skipBuild, defaults.skipBuild)
        cleanBuild = try value(.cleanBuild, defaults.cleanBuild)
        indexStorePath = try list(.indexStorePath, defaults.indexStorePath)
        derivedDataPath = try c.decodeIfPresent(String.self, forKey: .derivedDataPath)
        indexStoreLibrary = try c.decodeIfPresent(String.self, forKey: .indexStoreLibrary)
        retainPublic = try value(.retainPublic, defaults.retainPublic)
        retainObjcAnnotated = try value(.retainObjcAnnotated, defaults.retainObjcAnnotated)
        retainObjcAccessible = try value(.retainObjcAccessible, defaults.retainObjcAccessible)
        retainFiles = try list(.retainFiles, defaults.retainFiles)
        retainUnusedProtocolFuncParams = try value(.retainUnusedProtocolFuncParams, defaults.retainUnusedProtocolFuncParams)
        retainSwiftUIPreviews = try value(.retainSwiftUIPreviews, defaults.retainSwiftUIPreviews)
        retainCodableProperties = try value(.retainCodableProperties, defaults.retainCodableProperties)
        retainEncodableProperties = try value(.retainEncodableProperties, defaults.retainEncodableProperties)
        retainAssignOnlyProperties = try value(.retainAssignOnlyProperties, defaults.retainAssignOnlyProperties)
        retainAssignOnlyPropertyTypes = try list(.retainAssignOnlyPropertyTypes, defaults.retainAssignOnlyPropertyTypes)
        externalEncodableProtocols = try list(.externalEncodableProtocols, defaults.externalEncodableProtocols)
        externalCodableProtocols = try list(.externalCodableProtocols, defaults.externalCodableProtocols)
        externalTestCaseClasses = try list(.externalTestCaseClasses, defaults.externalTestCaseClasses)
        disableUnusedParameterAnalysis = try value(.disableUnusedParameterAnalysis, defaults.disableUnusedParameterAnalysis)
        disableRedundantPublicAnalysis = try value(.disableRedundantPublicAnalysis, defaults.disableRedundantPublicAnalysis)
        reportExclude = try list(.reportExclude, defaults.reportExclude)
        reportInclude = try list(.reportInclude, defaults.reportInclude)
        indexExclude = try list(.indexExclude, defaults.indexExclude)
        format = try value(.format, defaults.format)
        relativeResults = try value(.relativeResults, defaults.relativeResults)
        strict = try value(.strict, defaults.strict)
        baseline = try c.decodeIfPresent(String.self, forKey: .baseline)
        writeBaseline = try c.decodeIfPresent(String.self, forKey: .writeBaseline)
        verbose = try value(.verbose, defaults.verbose)
        quiet = try value(.quiet, defaults.quiet)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encode(schemes, forKey: .schemes)
        try c.encode(targets, forKey: .targets)
        try c.encode(excludeTargets, forKey: .excludeTargets)
        try c.encode(excludeTests, forKey: .excludeTests)
        try c.encode(buildArguments, forKey: .buildArguments)
        try c.encode(skipBuild, forKey: .skipBuild)
        try c.encode(cleanBuild, forKey: .cleanBuild)
        try c.encode(indexStorePath, forKey: .indexStorePath)
        try c.encodeIfPresent(derivedDataPath, forKey: .derivedDataPath)
        try c.encodeIfPresent(indexStoreLibrary, forKey: .indexStoreLibrary)
        try c.encode(retainPublic, forKey: .retainPublic)
        try c.encode(retainObjcAnnotated, forKey: .retainObjcAnnotated)
        try c.encode(retainObjcAccessible, forKey: .retainObjcAccessible)
        try c.encode(retainFiles, forKey: .retainFiles)
        try c.encode(retainUnusedProtocolFuncParams, forKey: .retainUnusedProtocolFuncParams)
        try c.encode(retainSwiftUIPreviews, forKey: .retainSwiftUIPreviews)
        try c.encode(retainCodableProperties, forKey: .retainCodableProperties)
        try c.encode(retainEncodableProperties, forKey: .retainEncodableProperties)
        try c.encode(retainAssignOnlyProperties, forKey: .retainAssignOnlyProperties)
        try c.encode(retainAssignOnlyPropertyTypes, forKey: .retainAssignOnlyPropertyTypes)
        try c.encode(externalEncodableProtocols, forKey: .externalEncodableProtocols)
        try c.encode(externalCodableProtocols, forKey: .externalCodableProtocols)
        try c.encode(externalTestCaseClasses, forKey: .externalTestCaseClasses)
        try c.encode(disableUnusedParameterAnalysis, forKey: .disableUnusedParameterAnalysis)
        try c.encode(disableRedundantPublicAnalysis, forKey: .disableRedundantPublicAnalysis)
        try c.encode(reportExclude, forKey: .reportExclude)
        try c.encode(reportInclude, forKey: .reportInclude)
        try c.encode(indexExclude, forKey: .indexExclude)
        try c.encode(format, forKey: .format)
        try c.encode(relativeResults, forKey: .relativeResults)
        try c.encode(strict, forKey: .strict)
        try c.encodeIfPresent(baseline, forKey: .baseline)
        try c.encodeIfPresent(writeBaseline, forKey: .writeBaseline)
        try c.encode(verbose, forKey: .verbose)
        try c.encode(quiet, forKey: .quiet)
    }
}
