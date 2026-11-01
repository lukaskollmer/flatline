import FlatlineCore
import Foundation

/// Builds Xcode schemes with `xcodebuild` and reads the index store from derived data.
public struct XcodeDriver: ProjectDriver {
    public enum Kind: Sendable {
        case workspace
        case project
        /// A Swift package built with xcodebuild, e.g. one that only supports iOS.
        case package
    }

    public let path: String
    public let kind: Kind
    public let root: String

    public init(path: String, kind: Kind, root: String) {
        self.path = path
        self.kind = kind
        self.root = root
    }

    private var projectArguments: [String] {
        switch kind {
        case .workspace: ["-workspace", path]
        case .project: ["-project", path]
        case .package: []
        }
    }

    /// xcodebuild finds a package's manifest in the current directory.
    private var buildDirectory: String {
        kind == .package ? path : root
    }

    public func prepare(configuration: Configuration, logger: Logger) throws -> PreparedProject {
        let derivedData = derivedDataPath(configuration)

        if !configuration.skipBuild {
            // Checked at runtime rather than with #if, so the build code is
            // compiled (and analyzed) on every platform.
            guard Self.isXcodeAvailable else {
                throw FlatlineError(
                    "Xcode projects can only be built on macOS. "
                        + "To analyze one here, copy its index store and pass --skip-build --index-store-path."
                )
            }
            let schemes = try resolveSchemes(configuration)
            for scheme in schemes {
                try build(scheme: scheme, derivedData: derivedData, configuration: configuration, logger: logger)
            }
        }

        let stores: [String]
        if !configuration.indexStorePath.isEmpty {
            stores = configuration.indexStorePath.map { Paths.absolute($0, base: root) }
        } else {
            let candidates = ["\(derivedData)/Index.noindex/DataStore", "\(derivedData)/Index/DataStore"]
            stores = IndexStoreLocator.existing(candidates)
            guard !stores.isEmpty else {
                throw FlatlineError("could not find an index store in \(derivedData). Pass --index-store-path.")
            }
        }
        return PreparedProject(root: root, indexStorePaths: stores, testModules: [])
    }

    private static var isXcodeAvailable: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
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
            let schemes: [String]?
            let targets: [String]?
        }

        let workspace: Container?
        let project: Container?
    }

    /// Schemes and targets as `xcodebuild -list` reports them. Slow for
    /// projects with packages, since it resolves them first.
    func list() throws -> (schemes: [String], targets: [String]) {
        let result = try Shell.runChecked("xcodebuild", ["-list", "-json"] + projectArguments, in: buildDirectory)
        guard let start = result.output.firstIndex(of: "{") else { return ([], []) }
        let list = try JSONDecoder().decode(List.self, from: Data(result.output[start...].utf8))
        let container = list.workspace ?? list.project
        return (container?.schemes ?? [], container?.targets ?? [])
    }

    private func resolveSchemes(_ configuration: Configuration) throws -> [String] {
        guard !configuration.schemes.isEmpty else {
            let available = try list().schemes
            if available.count == 1 {
                return available
            }
            throw FlatlineError(
                "choose the schemes to build with --schemes or `schemes:` in .flatline.yml. "
                    + "Available schemes: \(available.joined(separator: ", "))"
            )
        }

        // Check every scheme before building any, so a typo doesn't fail
        // the run after a long build. Scheme files on disk are the fast path.
        let requested = configuration.schemes
        let onDisk = schemeFilesOnDisk()
        guard !requested.allSatisfy(onDisk.contains) else { return requested }

        let (schemes, targets) = try list()
        let missing = requested.filter { !schemes.contains($0) }
        guard !missing.isEmpty else { return requested }

        let problems = missing.map { name in
            targets.contains(name)
                ? "'\(name)' is a target, not a scheme"
                : "there is no scheme named '\(name)'"
        }
        throw FlatlineError(
            problems.joined(separator: "; ") + ". Available schemes: \(schemes.joined(separator: ", "))"
        )
    }

    /// Names of the shared and user schemes stored in the project or
    /// workspace, and in the projects a workspace contains.
    private func schemeFilesOnDisk() -> Set<String> {
        var containers: [String] = []
        switch kind {
        case .project:
            containers = [path]
        case .workspace:
            containers = [path] + projectsInWorkspace()
        case .package:
            containers = ["\(path)/.swiftpm/xcode"]
        }

        var names: Set<String> = []
        let fileManager = FileManager.default
        for container in containers {
            var directories = ["\(container)/xcshareddata/xcschemes"]
            let userData = "\(container)/xcuserdata"
            for user in (try? fileManager.contentsOfDirectory(atPath: userData)) ?? [] {
                directories.append("\(userData)/\(user)/xcschemes")
            }
            for directory in directories {
                for file in (try? fileManager.contentsOfDirectory(atPath: directory)) ?? [] where file.hasSuffix(".xcscheme") {
                    names.insert(String(file.dropLast(".xcscheme".count)))
                }
            }
        }
        return names
    }

    /// Projects referenced from a workspace's `contents.xcworkspacedata`.
    private func projectsInWorkspace() -> [String] {
        guard let contents = try? String(contentsOfFile: "\(path)/contents.xcworkspacedata", encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"location\s*=\s*"(?:group|container|absolute):([^"]+\.xcodeproj)""#)
        else { return [] }
        let workspaceDirectory = (path as NSString).deletingLastPathComponent
        let range = NSRange(contents.startIndex..., in: contents)
        return regex.matches(in: contents, range: range).compactMap { match in
            Range(match.range(at: 1), in: contents).map { Paths.absolute(String(contents[$0]), base: workspaceDirectory) }
        }
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
        do {
            try Shell.runChecked("xcodebuild", arguments, in: buildDirectory, passthrough: logger.level >= .verbose)
        } catch let error as FlatlineError where error.description.contains("must be enabled before it can be used") {
            throw FlatlineError(
                error.description + "\nxcodebuild requires package macros and plugins to be trusted first, "
                    + "e.g. by building the project once in Xcode."
            )
        } catch let error as FlatlineError where error.description.contains("a destination is provided") {
            throw FlatlineError(
                error.description + "\nPass a destination after `--`, e.g. "
                    + "flatline scan --schemes \(scheme) -- -destination 'generic/platform=iOS Simulator'"
            )
        }
    }
}
