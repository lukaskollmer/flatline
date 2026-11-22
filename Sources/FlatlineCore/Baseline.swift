import Foundation

/// A record of accepted findings. Findings in the baseline are not reported,
/// so a project can adopt flatline without fixing everything first.
public struct Baseline: Codable, Sendable {
    public var version = 1
    public var findings: [String]

    public init(findings: [Finding], projectRoot: String) {
        self.findings = Array(Set(findings.map { $0.identifier(projectRoot: projectRoot) })).sorted()
    }

    public static func load(from path: String) throws -> Baseline {
        try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public func write(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func filter(_ findings: [Finding], projectRoot: String) -> [Finding] {
        let known = Set(self.findings)
        return findings.filter { !known.contains($0.identifier(projectRoot: projectRoot)) }
    }
}
