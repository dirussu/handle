import XCTest
import AppKit
@testable import Handle

@MainActor
final class ToolCallParsingTests: XCTestCase {
    func testParseToolCall() {
        XCTAssertEqual(ToolCallParser.parse("```json\n{\"name\":\"point_at\",\"arguments\":{\"index\":3}}\n```")?.name, "point_at", "parse ```json fence")
        XCTAssertEqual(ToolCallParser.parse("<tool_call>{\"name\":\"point_at\",\"arguments\":{\"index\":3}}</tool_call>")?.name, "point_at", "parse <tool_call> tags")
        XCTAssertEqual(((ToolCallParser.parse("It's here: {\"name\":\"point_at\",\"arguments\":{\"index\":7}}")?.args["index"]) as? NSNumber)?.intValue, 7, "parse bare json + prose")
        XCTAssertNil(ToolCallParser.parse("the back button is in the top-left"), "parse prose-only → nil")
    }

    func testIntArgCoercion() {
        XCTAssertEqual(ToolCallParser.intArg(7 as NSNumber), 7, "intArg number")
        XCTAssertEqual(ToolCallParser.intArg("16"), 16, "intArg string")
        XCTAssertEqual(ToolCallParser.intArg(" 3 "), 3, "intArg spaced string")
        XCTAssertNil(ToolCallParser.intArg("nope"), "intArg garbage → nil")
        XCTAssertNil(ToolCallParser.intArg(nil), "intArg nil → nil")
        XCTAssertEqual(ToolCallParser.intArg(ToolCallParser.parse("```json\n{\"name\":\"point_at\",\"arguments\":{\"index\":\"16\"}}\n```")?.args["index"]), 16, "parse+coerce string index")
        XCTAssertEqual(ToolCallParser.parse("{\"name\":\"point_at\",\"arguments\":{\"index\":3},\"note\":\"press }\"}")?.name, "point_at", "parse brace inside string value")
    }
}
