import XCTest
import AppKit
@testable import Handle

final class GeneralTests: AppTestCase {
    func testEditMenu() {
        agentLog.info("selftest menu dump: \(NSApp.mainMenu?.items.map { "\($0.title)/\($0.submenu?.title ?? "-")" }.joined(separator: ", ") ?? "NO MAIN MENU", privacy: .public)")
        let editMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }
        check("edit menu installed", editMenu != nil)
        check("edit menu paste wired", editMenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } == true)
        check("edit menu selectall wired", editMenu?.items.contains { $0.action == #selector(NSText.selectAll(_:)) } == true)
    }

    func testTheBCorruptedTheOffset() {
        check("sig corrupt offset matches clean", AppDelegate.callSignature(name: "t", args: ["s": "2026-07-15T00:00:00+02: soul"]) == AppDelegate.callSignature(name: "t", args: ["s": "2026-07-15T00:00:00+02:00"]))
    }
}
