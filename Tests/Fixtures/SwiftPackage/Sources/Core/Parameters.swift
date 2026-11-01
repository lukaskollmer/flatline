func unusedParameter(used: Int, unused: Int) -> Int { used } // expect: unusedParameter(unused)

func underscored(_ value: Int, _: Int) -> Int { value }

func usedInClosure(_ value: Int) -> () -> Int { { value } }

func usedInOptionalBinding(_ value: Int?) -> Int {
    if let value { return value }
    return 0
}

func usedInInterpolation(_ name: String) -> String { "Hi \(name)" }

func stub(_ value: Int) -> Int { fatalError("not implemented") }

func emptyBody(_ value: Int) {}

// flatline:ignore:parameters ignored
func ignoredParameter(_ ignored: Int, other: Int) -> Int { 0 } // expect: unusedParameter(other)

func passedAsValue(_ value: Int) -> Int { 0 }

protocol Handler {
    func handle(_ event: Int)
}

struct NoopHandler: Handler {
    func handle(_ event: Int) { print("noop") }
}

class BaseHandler {
    func handle(value: Int) { print("base") }
}

final class SubHandler: BaseHandler {
    override func handle(value: Int) { print(value) }
}

struct Initializer {
    init(unusedLabel: Int) { print("init") } // expect: unusedParameter(unusedLabel)
}
