import XCTest
@testable import Handle

/// Base class for tests that need the app delegate.
@MainActor
class AppTestCase: XCTestCase {
    let app = AppDelegate()
}
