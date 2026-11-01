public struct SourceLocation: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// Absolute path of the source file.
    public let file: String
    /// 1-based line.
    public let line: Int
    /// 1-based UTF-8 column.
    public let column: Int

    public init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    public var description: String {
        "\(file):\(line):\(column)"
    }

    public static func < (lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        (lhs.file, lhs.line, lhs.column) < (rhs.file, rhs.line, rhs.column)
    }
}

/// A half-open range of positions within one file, as (line, column) pairs.
public struct SourceRange: Hashable, Sendable {
    public let start: Position
    public let end: Position

    public struct Position: Hashable, Comparable, Sendable {
        public let line: Int
        public let column: Int

        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }

        public static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.line, lhs.column) < (rhs.line, rhs.column)
        }
    }

    public init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }

    public func contains(_ position: Position) -> Bool {
        start <= position && position < end
    }

    public func contains(_ other: SourceRange) -> Bool {
        start <= other.start && other.end <= end
    }
}
