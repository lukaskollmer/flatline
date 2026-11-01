import FlatlineCore
import Foundation

/// Builds Xcode schemes with `xcodebuild` and reads the index store from derived data.
public struct XcodeDriver: ProjectDriver {
    public let path: String
    public let isWorkspace: Bool
    public let root: String

    public init(path: String, isWorkspace: Bool, root: String) {
        self.path = path
        self.isWorkspace = isWorkspace
        self.root = root
    }

    private var projectArguments: [String] {
        [isWorkspace ? "-workspace" : "-project", path]
    }

    public func prepare(configuration: Configuration, logger: Logger) throws -> PreparedProject {
        let derivedData = derivedDataPath(configuration)

        if !configuration.skipBuild {
            #if !os(macOS)
            throw FlatlineError(
                "Xcode projects can only be built on macOS. "
                    + "To analyze one here, copy its index store and pass --skip-build --index-store-path."
            )
            #else
            let schemes = try resolveSchemes(configuration)
            for scheme in schemes {
                try build(scheme: scheme, derivedData: derivedData, configuration: configuration, logger: logger)
            }
            #endif
        }

        let stores: [String]
        if !configuration.indexStorePath.isEmpty {
            stores = configuration.indexStorePath.map { Paths.absolute($0, base: root) }
        } else {
            let candidates = ["\(derivedData)/Index.noindex/DataStore", "\(derivedData)/Index/DataStore"]
            guard let store = IndexStoreLocator.newest(of: candidates) else {
                throw FlatlineError("could not find an index store in \(derivedData). Pass --index-store-path.")
            }
            stores = [store]
        }
        return PreparedProject(root: root, indexStorePaths: stores, testModules: [])
    }

    func derivedDataPath(_ configuration: Configuration) -> String {
        if let path = configuration.derivedDataPath {
            return Paths.absolute(path, base: root)
        }
        // A private derived data directory keeps flatline's builds from
        // interfering with Xcode's, and makes them incremental across runs.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
            ?? NSTemporaryDirectory()
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return "\(caches)/flatline/DerivedData/\(name)-\(Self.hash(path))"
    }

    private static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }

    struct List: Decodable {
        struct Container: Decodable {
            let name: String
            let schemes: [String]?
        }

        let workspace: Container?
        let project: Container?
    }

    func availableSchemes() throws -> [String] {
        let result = try Shell.runChecked("xcodebuild", ["-list", "-json"] + projectArguments, in: root)
        guard let start = result.output.firstIndex(of: "{") else { return [] }
        let list = try JSONDecoder().decode(List.self, from: Data(result.output[start...].utf8))
        return (list.workspace ?? list.project)?.schemes ?? []
    }

    private func resolveSchemes(_ configuration: Configuration) throws -> [String] {
        if !configuration.schemes.isEmpty {
            return configuration.schemes
        }
        let available = try availableSchemes()
        if available.count == 1 {
            return available
        }
        throw FlatlineError(
            "choose the schemes to build with --schemes or `schemes:` in .flatline.yml. "
                + "Available schemes: \(available.joined(separator: ", "))"
        )
    }

    private func build(scheme: String, derivedData: String, configuration: Configuration, logger: Logger) throws {
        var arguments = [configuration.excludeTests ? "build" : "build-for-testing"]
        if configuration.cleanBuild {
            arguments.insert("clean", at: 0)
        }
        arguments += projectArguments
        arguments += ["-scheme", scheme, "-derivedDataPath", derivedData]
        if logger.level < .verbose {
            arguments.append("-quiet")
        }
        arguments += [
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY=",
            "COMPILER_INDEX_STORE_ENABLE=YES",
            "INDEX_ENABLE_DATA_STORE=YES",
            "DEBUG_INFORMATION_FORMAT=dwarf",
        ]
        arguments += configuration.buildArguments
        logger.info("Building scheme \(scheme)")
        logger.debug("xcodebuild \(arguments.joined(separator: " "))")
        try Shell.runChecked("xcodebuild", arguments, in: root, passthrough: logger.level >= .verbose)
    }
}
