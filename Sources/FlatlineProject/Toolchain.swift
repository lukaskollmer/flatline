import FlatlineCore
import Foundation

/// Locates the Swift toolchain's programs and libraries.
public enum Toolchain {
    #if os(macOS)
    /// On macOS, go through `xcrun` so the selected Xcode's toolchain (and
    /// `TOOLCHAINS`/`DEVELOPER_DIR`) is used, not whatever `swift` is on `PATH`.
    public static let swift = (program: "xcrun", arguments: ["swift"])
    static let libraryExtension = "dylib"
    #else
    public static let swift = (program: "swift", arguments: [String]())
    static let libraryExtension = "so"
    #endif

    public static func runSwift(
        _ arguments: [String],
        in directory: String? = nil,
        passthrough: Bool = false
    ) throws -> ProcessResult {
        try Shell.runChecked(swift.program, swift.arguments + arguments, in: directory, passthrough: passthrough)
    }

    /// Finds libIndexStore, preferring an explicit path, then the toolchain that
    /// `swift` belongs to.
    public static func indexStoreLibrary(explicit: String?) throws -> String {
        if let explicit {
            guard FileManager.default.fileExists(atPath: explicit) else {
                throw FlatlineError("libIndexStore not found at \(explicit)")
            }
            return explicit
        }
        if let fromEnvironment = ProcessInfo.processInfo.environment["FLATLINE_INDEXSTORE_LIBRARY"] {
            return fromEnvironment
        }

        var candidates: [String] = []
        // runtimeResourcePath is <toolchain>/usr/lib/swift.
        if let info = try? runSwift(["-print-target-info"]),
           let json = try? JSONSerialization.jsonObject(with: Data(info.output.utf8)) as? [String: Any],
           let paths = json["paths"] as? [String: Any],
           let resources = paths["runtimeResourcePath"] as? String {
            let lib = (resources as NSString).deletingLastPathComponent
            candidates.append("\(lib)/libIndexStore.\(libraryExtension)")
        }
        #if os(macOS)
        if let developer = try? Shell.run("xcode-select", ["-p"]).output.trimmingCharacters(in: .whitespacesAndNewlines) {
            candidates.append("\(developer)/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib")
        }
        #else
        candidates += ["/usr/lib/libIndexStore.so", "/usr/lib/swift/linux/libIndexStore.so"]
        #endif

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        throw FlatlineError(
            "could not find libIndexStore (looked in \(candidates.joined(separator: ", "))). "
                + "Pass --index-store-library or set index_store_library."
        )
    }
}
