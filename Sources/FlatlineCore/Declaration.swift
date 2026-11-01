public enum DeclarationKind: String, Codable, Sendable, CaseIterable {
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case actor
    case `extension`
    case `typealias`
    case associatedType
    case enumCase
    case function
    case instanceMethod
    case staticMethod
    case classMethod
    case `operator`
    case initializer
    case deinitializer
    case `subscript`
    case globalVariable
    case instanceProperty
    case staticProperty
    case classProperty
    case macro

    public var displayName: String {
        switch self {
        case .class: "Class"
        case .struct: "Struct"
        case .enum: "Enum"
        case .protocol: "Protocol"
        case .actor: "Actor"
        case .extension: "Extension"
        case .typealias: "Typealias"
        case .associatedType: "Associated type"
        case .enumCase: "Enum case"
        case .function: "Function"
        case .instanceMethod: "Method"
        case .staticMethod: "Static method"
        case .classMethod: "Class method"
        case .operator: "Operator"
        case .initializer: "Initializer"
        case .deinitializer: "Deinitializer"
        case .subscript: "Subscript"
        case .globalVariable: "Variable"
        case .instanceProperty: "Property"
        case .staticProperty: "Static property"
        case .classProperty: "Class property"
        case .macro: "Macro"
        }
    }

    public var isType: Bool {
        switch self {
        case .class, .struct, .enum, .protocol, .actor: true
        default: false
        }
    }

    public var isFunction: Bool {
        switch self {
        case .function, .instanceMethod, .staticMethod, .classMethod, .operator, .initializer, .subscript: true
        default: false
        }
    }

    public var isVariable: Bool {
        switch self {
        case .globalVariable, .instanceProperty, .staticProperty, .classProperty: true
        default: false
        }
    }
}

public enum Accessibility: String, Codable, Sendable, Comparable {
    case `private`
    case `fileprivate`
    case `internal`
    case `package`
    case `public`
    case `open`

    private var rank: Int {
        switch self {
        case .private: 0
        case .fileprivate: 1
        case .internal: 2
        case .package: 3
        case .public: 4
        case .open: 5
        }
    }

    public static func < (lhs: Accessibility, rhs: Accessibility) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct Declaration: Sendable {
    public typealias ID = Int

    public let id: ID
    public var kind: DeclarationKind
    public var name: String
    /// A declaration has several USRs when the same source is compiled into
    /// several modules (e.g. a file shared by an app and an extension target).
    public var usrs: [String]
    public var location: SourceLocation
    public var modules: Set<String>
    public var parent: ID?
    public var children: [ID] = []
    /// Declared by the compiler or a macro rather than written in source.
    public var isImplicit: Bool
    /// Attribute names without the leading `@`, e.g. `objc`, `main`, `IBAction`.
    public var attributes: Set<String> = []
    /// Declaration modifiers, e.g. `override`, `static`, `public`, `dynamic`.
    public var modifiers: Set<String> = []
    /// The accessibility written in source, if any.
    public var explicitAccessibility: Accessibility?
    /// Whether this declaration may appear in results at all.
    public var isReportable: Bool = true

    public init(
        id: ID,
        kind: DeclarationKind,
        name: String,
        usrs: [String],
        location: SourceLocation,
        modules: Set<String>,
        parent: ID? = nil,
        isImplicit: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.usrs = usrs
        self.location = location
        self.modules = modules
        self.parent = parent
        self.isImplicit = isImplicit
    }
}
