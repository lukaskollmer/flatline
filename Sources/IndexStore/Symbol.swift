public enum SymbolKind: UInt32, Sendable {
    case unknown = 0
    case module = 1
    case namespace = 2
    case namespaceAlias = 3
    case macro = 4
    case `enum` = 5
    case `struct` = 6
    case `class` = 7
    case `protocol` = 8
    case `extension` = 9
    case union = 10
    case `typealias` = 11
    case function = 12
    case variable = 13
    case field = 14
    case enumConstant = 15
    case instanceMethod = 16
    case classMethod = 17
    case staticMethod = 18
    case instanceProperty = 19
    case classProperty = 20
    case staticProperty = 21
    case constructor = 22
    case destructor = 23
    case conversionFunction = 24
    case parameter = 25
    case using = 26
    case concept = 27
    case commentTag = 1000
}

public enum SymbolSubkind: UInt32, Sendable {
    case none = 0
    case cxxCopyConstructor = 1
    case cxxMoveConstructor = 2
    case accessorGetter = 3
    case accessorSetter = 4
    case usingTypename = 5
    case usingValue = 6
    case usingEnum = 7
    case swiftAccessorWillSet = 1000
    case swiftAccessorDidSet = 1001
    case swiftAccessorAddressor = 1002
    case swiftAccessorMutableAddressor = 1003
    case swiftExtensionOfStruct = 1004
    case swiftExtensionOfClass = 1005
    case swiftExtensionOfEnum = 1006
    case swiftExtensionOfProtocol = 1007
    case swiftPrefixOperator = 1008
    case swiftPostfixOperator = 1009
    case swiftInfixOperator = 1010
    case swiftSubscript = 1011
    case swiftAssociatedType = 1012
    case swiftGenericTypeParam = 1013
    case swiftAccessorRead = 1014
    case swiftAccessorModify = 1015
    case swiftAccessorInit = 1016
    case swiftAccessorBorrow = 1017
    case swiftAccessorMutate = 1018
}

public enum SymbolLanguage: UInt32, Sendable {
    case c = 0
    case objc = 1
    case cxx = 2
    case swift = 100
    case unknown = 0xFFFF_FFFF
}

public struct SymbolProperties: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let generic = SymbolProperties(rawValue: 1 << 0)
    public static let templatePartialSpecialization = SymbolProperties(rawValue: 1 << 1)
    public static let templateSpecialization = SymbolProperties(rawValue: 1 << 2)
    public static let unitTest = SymbolProperties(rawValue: 1 << 3)
    public static let ibAnnotated = SymbolProperties(rawValue: 1 << 4)
    public static let ibOutletCollection = SymbolProperties(rawValue: 1 << 5)
    public static let gkInspectable = SymbolProperties(rawValue: 1 << 6)
    public static let local = SymbolProperties(rawValue: 1 << 7)
    public static let protocolInterface = SymbolProperties(rawValue: 1 << 8)
    public static let swiftAsync = SymbolProperties(rawValue: 1 << 16)
}

public struct SymbolRoles: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let declaration = SymbolRoles(rawValue: 1 << 0)
    public static let definition = SymbolRoles(rawValue: 1 << 1)
    public static let reference = SymbolRoles(rawValue: 1 << 2)
    public static let read = SymbolRoles(rawValue: 1 << 3)
    public static let write = SymbolRoles(rawValue: 1 << 4)
    public static let call = SymbolRoles(rawValue: 1 << 5)
    public static let dynamic = SymbolRoles(rawValue: 1 << 6)
    public static let addressOf = SymbolRoles(rawValue: 1 << 7)
    public static let implicit = SymbolRoles(rawValue: 1 << 8)
    public static let undefinition = SymbolRoles(rawValue: 1 << 19)
    public static let nameReference = SymbolRoles(rawValue: 1 << 20)

    public static let childOf = SymbolRoles(rawValue: 1 << 9)
    public static let baseOf = SymbolRoles(rawValue: 1 << 10)
    public static let overrideOf = SymbolRoles(rawValue: 1 << 11)
    public static let receivedBy = SymbolRoles(rawValue: 1 << 12)
    public static let calledBy = SymbolRoles(rawValue: 1 << 13)
    public static let extendedBy = SymbolRoles(rawValue: 1 << 14)
    public static let accessorOf = SymbolRoles(rawValue: 1 << 15)
    public static let containedBy = SymbolRoles(rawValue: 1 << 16)
    public static let ibTypeOf = SymbolRoles(rawValue: 1 << 17)
    public static let specializationOf = SymbolRoles(rawValue: 1 << 18)
}

public struct Symbol: Hashable, Sendable {
    public let usr: String
    public let name: String
    public let kind: SymbolKind
    public let subkind: SymbolSubkind
    public let properties: SymbolProperties
    public let language: SymbolLanguage

    public init(
        usr: String,
        name: String,
        kind: SymbolKind,
        subkind: SymbolSubkind = .none,
        properties: SymbolProperties = [],
        language: SymbolLanguage = .swift
    ) {
        self.usr = usr
        self.name = name
        self.kind = kind
        self.subkind = subkind
        self.properties = properties
        self.language = language
    }
}

public struct SymbolRelation: Sendable {
    public let roles: SymbolRoles
    public let symbol: Symbol
}

public struct SymbolOccurrence: Sendable {
    public let symbol: Symbol
    public let roles: SymbolRoles
    /// 1-based line.
    public let line: Int
    /// 1-based UTF-8 column.
    public let column: Int
    public let relations: [SymbolRelation]
}
