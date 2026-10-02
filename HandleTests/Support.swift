import XCTest
@testable import Handle

/// A named expectation: fails the test with `name` when the condition is false.
func check(_ name: String, _ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(condition(), name, file: file, line: line)
}

/// Base class for tests that need the app delegate's pure helpers.
@MainActor
class AppTestCase: XCTestCase {
    let app = AppDelegate()
}
