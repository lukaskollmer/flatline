import FlatlineCore
import IndexStore

enum SymbolClassification {
    case declaration(DeclarationKind)
    /// Getters, setters, observers etc. are folded into their property.
    case accessor
    case ignored
}

extension Symbol {
    var classification: SymbolClassification {
        if properties.contains(.local) {
            return .ignored
        }
        switch subkind {
        case .accessorGetter, .accessorSetter, .swiftAccessorWillSet, .swiftAccessorDidSet,
             .swiftAccessorAddressor, .swiftAccessorMutableAddressor, .swiftAccessorRead,
             .swiftAccessorModify, .swiftAccessorInit, .swiftAccessorBorrow, .swiftAccessorMutate:
            return .accessor
        case .swiftGenericTypeParam:
            return .ignored
        case .swiftPrefixOperator, .swiftInfixOperator, .swiftPostfixOperator:
            return .declaration(.operator)
        case .swiftSubscript:
            return .declaration(.subscript)
        case .swiftAssociatedType:
            return .declaration(.associatedType)
        default:
            break
        }
        switch kind {
        case .class: return .declaration(.class)
        case .struct: return .declaration(.struct)
        case .enum: return .declaration(.enum)
        case .protocol: return .declaration(.protocol)
        case .extension: return .declaration(.extension)
        case .typealias: return .declaration(.typealias)
        case .enumConstant: return .declaration(.enumCase)
        case .function: return .declaration(.function)
        case .instanceMethod: return .declaration(.instanceMethod)
        case .staticMethod: return .declaration(.staticMethod)
        case .classMethod: return .declaration(.classMethod)
        case .constructor: return .declaration(.initializer)
        case .destructor: return .declaration(.deinitializer)
        case .variable: return .declaration(.globalVariable)
        case .instanceProperty: return .declaration(.instanceProperty)
        case .staticProperty: return .declaration(.staticProperty)
        case .classProperty: return .declaration(.classProperty)
        case .macro: return .declaration(.macro)
        default: return .ignored
        }
    }
}

/// USRs and names of standard library and SDK symbols that rules depend on.
enum KnownSymbols {
    static let encodable = "s:SE"
    static let decodable = "s:Se"
    static let equatable = "s:SQ"
    static let hashable = "s:SH"
    static let caseIterable = "s:s12CaseIterableP"
    static let codingKey = "s:s9CodingKeyP"
    static let xcTestCase = "c:objc(cs)XCTestCase"
    static let previewProvider = "s:7SwiftUI15PreviewProviderP"

    /// Attributes that expose a declaration to Objective-C or Interface Builder.
    static let objcAttributes: Set<String> = [
        "objc", "objcMembers", "IBAction", "IBOutlet", "IBInspectable", "IBSegueAction",
        "IBDesignable", "NSManaged", "GKInspectable",
    ]

    /// Attributes that make a declaration callable from outside Swift's view.
    static let exportAttributes: Set<String> = ["_cdecl", "_silgen_name", "_dynamicReplacement", "_expose"]

    static let entryPointAttributes: Set<String> = ["main", "UIApplicationMain", "NSApplicationMain"]

    /// Attributes on a variable that don't change what assigning to it does.
    static let inertVariableAttributes: Set<String> = [
        "available", "MainActor", "nonobjc", "usableFromInline", "inlinable", "preconcurrency", "TaskLocal",
    ]
}

extension String {
    /// Names produced by macro expansion, e.g. `$s4Main3FooV4TestfMp_...`.
    var isMacroExpansionName: Bool {
        hasPrefix("$s") && contains("fM")
    }

    /// The USR clang uses for an `@objc` Swift declaration: Swift records
    /// `c:@M@Module@objc(cs)Name`, Objective-C code refers to `c:objc(cs)Name`.
    var objcUSRWithoutModule: String? {
        guard hasPrefix("c:@M@"), let range = range(of: "@objc(") else { return nil }
        return "c:" + self[index(after: range.lowerBound)...]
    }
}
