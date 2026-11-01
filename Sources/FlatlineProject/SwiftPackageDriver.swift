import FlatlineCore
import Foundation

/// Builds a Swift package with `swift build` and reads its index store.
public struct SwiftPackageDriver: ProjectDriver {
    public let directory: String

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
            // Debug builds are indexed by default. Requesting it explicitly breaks
            // test discovery on Linux with Swift Build, so only do it for release builds.
            var arguments = ["build"]
            if !configuration.excludeTests {
                arguments.append("--build-tests")
            }
            if Self.isReleaseBuild(configuration.buildArguments) {
                arguments.append("--enable-index-store")
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
            stores = try locateIndexStores(buildArguments: configuration.buildArguments)
        }
        return PreparedProject(root: directory, indexStorePaths: stores, testModules: testModules)
    }

    static func isReleaseBuild(_ arguments: [String]) -> Bool {
        zip(arguments, arguments.dropFirst()).contains { flag, value in
            (flag == "-c" || flag == "--configuration") && value == "release"
        } || arguments.contains("--configuration=release")
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

    /// Where `swift build` put the index. It differs between build systems and
    /// commands: `.build/out` or `.build/out/Products/Debug/index/store` with
    /// Swift Build, `.build/<triple>/debug/index/store` with the native one.
    func locateIndexStores(buildArguments: [String]) throws -> [String] {
        let result = try Toolchain.runSwift(["build", "--show-bin-path"] + buildArguments, in: directory)
        let binPath = result.output.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let url = URL(fileURLWithPath: binPath)
        let candidates = [
            url.appendingPathComponent("index/store").path,
            url.deletingLastPathComponent().deletingLastPathComponent().path,
        ]
        let stores = IndexStoreLocator.existing(candidates)
        guard !stores.isEmpty else {
            throw FlatlineError(
                "could not find the index store of \(directory) (looked in \(candidates.joined(separator: ", "))). "
                    + "Pass --index-store-path."
            )
        }
        return stores
    }
}
