import XCTest
import AppKit
@testable import Handle

@MainActor
final class GeneralTests: XCTestCase {
    func testEditMenu() {
        agentLog.info("selftest menu dump: \(NSApp.mainMenu?.items.map { "\($0.title)/\($0.submenu?.title ?? "-")" }.joined(separator: ", ") ?? "NO MAIN MENU", privacy: .public)")
        let editMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }
        XCTAssertNotNil(editMenu, "edit menu installed")
        XCTAssertTrue(editMenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } == true, "edit menu paste wired")
        XCTAssertTrue(editMenu?.items.contains { $0.action == #selector(NSText.selectAll(_:)) } == true, "edit menu selectall wired")
    }

    func testTheBCorruptedTheOffset() {
        XCTAssertEqual(RepeatGuard.signature(name: "t", args: ["s": "2026-07-15T00:00:00+02: soul"]), RepeatGuard.signature(name: "t", args: ["s": "2026-07-15T00:00:00+02:00"]), "sig corrupt offset matches clean")
    }
}
