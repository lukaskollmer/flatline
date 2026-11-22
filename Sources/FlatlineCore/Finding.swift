public struct Finding: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The declaration is never used.
        case unused
        /// A protocol that is only ever conformed to, never used as a type or constraint.
        case redundantProtocol
        /// A property that is written to, but never read.
        case assignOnlyProperty
        /// A function parameter that the function body never uses.
        case unusedParameter
        /// A `public` or `open` declaration that is only used inside its own module.
        case redundantPublicAccessibility
        /// An `import` of a module that the file doesn't use.
        case unusedImport
    }

    public let kind: Kind
    public let declarationKind: DeclarationKind
    /// The declaration name, the parameter name for `unusedParameter`, or the
    /// imported module (or `Module.Declaration`) for `unusedImport`.
    public let name: String
    public let location: SourceLocation
    public let modules: [String]
    /// USRs of the declaration; for `unusedParameter`, of the function; none for `unusedImport`.
    public let usrs: [String]
    /// For `redundantPublicAccessibility`: the accessibility written in source.
    public let accessibility: Accessibility?

    public init(
        kind: Kind,
        declarationKind: DeclarationKind,
        name: String,
        location: SourceLocation,
        modules: [String],
        usrs: [String],
        accessibility: Accessibility? = nil
    ) {
        self.kind = kind
        self.declarationKind = declarationKind
        self.name = name
        self.location = location
        self.modules = modules.sorted()
        self.usrs = usrs.sorted()
        self.accessibility = accessibility
    }

    public var message: String {
        switch kind {
        case .unused:
            "\(declarationKind.displayName) '\(name)' is unused"
        case .redundantProtocol:
            "Protocol '\(name)' is redundant: it is conformed to, but never used"
        case .assignOnlyProperty:
            "\(declarationKind.displayName) '\(name)' is assigned, but never read"
        case .unusedParameter:
            "Parameter '\(name)' is unused"
        case .redundantPublicAccessibility:
            "\(declarationKind.displayName) '\(name)' is declared \(accessibility?.rawValue ?? "public"), "
                + "but not used outside of \(modules.count == 1 ? "module '\(modules[0])'" : "its modules")"
        case .unusedImport:
            "Import '\(name)' is unused"
        }
    }

    /// Identifies the finding across runs; stable when code moves around.
    public var identifier: String {
        if kind == .unusedImport {
            // Imports have no USR. File names are unique within a module.
            let fileName = location.file.split(separator: "/").last.map(String.init) ?? location.file
            return "\(kind.rawValue)|\(modules.joined(separator: ","))|\(fileName)|\(name)"
        }
        return "\(kind.rawValue)|\(usrs.joined(separator: ","))|\(name)"
    }
}
