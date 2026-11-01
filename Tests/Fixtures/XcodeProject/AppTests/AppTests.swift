import XCTest
@testable import App

final class AppTests: XCTestCase {
    func testSettings() {
        XCTAssertFalse(Settings().onlyUsedByTests())
    }
}
