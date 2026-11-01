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

        if !configuration.indexStorePath.isEmpty {
            guard configuration.buildVariants.isEmpty else {
                throw FlatlineError(
                    "build_variants and index_store_path can't be combined; "
                        + "each index store passed with index_store_path is analyzed as a variant of its own"
                )
            }
            if !configuration.skipBuild {
                try build(package.name, arguments: configuration.buildArguments, configuration: configuration, logger: logger)
            }
            return PreparedProject(
                root: directory,
                indexStores: IndexStoreLocator.explicitStores(configuration, base: directory),
                testModules: testModules
            )
        }

        // Each variant builds into a scratch directory of its own, so the
        // builds don't overwrite each other's index.
        let variants = configuration.resolvedVariants
        var stores: [[String]] = []
        for (index, (variant, directoryName)) in variants.enumerated() {
            var arguments = configuration.buildArguments + variant.buildArguments
            if let directoryName {
                arguments = withVariantScratchPath(arguments, name: directoryName)
            }
            if !configuration.skipBuild {
                let label = variants.count > 1
                    ? "\(package.name) (variant \(index + 1) of \(variants.count): \(variant.displayName))"
                    : package.name
                try build(label, arguments: arguments, configuration: configuration, logger: logger)
            }
            stores.append(try locateIndexStores(buildArguments: arguments))
        }
        return PreparedProject(root: directory, indexStores: stores, testModules: testModules)
    }

    private func build(_ label: String, arguments: [String], configuration: Configuration, logger: Logger) throws {
        if configuration.cleanBuild {
            logger.info("Cleaning \(label)")
            _ = try Toolchain.runSwift(["package", "clean"] + scratchPathArguments(arguments), in: directory)
        }
        // Debug builds are indexed by default. Requesting it explicitly breaks
        // test discovery on Linux with Swift Build, so only do it for release builds.
        var buildArguments = ["build"]
        if !configuration.excludeTests {
            buildArguments.append("--build-tests")
        }
        if Self.isReleaseBuild(arguments) {
            buildArguments.append("--enable-index-store")
        }
        buildArguments += arguments
        logger.info("Building \(label)")
        logger.debug("swift \(buildArguments.joined(separator: " "))")
        _ = try Toolchain.runSwift(buildArguments, in: directory, passthrough: logger.level >= .verbose)
    }

    /// Replaces the scratch path with `<scratch path>/flatline-variants/<name>`.
    func withVariantScratchPath(_ arguments: [String], name: String) -> [String] {
        var remaining: [String] = []
        var scratchPath = "\(directory)/.build"
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--scratch-path" || argument == "--build-path", index + 1 < arguments.endIndex {
                scratchPath = Paths.absolute(arguments[index + 1], base: directory)
                index += 2
                continue
            }
            if let value = argument.split(separator: "=", maxSplits: 1).last,
               argument.hasPrefix("--scratch-path=") || argument.hasPrefix("--build-path=") {
                scratchPath = Paths.absolute(String(value), base: directory)
            } else {
                remaining.append(argument)
            }
            index += 1
        }
        return remaining + ["--scratch-path", "\(scratchPath)/flatline-variants/\(name)"]
    }

    /// Just the scratch path arguments, for `swift package` commands.
    private func scratchPathArguments(_ arguments: [String]) -> [String] {
        guard let index = arguments.lastIndex(of: "--scratch-path"), index + 1 < arguments.endIndex else { return [] }
        return ["--scratch-path", arguments[index + 1]]
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
