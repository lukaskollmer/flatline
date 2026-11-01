import XCTest
@testable import Core

final class CoreTests: XCTestCase {
    func testGreeter() {
        XCTAssertEqual(Greeter().greet("a"), "Hello, a")
    }

    func testOnlyUsedByTests() {
        XCTAssertEqual(onlyUsedByTests(), 1)
    }

    func unusedHelper() {} // expect: unused

    override func setUp() {
        super.setUp()
    }
}
