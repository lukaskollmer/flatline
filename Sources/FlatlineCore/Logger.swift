import Foundation

/// Writes progress and diagnostics to standard error, so results on standard
/// output stay machine-readable.
public struct Logger: Sendable {
    public enum Level: Int, Sendable, Comparable {
        case quiet
        case normal
        case verbose

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let level: Level
    private let colors: Bool

    public init(level: Level = .normal) {
        self.level = level
        colors = isatty(STDERR_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    public func info(_ message: @autoclosure () -> String) {
        guard level >= .normal else { return }
        write(styled("*", "1;34") + " " + message())
    }

    public func debug(_ message: @autoclosure () -> String) {
        guard level >= .verbose else { return }
        write(styled("·", "2") + " " + message())
    }

    public func warning(_ message: @autoclosure () -> String) {
        write(styled("warning:", "1;33") + " " + message())
    }

    public func error(_ message: @autoclosure () -> String) {
        write(styled("error:", "1;31") + " " + message())
    }

    private func styled(_ text: String, _ code: String) -> String {
        colors ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    private func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
