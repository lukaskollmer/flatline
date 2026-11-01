import FlatlineCore
import Foundation
import SwiftParser
import SwiftSyntax

/// Parses a source file and collects what the index doesn't record:
/// attributes, modifiers, comment commands, parameter usage and source ranges.
enum SyntaxCollector {
    static func collect(path: String) throws -> FileSyntaxInfo {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return collect(source: source, path: path)
    }

    static func collect(source: String, path: String) -> FileSyntaxInfo {
        let tree = Parser.parse(source: source)
        let visitor = DeclarationVisitor(converter: SourceLocationConverter(fileName: path, tree: tree))
        visitor.walk(tree)

        var info = FileSyntaxInfo(path: path)
        info.scopes = visitor.declarations
        for declaration in visitor.declarations {
            info.declarations[declaration.namePosition] = declaration
        }
        for (position, declaration) in visitor.aliases {
            info.declarations[position] = declaration
        }
        info.previewRanges = visitor.previewRanges
        info.hasTopLevelCode = (path as NSString).lastPathComponent == "main.swift"
            || tree.statements.contains { if case .decl = $0.item { false } else { true } }
        info.ignoresAll = Self.commands(in: tree.leadingTrivia).contains(.ignoreAll)
            || source.contains("flatline:ignore:all")
            || source.contains("periphery:ignore:all")
        return info
    }

    static func commands(in trivia: Trivia) -> Set<CommentCommand> {
        var commands: Set<CommentCommand> = []
        for piece in trivia {
            let text: String
            switch piece {
            case let .lineComment(comment), let .blockComment(comment),
                 let .docLineComment(comment), let .docBlockComment(comment):
                text = comment
            default:
                continue
            }
            for prefix in ["flatline:", "periphery:"] {
                guard let range = text.range(of: prefix) else { continue }
                let rest = text[range.upperBound...]
                let word = rest.prefix { !$0.isWhitespace && $0 != "*" }
                switch word {
                case "ignore":
                    commands.insert(.ignore)
                case "ignore:all":
                    commands.insert(.ignoreAll)
                case "ignore:parameters":
                    let names = rest.dropFirst(word.count)
                        .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                        .map { String($0) }
                        .filter { $0 != "*/" && $0 != "-" }
                    commands.insert(.ignoreParameters(Set(names.prefix { !$0.hasPrefix("-") })))
                default:
                    break
                }
            }
        }
        return commands
    }
}

private final class DeclarationVisitor: SyntaxVisitor {
    let converter: SourceLocationConverter
    var declarations: [DeclarationSyntaxInfo] = []
    /// Extra positions under which a declaration is registered.
    var aliases: [(Position, DeclarationSyntaxInfo)] = []
    var previewRanges: [SourceRange] = []

    /// Nesting inside type and extension bodies.
    private var typeDepth = 0
    /// Nesting inside function bodies, closures and accessors, where
    /// declarations are local and not part of the index.
    private var localDepth = 0

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Helpers

    private func position(_ absolute: AbsolutePosition) -> Position {
        let location = converter.location(for: absolute)
        return Position(line: location.line, column: location.column)
    }

    private func position(of token: TokenSyntax) -> Position {
        position(token.positionAfterSkippingLeadingTrivia)
    }

    private func range(of node: some SyntaxProtocol) -> SourceRange {
        SourceRange(
            start: position(node.positionAfterSkippingLeadingTrivia),
            end: position(node.endPositionBeforeTrailingTrivia)
        )
    }

    private func record(
        _ kind: DeclarationSyntaxInfo.Kind,
        name: TokenSyntax,
        node: some DeclSyntaxProtocol,
        attributes: AttributeListSyntax?,
        modifiers: DeclModifierListSyntax?,
        configure: (inout DeclarationSyntaxInfo) -> Void = { _ in }
    ) {
        guard localDepth == 0 else { return }
        var info = DeclarationSyntaxInfo(
            kind: kind,
            name: name.text.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
            namePosition: position(of: name),
            range: range(of: node),
            attributes: Self.attributeNames(attributes),
            modifiers: Self.modifierNames(modifiers),
            accessibility: Self.accessibility(modifiers),
            commands: SyntaxCollector.commands(in: node.leadingTrivia),
            isTopLevel: typeDepth == 0
        )
        configure(&info)
        declarations.append(info)
    }

    static func attributeNames(_ attributes: AttributeListSyntax?) -> Set<String> {
        var names: Set<String> = []
        for element in attributes ?? [] {
            guard case let .attribute(attribute) = element else { continue }
            var name = attribute.attributeName.trimmedDescription
            if let generic = name.firstIndex(of: "<") {
                name = String(name[..<generic])
            }
            names.insert(name)
            if let last = name.split(separator: ".").last, last.count != name.count {
                names.insert(String(last))
            }
            if name == "available", attribute.arguments?.trimmedDescription.contains("unavailable") == true {
                names.insert("available(unavailable)")
            }
        }
        return names
    }

    static func modifierNames(_ modifiers: DeclModifierListSyntax?) -> Set<String> {
        Set((modifiers ?? []).map { modifier in
            if let detail = modifier.detail?.detail.text {
                return "\(modifier.name.text)(\(detail))"
            }
            return modifier.name.text
        })
    }

    static func accessibility(_ modifiers: DeclModifierListSyntax?) -> Accessibility? {
        for modifier in modifiers ?? [] where modifier.detail == nil {
            if let accessibility = Accessibility(rawValue: modifier.name.text) {
                return accessibility
            }
        }
        return nil
    }

    private func parameters(_ list: FunctionParameterListSyntax, body: (some SyntaxProtocol)?) -> [ParameterInfo] {
        guard !list.isEmpty else { return [] }
        let used = body.map { IdentifierCollector.identifiers(in: $0) } ?? []
        return list.compactMap { parameter in
            let token = parameter.secondName ?? parameter.firstName
            let name = token.text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            guard name != "_" else { return nil }
            return ParameterInfo(name: name, position: position(of: token), isUsed: used.contains(name))
        }
    }

    private static let stubFunctions: Set<String> = [
        "fatalError", "preconditionFailure", "assertionFailure", "abort", "unimplemented", "notImplemented",
    ]

    private static func isStub(_ statements: CodeBlockItemListSyntax) -> Bool {
        guard let first = statements.first else { return true }
        guard statements.count == 1, case let .expr(expression) = first.item,
              let call = expression.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self)
        else { return false }
        return stubFunctions.contains(callee.baseName.text)
    }

    // MARK: Types

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.type(isActor: false), name: node.name, node: node, attributes: node.attributes, modifiers: node.modifiers)
        return enterType()
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.type(isActor: false), name: node.name, node: node, attributes: node.attributes, modifiers: node.modifiers)
        return enterType()
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.type(isActor: false), name: node.name, node: node, attributes: node.attributes, modifiers: node.modifiers)
        return enterType()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.type(isActor: true), name: node.name, node: node, attributes: node.attributes, modifiers: node.modifiers)
        return enterType()
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.type(isActor: false), name: node.name, node: node, attributes: node.attributes, modifiers: node.modifiers)
        return enterType()
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard localDepth == 0 else { return enterType() }
        // The index places an extension at the last component of the extended type.
        let tokens = node.extendedType.tokens(viewMode: .sourceAccurate).filter {
            if case .identifier = $0.tokenKind { true } else { false }
        }
        if let last = tokens.last {
            record(.extension, name: last, node: node, attributes: node.attributes, modifiers: node.modifiers)
            if let first = tokens.first, first != last, let info = declarations.last {
                aliases.append((position(of: first), info))
            }
        }
        return enterType()
    }

    override func visitPost(_: ClassDeclSyntax) { typeDepth -= 1 }
    override func visitPost(_: StructDeclSyntax) { typeDepth -= 1 }
    override func visitPost(_: EnumDeclSyntax) { typeDepth -= 1 }
    override func visitPost(_: ActorDeclSyntax) { typeDepth -= 1 }
    override func visitPost(_: ProtocolDeclSyntax) { typeDepth -= 1 }
    override func visitPost(_: ExtensionDeclSyntax) { typeDepth -= 1 }

    private func enterType() -> SyntaxVisitorContinueKind {
        typeDepth += 1
        return .visitChildren
    }

    // MARK: Members

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.function, name: node.name, node: node, attributes: node.attributes, modifiers: node.modifiers) { info in
            info.parameters = parameters(node.signature.parameterClause.parameters, body: node.body)
            info.hasBody = node.body != nil
            info.isStub = node.body.map { Self.isStub($0.statements) } ?? false
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.function, name: node.initKeyword, node: node, attributes: node.attributes, modifiers: node.modifiers) { info in
            info.parameters = parameters(node.signature.parameterClause.parameters, body: node.body)
            info.hasBody = node.body != nil
            info.isStub = node.body.map { Self.isStub($0.statements) } ?? false
        }
        return .visitChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.function, name: node.deinitKeyword, node: node, attributes: node.attributes, modifiers: node.modifiers)
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.function, name: node.subscriptKeyword, node: node, attributes: node.attributes, modifiers: node.modifiers) { info in
            info.parameters = parameters(node.parameterClause.parameters, body: node.accessorBlock)
            info.hasBody = node.accessorBlock != nil
        }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            let isStored: Bool
            var hasObservers = false
            switch binding.accessorBlock?.accessors {
            case nil:
                isStored = true
            case .getter:
                isStored = false
            case let .accessors(accessors):
                let kinds = Set(accessors.map(\.accessorSpecifier.text))
                hasObservers = !kinds.isDisjoint(with: ["willSet", "didSet"])
                isStored = kinds.isSubset(of: ["willSet", "didSet"])
            }
            for name in Self.identifiers(in: binding.pattern) {
                record(.variable, name: name, node: node, attributes: node.attributes, modifiers: node.modifiers) { info in
                    info.isStored = isStored
                    info.hasObservers = hasObservers
                    info.typeAnnotation = binding.typeAnnotation?.type.trimmedDescription
                }
            }
        }
        return .visitChildren
    }

    private static func identifiers(in pattern: PatternSyntax) -> [TokenSyntax] {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            return [identifier.identifier]
        }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.flatMap { identifiers(in: $0.pattern) }
        }
        if let binding = pattern.as(ValueBindingPatternSyntax.self) {
            return identifiers(in: binding.pattern)
        }
        return []
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.elements {
            record(.enumCase, name: element.name, node: node, attributes: node.attributes, modifiers: node.modifiers)
        }
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.typealias, name: node.name, node: node, attributes: node.attributes, modifiers: node.modifiers)
        return .visitChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.other, name: node.name, node: node, attributes: node.attributes, modifiers: node.modifiers)
        return .visitChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.other, name: node.name, node: node, attributes: node.attributes, modifiers: node.modifiers)
        return .visitChildren
    }

    // MARK: Local scopes

    override func visit(_: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        localDepth += 1
        return .visitChildren
    }

    override func visitPost(_: CodeBlockSyntax) { localDepth -= 1 }

    override func visit(_: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        localDepth += 1
        return .visitChildren
    }

    override func visitPost(_: AccessorBlockSyntax) { localDepth -= 1 }

    override func visit(_: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        localDepth += 1
        return .visitChildren
    }

    override func visitPost(_: ClosureExprSyntax) { localDepth -= 1 }

    // MARK: Previews

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.macroName.text == "Preview" {
            previewRanges.append(range(of: node))
        }
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if node.macroName.text == "Preview" {
            previewRanges.append(range(of: node))
        }
        return .visitChildren
    }
}

/// Collects every name a piece of code refers to, to decide whether a
/// parameter is used. Over-approximates: any use of the name counts.
private final class IdentifierCollector: SyntaxVisitor {
    var names: Set<String> = []

    static func identifiers(in node: some SyntaxProtocol) -> Set<String> {
        let collector = IdentifierCollector(viewMode: .sourceAccurate)
        collector.walk(node)
        return collector.names
    }

    private func insert(_ token: TokenSyntax) {
        names.insert(token.text.trimmingCharacters(in: CharacterSet(charactersIn: "`")))
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        insert(node.baseName)
        return .visitChildren
    }

    // `if let name {` and `guard let name else {` refer to `name`.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if node.initializer == nil, let identifier = node.pattern.as(IdentifierPatternSyntax.self) {
            insert(identifier.identifier)
        }
        return .visitChildren
    }

    // `[name]` and `[weak name]` capture lists refer to `name`.
    override func visit(_ node: ClosureCaptureSyntax) -> SyntaxVisitorContinueKind {
        if node.initializer == nil {
            insert(node.name)
        }
        return .visitChildren
    }
}
