import Foundation

public enum OutputFormat: String, Codable, Sendable, CaseIterable {
    /// `path:line:column: warning: message`, understood by Xcode and most editors.
    case xcode
    case json
    case csv
    case checkstyle
    /// Workflow commands that annotate pull requests on GitHub Actions.
    case githubActions = "github-actions"
    /// Code Quality report for GitLab CI (Code Climate format).
    case codeclimate

    public func formatter() -> any OutputFormatter {
        switch self {
        case .xcode: XcodeFormatter()
        case .json: JSONFormatter()
        case .csv: CSVFormatter()
        case .checkstyle: CheckstyleFormatter()
        case .githubActions: GitHubActionsFormatter()
        case .codeclimate: CodeClimateFormatter()
        }
    }
}

public struct OutputContext: Sendable {
    public let projectRoot: String
    public let relativePaths: Bool

    public init(projectRoot: String, relativePaths: Bool) {
        self.projectRoot = projectRoot
        self.relativePaths = relativePaths
    }

    public func path(_ location: SourceLocation) -> String {
        relativePaths ? Paths.relative(location.file, to: projectRoot) : location.file
    }
}

public protocol OutputFormatter: Sendable {
    func format(_ findings: [Finding], context: OutputContext) throws -> String
}

struct XcodeFormatter: OutputFormatter {
    func format(_ findings: [Finding], context: OutputContext) -> String {
        findings.map { finding in
            "\(context.path(finding.location)):\(finding.location.line):\(finding.location.column): warning: \(finding.message)"
        }.joined(separator: "\n")
    }
}

struct JSONFormatter: OutputFormatter {
    private struct Entry: Encodable {
        let kind: Finding.Kind
        let declarationKind: DeclarationKind
        let name: String
        let message: String
        let file: String
        let line: Int
        let column: Int
        let modules: [String]
        let usrs: [String]
        let accessibility: Accessibility?

        enum CodingKeys: String, CodingKey {
            case kind
            case declarationKind = "declaration_kind"
            case name, message, file, line, column, modules, usrs, accessibility
        }
    }

    func format(_ findings: [Finding], context: OutputContext) throws -> String {
        let entries = findings.map {
            Entry(
                kind: $0.kind,
                declarationKind: $0.declarationKind,
                name: $0.name,
                message: $0.message,
                file: context.path($0.location),
                line: $0.location.line,
                column: $0.location.column,
                modules: $0.modules,
                usrs: $0.usrs,
                accessibility: $0.accessibility
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(entries), as: UTF8.self)
    }
}

struct CSVFormatter: OutputFormatter {
    func format(_ findings: [Finding], context: OutputContext) -> String {
        let header = "kind,declaration_kind,name,modules,file,line,column,message"
        let rows = findings.map { finding in
            [
                finding.kind.rawValue,
                finding.declarationKind.rawValue,
                finding.name,
                finding.modules.joined(separator: " "),
                context.path(finding.location),
                String(finding.location.line),
                String(finding.location.column),
                finding.message,
            ].map(Self.escape).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

struct CheckstyleFormatter: OutputFormatter {
    func format(_ findings: [Finding], context: OutputContext) -> String {
        var lines = [#"<?xml version="1.0" encoding="utf-8"?>"#, #"<checkstyle version="4.3">"#]
        let byFile = Dictionary(grouping: findings) { context.path($0.location) }
        for file in byFile.keys.sorted() {
            lines.append(#"  <file name="\#(Self.escape(file))">"#)
            for finding in byFile[file]! {
                lines.append(
                    #"    <error line="\#(finding.location.line)" column="\#(finding.location.column)" "#
                        + #"severity="warning" message="\#(Self.escape(finding.message))" "#
                        + #"source="flatline.\#(finding.kind.rawValue)"/>"#
                )
            }
            lines.append("  </file>")
        }
        lines.append("</checkstyle>")
        return lines.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

struct GitHubActionsFormatter: OutputFormatter {
    func format(_ findings: [Finding], context: OutputContext) -> String {
        // GitHub resolves annotation paths relative to the repository root.
        let context = OutputContext(projectRoot: context.projectRoot, relativePaths: true)
        return findings.map { finding in
            "::warning file=\(Self.escapeProperty(context.path(finding.location))),"
                + "line=\(finding.location.line),col=\(finding.location.column),"
                + "title=\(Self.escapeProperty("flatline: \(finding.kind.rawValue)"))::\(Self.escapeData(finding.message))"
        }.joined(separator: "\n")
    }

    static func escapeData(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    static func escapeProperty(_ text: String) -> String {
        escapeData(text)
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: ",", with: "%2C")
    }
}

struct CodeClimateFormatter: OutputFormatter {
    private struct Issue: Encodable {
        struct Location: Encodable {
            struct Lines: Encodable { let begin: Int }
            let path: String
            let lines: Lines
        }

        let type = "issue"
        let checkName: String
        let description: String
        let categories = ["Clarity"]
        let severity = "minor"
        let fingerprint: String
        let location: Location

        enum CodingKeys: String, CodingKey {
            case type
            case checkName = "check_name"
            case description, categories, severity, fingerprint, location
        }
    }

    func format(_ findings: [Finding], context: OutputContext) throws -> String {
        let context = OutputContext(projectRoot: context.projectRoot, relativePaths: true)
        let issues = findings.map {
            Issue(
                checkName: $0.kind.rawValue,
                description: $0.message,
                fingerprint: Self.fingerprint($0.identifier),
                location: .init(path: context.path($0.location), lines: .init(begin: $0.location.line))
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(issues), as: UTF8.self)
    }

    /// 64-bit FNV-1a, hex encoded: stable across runs and platforms.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
