final class Counter {
    nonisolated(unsafe) static var shared = Counter()

    var count = 0
    var lastUpdated = 0 // expect: assignOnlyProperty
    var observed = 0 {
        didSet { print("changed") }
    }
    lazy var expensive = [1, 2, 3]

    func increment() {
        count += 1
        lastUpdated = count
        observed = count
    }
}

@propertyWrapper
struct Clamped {
    private var value: Int
    let range: ClosedRange<Int>

    init(wrappedValue: Int, _ range: ClosedRange<Int>) {
        self.range = range
        value = min(max(wrappedValue, range.lowerBound), range.upperBound)
    }

    var wrappedValue: Int {
        get { value }
        set { value = min(max(newValue, range.lowerBound), range.upperBound) }
    }

    var projectedValue: ClosedRange<Int> { range }
}

struct Volume {
    @Clamped(0 ... 10) var level: Int = 5
}
