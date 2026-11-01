@resultBuilder
enum ListBuilder {
    static func buildBlock(_ items: String...) -> [String] { items }
    static func buildOptional(_ items: [String]?) -> [String] { items ?? [] }
}

func makeList(@ListBuilder _ content: () -> [String]) -> [String] {
    content()
}

@dynamicMemberLookup
struct Config {
    var values: [String: String]

    subscript(dynamicMember key: String) -> String? {
        values[key]
    }
}

struct Multiplier {
    let factor: Int

    func callAsFunction(_ value: Int) -> Int { value * factor }
}

@available(*, unavailable)
func unavailableFunction() {}

@_cdecl("flatline_fixture_exported")
func exportedToC() {}
