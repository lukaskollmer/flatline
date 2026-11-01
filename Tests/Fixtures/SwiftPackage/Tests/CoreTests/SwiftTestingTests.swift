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
