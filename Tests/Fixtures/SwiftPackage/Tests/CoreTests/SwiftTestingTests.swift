import Testing
@testable import Core

@Test func swiftTestingFunction() {
    #expect(Greeter().greet("b") == "Hello, b")
}

@Suite struct GreeterSuite {
    @Test func inSuite() {
        #expect(!makeNames().isEmpty)
    }

    func unusedSuiteHelper() {} // expect: unused
}

/// The macro expansion names of these tests mangle `Test` with a word substitution.
@Suite struct TestNamesWithTestInThem {
    @Test func detectsTestModules() {}
}

struct SuiteWithInitializer {
    let greeter: Greeter

    init() {
        greeter = Greeter()
    }

    init(unused: Int) { // expect: unused
        greeter = Greeter()
    }

    @Test func greets() {
        #expect(!greeter.greet("c").isEmpty)
    }
}
