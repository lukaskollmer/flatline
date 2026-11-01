public func formatGreeting(for name: String) -> String {
    "Hello, \(capitalized(name))!"
}

func capitalized(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
}

public func unusedUtility() {} // expect: unused
