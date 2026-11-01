import Foundation

/// A record of accepted findings. Findings in the baseline are not reported,
/// so a project can adopt flatline without fixing everything first.
public struct Baseline: Codable, Sendable {
    public var version = 1
    public var findings: [String]

    public init(findings: [Finding]) {
        self.findings = Array(Set(findings.map(\.identifier))).sorted()
    }

    public static func load(from path: String) throws -> Baseline {
        try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public func write(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func filter(_ findings: [Finding]) -> [Finding] {
        let known = Set(self.findings)
        return findings.filter { !known.contains($0.identifier) }
    }
}
