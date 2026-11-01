import FlatlineCore
import Foundation

/// Builds a Swift package with `swift build` and reads its index store.
public struct SwiftPackageDriver: ProjectDriver {
    public let directory: String

    public var root: String { directory }

    public init(directory: String) {
        self.directory = directory
    }

    public func prepare(configuration: Configuration, logger: Logger) throws -> PreparedProject {
        let package = try describe()
        let testModules = Set(package.targets.filter { $0.type == "test" }.map(\.moduleName))

        if !configuration.skipBuild {
            if configuration.cleanBuild {
                logger.info("Cleaning \(package.name)")
                _ = try Toolchain.runSwift(["package", "clean"], in: directory)
            }
            var arguments = ["build", "--enable-index-store"]
            if !configuration.excludeTests {
                arguments.append("--build-tests")
            }
            arguments += configuration.buildArguments
            logger.info("Building \(package.name)")
            logger.debug("swift \(arguments.joined(separator: " "))")
            _ = try Toolchain.runSwift(arguments, in: directory, passthrough: logger.level >= .verbose)
        }

        let stores: [String]
        if !configuration.indexStorePath.isEmpty {
            stores = configuration.indexStorePath.map { Paths.absolute($0, base: directory) }
        } else {
            stores = [try locateIndexStore(buildArguments: configuration.buildArguments)]
        }
        return PreparedProject(root: directory, indexStorePaths: stores, testModules: testModules)
    }

    struct PackageDescription: Decodable {
        struct Target: Decodable {
            let name: String
            let c99name: String?
            let type: String

            var moduleName: String { c99name ?? name }
        }

        let name: String
        let targets: [Target]
    }

    func describe() throws -> PackageDescription {
        let result = try Toolchain.runSwift(["package", "describe", "--type", "json"], in: directory)
        // Diagnostics may precede the JSON.
        guard let start = result.output.firstIndex(of: "{") else {
            throw FlatlineError("could not read the package description of \(directory)")
        }
        do {
            return try JSONDecoder().decode(PackageDescription.self, from: Data(result.output[start...].utf8))
        } catch {
            throw FlatlineError("could not read the package description of \(directory): \(error)")
        }
    }

    /// Where `swift build` put the index store. It differs between build systems:
    /// `.build/out` with Swift Build, `.build/<triple>/debug/index/store` with the native one.
    func locateIndexStore(buildArguments: [String]) throws -> String {
        let result = try Toolchain.runSwift(["build", "--show-bin-path"] + buildArguments, in: directory)
        let binPath = result.output.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let url = URL(fileURLWithPath: binPath)
        let candidates = [
            url.appendingPathComponent("index/store").path,
            url.deletingLastPathComponent().deletingLastPathComponent().path,
        ]
        guard let store = IndexStoreLocator.newest(of: candidates) else {
            throw FlatlineError(
                "could not find the index store of \(directory) (looked in \(candidates.joined(separator: ", "))). "
                    + "Pass --index-store-path."
            )
        }
        return store
    }
}
