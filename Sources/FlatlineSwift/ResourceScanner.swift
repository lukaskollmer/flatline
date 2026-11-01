import FlatlineCore
import Foundation

/// Finds class names referenced from Interface Builder files, property lists
/// and Core Data models, which instantiate classes by name at runtime.
enum ResourceScanner {
    static func classNames(in root: String, exclude: [Glob]) -> Set<String> {
        var names: Set<String> = []
        let skipped = Set(UnitSelector.ignoredDirectories + [".git", "node_modules", "build"])
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return names }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skipped.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let path = url.path
            guard !Glob.any(exclude, match: path, relativeTo: root) else { continue }

            let patterns: [String]
            switch url.pathExtension {
            case "xib", "storyboard":
                patterns = [#"customClass="([^"]+)""#]
            case "plist":
                patterns = [#"<key>[A-Za-z]*(?:Class|ClassName)</key>\s*<string>([^<]+)</string>"#]
            case "" where name == "contents" && url.deletingLastPathComponent().pathExtension == "xcdatamodel":
                patterns = [#"(?:representedClassName|customClassName)="([^"]+)""#]
            default:
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for pattern in patterns {
                for match in matches(of: pattern, in: text) {
                    // "$(PRODUCT_MODULE_NAME).SceneDelegate" or "Module.Class" → "Class"
                    if let className = match.split(separator: ".").last {
                        names.insert(String(className))
                    }
                }
            }
        }
        return names
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
