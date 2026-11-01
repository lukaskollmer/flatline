import FlatlineCore
import Foundation
import Yams

public enum ConfigurationLoader {
    public static let defaultFileNames = [".flatline.yml", ".flatline.yaml", ".periphery.yml"]

    /// Options of Periphery that have no equivalent and are safe to ignore.
    static let ignoredPeripheryKeys: Set<String> = [
        "disable_update_check", "color", "skip_schemes_validation", "retain_unused_imported_modules",
        "disable_unused_import_analysis", "superfluous_ignore_comments", "no_superfluous_ignore_comments",
        "json_package_manifest_path", "bazel", "bazel_filter", "generic_project_config", "exclude_targets_regex",
    ]

    /// Loads `path`, or the first default configuration file in `directory`.
    public static func load(path: String?, directory: String, logger: Logger) throws -> (Configuration, String?) {
        let file: String
        if let path {
            file = Paths.absolute(path, base: directory)
            guard FileManager.default.fileExists(atPath: file) else {
                throw FlatlineError("configuration file \(path) does not exist")
            }
        } else if let found = defaultFileNames.map({ "\(directory)/\($0)" }).first(where: FileManager.default.fileExists) {
            file = found
            if found.hasSuffix(".periphery.yml") {
                logger.info("Using .periphery.yml (rename it to .flatline.yml to silence this message)")
            }
        } else {
            return (Configuration(), nil)
        }

        let text = try String(contentsOfFile: file, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (Configuration(), file)
        }
        if let keys = (try Yams.load(yaml: text) as? [String: Any])?.keys {
            let known = Set(Configuration.CodingKeys.allCases.map(\.rawValue))
            for key in keys.sorted() where !known.contains(key) {
                if ignoredPeripheryKeys.contains(key) {
                    logger.debug("Ignoring unsupported option '\(key)' in \(file)")
                } else {
                    logger.warning("Unknown option '\(key)' in \(file) is ignored")
                }
            }
        }
        do {
            return (try YAMLDecoder().decode(Configuration.self, from: text), file)
        } catch let error as DecodingError {
            throw FlatlineError("invalid configuration in \(file): \(describe(error))")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context),
             let .keyNotFound(_, context), let .dataCorrupted(context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}
