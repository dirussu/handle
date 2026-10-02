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
        check("rank: button first", ranked.first?.label == "Back")
        check("dedup: one Documents", ranked.filter { $0.label == "Documents" }.count == 1)
        check("dedup: count 3", ranked.count == 3)
        // promptAsksToPoint gating (#3 — only pointing turns send candidates/dispatch)
        check("asksToPoint where", app.promptAsksToPoint("where is the back button"))
        check("asksToPoint show me", app.promptAsksToPoint("show me the sidebar"))
        check("asksToPoint explain→false", !app.promptAsksToPoint("explain what's on screen"))
        check("asksToPoint haiku→false", !app.promptAsksToPoint("write a haiku about cats"))
        // candidate list: prompt indices align with element order + labels present
        let instr = app.pointAtToolInstruction(elements: [
            AXElement(role: "AXButton", label: "Back", frame: f, value: nil),
            AXElement(role: "AXTextField", label: "Search", frame: f, value: nil),
        ])
        check("instr [0] Back", instr.contains("[0] Button \"Back\""))
        check("instr [1] Search", instr.contains("[1] TextField \"Search\""))
        check("instr has decline path (-1)", instr.contains("index -1"))
        check("dispatch declines on -1", AppDelegate.intArg(-1 as NSNumber) == -1)   // -1 parses; dispatch guards idx<0
        check("instr empty→\"\"", app.pointAtToolInstruction(elements: []).isEmpty)
    }

    func testWebText() {
        check("web: html → text", { let t = WebTools.textFromHTML("<html><head><title>Hi &amp; bye</title><style>x{}</style><script>bad()</script></head><body><h1>Head</h1><p>one&nbsp;two</p><!-- c --><div>three</div></body></html>"); return t.hasPrefix("Title: Hi & bye") && t.contains("Head\n") && t.contains("one two") && !t.contains("bad()") && !t.contains("x{}") }())
        check("mcp loop: tool names sanitised + capped", MCPLoopTools.toolName(server: "github", name: "create_issue") == "mcp__github__create_issue" && MCPLoopTools.toolName(server: "my server", name: "do.it!") == "mcp__my_server__do_it_" && MCPLoopTools.toolName(server: String(repeating: "s", count: 40), name: String(repeating: "n", count: 40)).count == 64)
        check("mcp loop: map round-trips + object schema", { let (tools, map) = MCPLoopTools.make([MCPToolInfo(server: "s", name: "t", description: "d", schema: [:])]); return tools.count == 1 && tools[0].confirmation == .confirm && map[tools[0].name]?.name == "t" && (tools[0].inputSchema["type"] as? String) == "object" }())
        check("recipes: candidates line names ids + params", { let r = Recipe(id: "set-volume", title: "Set volume", description: "Sets it", keywords: ["volume"], params: [RecipeParam(name: "level", type: .int, prompt: "0-100")], confirmTemplate: "x", body: "y"); let line = AppDelegate.recipeCandidatesLine(for: "set the volume", recipes: [r]); return line.contains("run_recipe") && line.contains("- set-volume — Set volume") && line.contains("level (a number)") && AppDelegate.recipeCandidatesLine(for: "zzz", recipes: [r]).isEmpty }())
        check("anthropic: server tool passthrough", (AnthropicProvider.encodeTool(WebSettings.anthropicSearchSpec)["type"] as? String) == "web_search_20260209" && AnthropicProvider.encodeTool(WebSettings.anthropicSearchSpec)["input_schema"] == nil)
        check("openai: server tools dropped", OpenAIProvider.body(for: AIRequest(messages: [.user("u")], tools: [WebSettings.anthropicSearchSpec]), model: "m", includeTools: true)["tools"] == nil)
    }

    func testPermissionsHelpers() {
        check("tellTargets multi+dedupe", PermissionsService.tellTargets(in:
            "tell application \"Music\" to play\ntell application \"Finder\" to activate\ntell application \"music\" to pause") == ["Music", "Finder"])
        check("tellTargets id form", PermissionsService.tellTargets(in: "tell application id \"com.apple.Music\" to play") == ["com.apple.Music"])
        check("tellTargets none", PermissionsService.tellTargets(in: "set volume output volume 20").isEmpty)
        check("mapAE granted", PermissionsService.mapAEStatus(noErr) == .granted)
        check("mapAE denied", PermissionsService.mapAEStatus(OSStatus(errAEEventNotPermitted)) == .denied)
        check("mapAE notRunning", PermissionsService.mapAEStatus(OSStatus(procNotFound)) == .unavailable("App not running"))
        check("settings url", PermissionsService.settingsURL(pane: "Privacy_Automation").absoluteString.hasSuffix("Privacy_Automation"))
    }

    func testClickPathGating() {
        check("asksToClick click", app.promptAsksToClick("click the send button"))
        check("asksToClick press", app.promptAsksToClick("press the OK button"))
        check("asksToClick tap", app.promptAsksToClick("tap the compose icon"))
        check("asksToClick where→false", !app.promptAsksToClick("where is the send button"))
        check("asksToClick explain→false", !app.promptAsksToClick("explain what's on screen"))
        check("asksToPoint click→false now", !app.promptAsksToPoint("click on the send button"))
        check("asksToPoint where still", app.promptAsksToPoint("where is the send button"))
    }
}
