import XCTest
import AppKit
@testable import Handle

final class ToolCallParsingTests: AppTestCase {
    func testParseToolCall() {
        check("parse ```json fence", app.parseToolCall("```json\n{\"name\":\"point_at\",\"arguments\":{\"index\":3}}\n```")?.name == "point_at")
        check("parse <tool_call> tags", app.parseToolCall("<tool_call>{\"name\":\"point_at\",\"arguments\":{\"index\":3}}</tool_call>")?.name == "point_at")
        check("parse bare json + prose", ((app.parseToolCall("It's here: {\"name\":\"point_at\",\"arguments\":{\"index\":7}}")?.args["index"]) as? NSNumber)?.intValue == 7)
        check("parse prose-only → nil", app.parseToolCall("the back button is in the top-left") == nil)
    }

    func testIntArgCoercion() {
        check("intArg number", AppDelegate.intArg(7 as NSNumber) == 7)
        check("intArg string", AppDelegate.intArg("16") == 16)
        check("intArg spaced string", AppDelegate.intArg(" 3 ") == 3)
        check("intArg garbage → nil", AppDelegate.intArg("nope") == nil)
        check("intArg nil → nil", AppDelegate.intArg(nil) == nil)
        check("parse+coerce string index", AppDelegate.intArg(app.parseToolCall("```json\n{\"name\":\"point_at\",\"arguments\":{\"index\":\"16\"}}\n```")?.args["index"]) == 16)
        check("parse brace inside string value", app.parseToolCall("{\"name\":\"point_at\",\"arguments\":{\"index\":3},\"note\":\"press }\"}")?.name == "point_at")
    }
}
