class Vehicle {
    func describe() -> String { "vehicle" }
    func neverCalled() {} // expect: unused
    deinit {}
}

final class Car: Vehicle {
    override func describe() -> String { "car" }
}

final class Bike: Vehicle { // expect: unused
    override func describe() -> String { "bike" }
}

func describeVehicle(_ vehicle: Vehicle) -> String {
    vehicle.describe()
}

class Base {
    func template() -> Int { 1 }
}

final class Sub: Base {
    override func template() -> Int { 2 }
}

struct Point {
    let x: Int
    let y: Int

    init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    init(both: Int) { // expect: unused
        self.init(x: both, y: both)
    }
}
