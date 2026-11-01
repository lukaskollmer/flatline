protocol Shape {
    var area: Double { get }
    func unusedRequirement() // expect: unused
}

struct Square: Shape {
    let side: Double
    var area: Double { side * side }
    func unusedRequirement() {} // expect: unused
}

struct NeverConstructed: Shape { // expect: unused
    var area: Double { 0 }
    func unusedRequirement() {}
}

func totalArea(_ shapes: [any Shape]) -> Double {
    shapes.map(\.area).reduce(0, +)
}

protocol Describable {
    func describe() -> String
}

extension Describable {
    func describe() -> String { "default" }
    func unusedHelper() {} // expect: unused
}

struct UsesDefault: Describable {}

func describeAll(_ items: [any Describable]) -> [String] {
    items.map { $0.describe() }
}

protocol Redundant { // expect: redundantProtocol
    func redundantRequirement()
}

struct ConformsToRedundant: Redundant {
    func redundantRequirement() {} // expect: unused
}

protocol Store {
    associatedtype Item
    func items() -> [Item]
}

struct IntStore: Store {
    typealias Item = Int
    func items() -> [Int] { [1] }
}

func firstItem<S: Store>(of store: S) -> S.Item? {
    store.items().first
}

protocol Animal {
    func sound() -> String
}

protocol Pet: Animal {
    var name: String { get }
}

final class Dog: Pet {
    let name = "Rex"
    func sound() -> String { "Woof" }
}

func greetPet(_ pet: some Pet) -> String {
    "\(pet.name): \(pet.sound())"
}
