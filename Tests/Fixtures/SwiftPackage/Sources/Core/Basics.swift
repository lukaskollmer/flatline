public struct Greeter {
    public init() {}
    public func greet(_ name: String) -> String { "Hello, \(name)" }
    func unusedMethod() {} // expect: unused
}

extension Greeter {
    public func shout(_ name: String) -> String { greet(name).uppercased() }
    func unusedExtensionMethod() {} // expect: unused
}

final class UnusedClass { // expect: unused
    func methodOfUnusedClass() {}
}

struct OnlyUsedByUnused {} // expect: unused

func unusedFunction() -> OnlyUsedByUnused { OnlyUsedByUnused() } // expect: unused

let unusedGlobal = 42 // expect: unused

typealias UnusedAlias = Int // expect: unused

public typealias Names = [String]

public func makeNames() -> Names { ["a", "b"] }

enum Namespace {
    static let used = "used"
    static let unused = "unused" // expect: unused

    enum Nested { // expect: unused
        static let value = 1
    }
}

extension String {
    var usedExtensionOnExternalType: Int { count * 2 }
    var unusedExtensionOnExternalType: Int { count } // expect: unused
}

func onlyUsedByTests() -> Int { 1 }

let (tupleUsed, tupleUnused) = (1, 2) // expect: unused(tupleUnused)
