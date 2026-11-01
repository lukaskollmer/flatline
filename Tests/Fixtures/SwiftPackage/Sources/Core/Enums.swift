enum Direction {
    case north
    case south
    case unusedCase // expect: unused
}

enum Planet: Int, CaseIterable {
    case mercury
    case venus
}

enum Status: String {
    case active
    case inactive
}

enum Unrelated: String {
    case one
    case two // expect: unused
}

func parse(_ text: String) -> Status? {
    Status(rawValue: text)
}

func useEnums() -> Int {
    let direction = Direction.north
    if direction == .south {
        return 2
    }
    return Planet.allCases.count + Unrelated.one.rawValue.count
}
