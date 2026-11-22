// Also compiled into Tool, which has its own copy only with the Fancy trait.
#if VALUES || Fancy
public func value() -> Int {
    1
}
#endif

// Tool has its own copy in every variant, so no module uses another's.
public func ownValue() -> Int { // expect: redundantPublicAccessibility
    2
}
