import FlatlineCore

typealias SourceRange = FlatlineCore.SourceRange
typealias Position = FlatlineCore.SourceRange.Position

/// A `// flatline:` (or `// periphery:`) comment command.
enum CommentCommand: Hashable, Sendable {
    /// Don't report this declaration or anything inside it, and treat it as used.
    case ignore
    /// Don't report the listed parameters as unused.
    case ignoreParameters(Set<String>)
    /// Don't report anything in this file, and treat everything in it as used.
    case ignoreAll
}

struct ParameterInfo: Sendable {
    let name: String
    let position: Position
    let isUsed: Bool
}

/// What the parser knows about one declaration, keyed by the position of its
/// name, which is where the index places the declaration's occurrence.
struct DeclarationSyntaxInfo: Sendable {
    enum Kind: Sendable {
        case type(isActor: Bool)
        case `extension`
        case function
        case variable
        case enumCase
        case `typealias`
        case other
    }

    let kind: Kind
    let name: String
    let namePosition: Position
    /// From the first attribute to the end of the declaration.
    let range: SourceRange
    let attributes: Set<String>
    let modifiers: Set<String>
    let accessibility: Accessibility?
    let commands: Set<CommentCommand>
    /// The declaration is directly in the file, not nested in another declaration.
    let isTopLevel: Bool

    // Variables
    var isStored = false
    var hasObservers = false
    var typeAnnotation: String?

    // Functions, initializers and subscripts
    var parameters: [ParameterInfo] = []
    var hasBody = false
    /// The body is empty or only calls `fatalError()` or similar.
    var isStub = false

    var ignoredParameters: Set<String> {
        commands.reduce(into: []) { result, command in
            if case let .ignoreParameters(names) = command {
                result.formUnion(names)
            }
        }
    }

    var isIgnored: Bool {
        commands.contains(.ignore)
    }
}

struct FileSyntaxInfo: Sendable {
    let path: String
    var declarations: [Position: DeclarationSyntaxInfo] = [:]
    /// Declarations ordered by start, to find the innermost one around a position.
    var scopes: [DeclarationSyntaxInfo] = []
    /// The file contains statements outside of declarations (main.swift, scripts).
    var hasTopLevelCode = false
    var ignoresAll = false
    var previewRanges: [SourceRange] = []

    init(path: String) {
        self.path = path
    }

    /// The declarations whose range contains `position`, innermost first.
    func declarations(containing position: Position) -> [DeclarationSyntaxInfo] {
        var result: [DeclarationSyntaxInfo] = []
        // Scopes are in source order, so enclosing scopes come before nested ones.
        for scope in scopes {
            if scope.range.start > position { break }
            if scope.range.contains(position) {
                result.append(scope)
            }
        }
        return result.reversed()
    }

    func isInPreview(_ position: Position) -> Bool {
        previewRanges.contains { $0.contains(position) }
    }
}
