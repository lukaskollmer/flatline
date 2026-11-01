import Foundation

/// Shell-style path patterns: `*` and `?` match within one path component,
/// `**` matches any number of components.
public struct Glob: Sendable, CustomStringConvertible {
    public let pattern: String
    private let regex: NSRegularExpression

    public init(_ pattern: String) throws {
        self.pattern = pattern
        regex = try NSRegularExpression(pattern: Self.regularExpression(for: pattern))
    }

    public var description: String { pattern }

    /// Matches `path`, which should be relative to the same directory the
    /// pattern is relative to (absolute patterns match absolute paths).
    public func matches(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }

    private static func regularExpression(for pattern: String) -> String {
        var result = "^"
        var characters = Array(pattern)[...]
        while let character = characters.popFirst() {
            switch character {
            case "*":
                if characters.first == "*" {
                    characters.removeFirst()
                    if characters.first == "/" {
                        characters.removeFirst()
                        result += "(?:.*/)?"
                    } else {
                        result += ".*"
                    }
                } else {
                    result += "[^/]*"
                }
            case "?":
                result += "[^/]"
            case "[", "]", "(", ")", "{", "}", ".", "+", "^", "$", "|", "\\":
                result += "\\\(character)"
            default:
                result.append(character)
            }
        }
        return result + "$"
    }
}

extension Glob {
    /// Matches an absolute path against patterns relative to `root`.
    public static func any(_ globs: [Glob], match path: String, relativeTo root: String) -> Bool {
        guard !globs.isEmpty else { return false }
        let relative = Paths.relative(path, to: root)
        return globs.contains { $0.matches(relative) || $0.matches(path) }
    }
}

public enum Paths {
    /// `path` relative to `root`, or `path` itself if it is outside `root`.
    public static func relative(_ path: String, to root: String) -> String {
        let root = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    public static func isInside(_ path: String, _ directory: String) -> Bool {
        let directory = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(directory)
    }

    /// Makes `path` absolute (relative to `base`) and removes `.`/`..` components.
    public static func absolute(_ path: String, base: String) -> String {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: base).appendingPathComponent(path)
        return url.standardizedFileURL.path
    }

    /// Resolves symlinks, so paths from the compiler and from the file system compare equal.
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
