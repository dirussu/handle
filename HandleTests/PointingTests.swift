import XCTest
import AppKit
@testable import Handle

final class PointingTests: AppTestCase {
    func testRankAndDedup() {
        let f = CGRect(x: 0, y: 0, width: 10, height: 10)
        let syn = [
            AXElement(role: "AXStaticText", label: "Documents", frame: f, value: nil),
            AXElement(role: "AXStaticText", label: "Documents", frame: f, value: nil),                          // dupe
            AXElement(role: "AXStaticText", label: "Images", frame: CGRect(x: 20, y: 0, width: 10, height: 10), value: nil),
            AXElement(role: "AXButton", label: "Back", frame: CGRect(x: 40, y: 0, width: 10, height: 10), value: nil),
        ]
        let ranked = AccessibilityProbe.rankAndDedup(syn, limit: 25)
        XCTAssertEqual(ranked.first?.label, "Back", "rank: button first")
        XCTAssertEqual(ranked.filter { $0.label == "Documents" }.count, 1, "dedup: one Documents")
        XCTAssertEqual(ranked.count, 3, "dedup: count 3")
        // Intent.asksToPoint gating (#3 — only pointing turns send candidates/dispatch)
        XCTAssertTrue(Intent.asksToPoint("where is the back button"), "asksToPoint where")
        XCTAssertTrue(Intent.asksToPoint("show me the sidebar"), "asksToPoint show me")
        XCTAssertFalse(Intent.asksToPoint("explain what's on screen"), "asksToPoint explain→false")
        XCTAssertFalse(Intent.asksToPoint("write a haiku about cats"), "asksToPoint haiku→false")
        // candidate list: prompt indices align with element order + labels present
        let instr = app.pointAtToolInstruction(elements: [
            AXElement(role: "AXButton", label: "Back", frame: f, value: nil),
            AXElement(role: "AXTextField", label: "Search", frame: f, value: nil),
        ])
        XCTAssertTrue(instr.contains("[0] Button \"Back\""), "instr [0] Back")
        XCTAssertTrue(instr.contains("[1] TextField \"Search\""), "instr [1] Search")
        XCTAssertTrue(instr.contains("index -1"), "instr has decline path (-1)")
        // -1 parses; dispatch guards idx<0
        XCTAssertEqual(ToolCallParser.intArg(-1 as NSNumber), -1, "dispatch declines on -1")
        XCTAssertTrue(app.pointAtToolInstruction(elements: []).isEmpty, "instr empty→\"\"")
    }

    func testWebText() {
        do {
            let t = WebTools.textFromHTML("<html><head><title>Hi &amp; bye</title><style>x{}</style><script>bad()</script></head><body><h1>Head</h1><p>one&nbsp;two</p><!-- c --><div>three</div></body></html>")
            XCTAssertTrue(t.hasPrefix("Title: Hi & bye"), "web: html → text")
            XCTAssertTrue(t.contains("Head\n"), "web: html → text")
            XCTAssertTrue(t.contains("one two"), "web: html → text")
            XCTAssertFalse(t.contains("bad()"), "web: html → text")
            XCTAssertFalse(t.contains("x{}"), "web: html → text")
        }
        XCTAssertEqual(MCPLoopTools.toolName(server: "github", name: "create_issue"), "mcp__github__create_issue", "mcp loop: tool names sanitised + capped")
        XCTAssertEqual(MCPLoopTools.toolName(server: "my server", name: "do.it!"), "mcp__my_server__do_it_", "mcp loop: tool names sanitised + capped")
        XCTAssertEqual(MCPLoopTools.toolName(server: String(repeating: "s", count: 40), name: String(repeating: "n", count: 40)).count, 64, "mcp loop: tool names sanitised + capped")
        do {
            let (tools, map) = MCPLoopTools.make([MCPToolInfo(server: "s", name: "t", description: "d", schema: [:])])
            XCTAssertEqual(tools.count, 1, "mcp loop: map round-trips + object schema")
            XCTAssertEqual(tools[0].confirmation, .confirm, "mcp loop: map round-trips + object schema")
            XCTAssertEqual(map[tools[0].name]?.name, "t", "mcp loop: map round-trips + object schema")
            XCTAssertEqual((tools[0].inputSchema["type"] as? String), "object", "mcp loop: map round-trips + object schema")
        }
        do {
            let r = Recipe(id: "set-volume", title: "Set volume", description: "Sets it", keywords: ["volume"], params: [RecipeParam(name: "level", type: .int, prompt: "0-100")], confirmTemplate: "x", body: "y")
            let line = AppDelegate.recipeCandidatesLine(for: "set the volume", recipes: [r])
            XCTAssertTrue(line.contains("run_recipe"), "recipes: candidates line names ids + params")
            XCTAssertTrue(line.contains("- set-volume — Set volume"), "recipes: candidates line names ids + params")
            XCTAssertTrue(line.contains("level (a number)"), "recipes: candidates line names ids + params")
            XCTAssertTrue(AppDelegate.recipeCandidatesLine(for: "zzz", recipes: [r]).isEmpty, "recipes: candidates line names ids + params")
        }
        XCTAssertEqual((AnthropicProvider.encodeTool(WebSettings.anthropicSearchSpec)["type"] as? String), "web_search_20260209", "anthropic: server tool passthrough")
        XCTAssertNil(AnthropicProvider.encodeTool(WebSettings.anthropicSearchSpec)["input_schema"], "anthropic: server tool passthrough")
        XCTAssertNil(OpenAIProvider.body(for: AIRequest(messages: [.user("u")], tools: [WebSettings.anthropicSearchSpec]), model: "m", includeTools: true)["tools"], "openai: server tools dropped")
    }

    func testPermissionsHelpers() {
        let script = "tell application \"Music\" to play\ntell application \"Finder\" to activate\ntell application \"music\" to pause"
        XCTAssertEqual(PermissionsService.tellTargets(in: script), ["Music", "Finder"], "tellTargets multi+dedupe")
        XCTAssertEqual(PermissionsService.tellTargets(in: "tell application id \"com.apple.Music\" to play"), ["com.apple.Music"], "tellTargets id form")
        XCTAssertTrue(PermissionsService.tellTargets(in: "set volume output volume 20").isEmpty, "tellTargets none")
        XCTAssertEqual(PermissionsService.mapAEStatus(noErr), .granted, "mapAE granted")
        XCTAssertEqual(PermissionsService.mapAEStatus(OSStatus(errAEEventNotPermitted)), .denied, "mapAE denied")
        XCTAssertEqual(PermissionsService.mapAEStatus(OSStatus(procNotFound)), .unavailable("App not running"), "mapAE notRunning")
        XCTAssertTrue(PermissionsService.settingsURL(pane: "Privacy_Automation").absoluteString.hasSuffix("Privacy_Automation"), "settings url")
    }

    func testClickPathGating() {
        XCTAssertTrue(Intent.asksToClick("click the send button"), "asksToClick click")
        XCTAssertTrue(Intent.asksToClick("press the OK button"), "asksToClick press")
        XCTAssertTrue(Intent.asksToClick("tap the compose icon"), "asksToClick tap")
        XCTAssertFalse(Intent.asksToClick("where is the send button"), "asksToClick where→false")
        XCTAssertFalse(Intent.asksToClick("explain what's on screen"), "asksToClick explain→false")
        XCTAssertFalse(Intent.asksToPoint("click on the send button"), "asksToPoint click→false now")
        XCTAssertTrue(Intent.asksToPoint("where is the send button"), "asksToPoint where still")
    }
}
