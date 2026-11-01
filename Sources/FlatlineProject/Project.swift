import FlatlineCore
import Foundation

/// A project, built and ready to analyze.
public struct PreparedProject: Sendable {
    /// Only files under this directory are analyzed.
    public let root: String
    public let indexStorePaths: [String]
    /// Modules the project describes as test targets.
    public let testModules: Set<String>
}

public protocol ProjectDriver: Sendable {
    var root: String { get }
    func prepare(configuration: Configuration, logger: Logger) throws -> PreparedProject
}

public enum ProjectKind: Equatable, Sendable {
    case swiftPackage(directory: String)
    case xcodeWorkspace(String)
    case xcodeProject(String)
    /// No project file: analyze an existing index store for files under a directory.
    case indexStore(root: String)
}

public enum ProjectDetector {
    /// Picks the project to analyze from the configuration, or from the files
    /// in `directory`.
    public static func detect(configuration: Configuration, directory: String) throws -> ProjectKind {
        if let project = configuration.project {
            let path = Paths.absolute(project, base: directory)
            if path.hasSuffix(".xcworkspace") { return .xcodeWorkspace(path) }
            if path.hasSuffix(".xcodeproj") { return .xcodeProject(path) }
            if path.hasSuffix("Package.swift") { return .swiftPackage(directory: (path as NSString).deletingLastPathComponent) }
            if FileManager.default.fileExists(atPath: path + "/Package.swift") { return .swiftPackage(directory: path) }
            throw FlatlineError("\(project) is not an Xcode workspace, Xcode project or Swift package")
        }

        if configuration.skipBuild, !configuration.indexStorePath.isEmpty {
            return .indexStore(root: directory)
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let workspaces = entries.filter { $0.hasSuffix(".xcworkspace") }.sorted()
        let projects = entries.filter { $0.hasSuffix(".xcodeproj") }.sorted()
        if workspaces.count == 1 { return .xcodeWorkspace(directory + "/" + workspaces[0]) }
        if workspaces.isEmpty, projects.count == 1 { return .xcodeProject(directory + "/" + projects[0]) }
        if workspaces.count + projects.count > 1 {
            throw FlatlineError(
                "found several Xcode projects (\((workspaces + projects).joined(separator: ", "))); "
                    + "choose one with --project or `project:` in .flatline.yml"
            )
        }
        if entries.contains("Package.swift") { return .swiftPackage(directory: directory) }
        throw FlatlineError(
            "no Swift package or Xcode project found in \(directory). "
                + "Use --project, or --index-store-path with --skip-build."
        )
    }

    /// Swift packages are built with `swift build`, unless schemes are
    /// configured: then with `xcodebuild`, which can build for iOS.
    public static func driver(
        for kind: ProjectKind,
        configuration: Configuration,
        workingDirectory: String
    ) -> any ProjectDriver {
        switch kind {
        case let .swiftPackage(directory) where !configuration.schemes.isEmpty:
            XcodeDriver(path: directory, kind: .package, root: directory)
        case let .swiftPackage(directory):
            SwiftPackageDriver(directory: directory)
        case let .xcodeWorkspace(path):
            XcodeDriver(path: path, kind: .workspace, root: root(for: path, workingDirectory: workingDirectory))
        case let .xcodeProject(path):
            XcodeDriver(path: path, kind: .project, root: root(for: path, workingDirectory: workingDirectory))
        case let .indexStore(root):
            IndexStoreDriver(root: root)
        }
    }

    /// Sources of an Xcode project often live next to it (e.g. local
    /// packages), so analyze the whole working directory when the project is
    /// inside it.
    private static func root(for project: String, workingDirectory: String) -> String {
        let directory = (project as NSString).deletingLastPathComponent
        return Paths.isInside(project, workingDirectory) ? workingDirectory : directory
    }
}

/// Analyzes an existing index store; nothing to build.
struct IndexStoreDriver: ProjectDriver {
    let root: String

    func prepare(configuration: Configuration, logger _: Logger) throws -> PreparedProject {
        PreparedProject(
            root: root,
            indexStorePaths: configuration.indexStorePath.map { Paths.absolute($0, base: root) },
            testModules: []
        )
    }
}

enum IndexStoreLocator {
    /// An index store directory contains a `v5` directory with units and records.
    static func isIndexStore(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path + "/v5/units", isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The most recently updated of the candidate stores.
    static func newest(of candidates: [String]) -> String? {
        candidates
            .filter(isIndexStore)
            .max { modificationDate(of: $0) < modificationDate(of: $1) }
    }

    private static func modificationDate(of store: String) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: store + "/v5/units")
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }
}
