public struct PublicUsed {
    public init() {}
    public func run() {}
}

public struct PublicOnlyInternal { // expect: redundantPublicAccessibility
    public init() {} // expect: redundantPublicAccessibility
}

public struct PublicReturnType {
    public init() {}
}

public func requiresPublicReturn() -> PublicReturnType {
    PublicReturnType()
}

public func unusedPublicFunction() {} // expect: unused
