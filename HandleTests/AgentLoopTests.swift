import XCTest
import AppKit
@testable import Handle

final class AgentLoopTests: AppTestCase {
    func testToolRegistry() {
        check("registry has run_applescript", ToolRegistry.tool(named: "run_applescript") != nil)
        check("registry unknown → nil", ToolRegistry.tool(named: "nonexistent_tool_xyz") == nil)
        check("registry names nonempty", !ToolRegistry.names.isEmpty)
        check("registry excludes point_at", ToolRegistry.tool(named: "point_at") == nil)
        check("promptSpec names tool", ToolRegistry.tool(named: "run_applescript").map { ToolRegistry.promptSpec(for: [$0]).contains("run_applescript(") } ?? false)
    }

    func testConfirmationRoutingIsTheSafetyProperty() {
        check("reg create_reminder=confirm", ToolRegistry.tool(named: "create_reminder")?.confirmation == .confirm)
        check("reg list_reminders=auto", ToolRegistry.tool(named: "list_reminders")?.confirmation == .auto)
        check("reg delete_file=confirm", ToolRegistry.tool(named: "delete_file")?.confirmation == .confirm)
        check("reg move_file=confirm", ToolRegistry.tool(named: "move_file")?.confirmation == .confirm)
        check("reg read_file=auto", ToolRegistry.tool(named: "read_file")?.confirmation == .auto)
        check("reg write_file=confirm", ToolRegistry.tool(named: "write_file")?.confirmation == .confirm)   // preview before mutation
        check("reg draft_email=confirm", ToolRegistry.tool(named: "draft_email_reply")?.confirmation == .confirm)
        check("reg draft_imessage=confirm", ToolRegistry.tool(named: "draft_imessage")?.confirmation == .confirm)
    }

    func testOnboardingHardwareBar() {
        check("voice: apple silicon ok", Onboarding.voiceSupported(isAppleSilicon: true))
        check("voice: intel unsupported (soft note, no gate)", !Onboarding.voiceSupported(isAppleSilicon: false))
    }

    func testAgentLoopRails() {
        check("agent: stop on step cap", AgentSettings.stopReason(step: 30, maxSteps: 30, spentUSD: 0, budgetUSD: 0.5)?.contains("Step limit") == true && AgentSettings.stopReason(step: 29, maxSteps: 30, spentUSD: 0, budgetUSD: 0.5) == nil)
        check("agent: stop on budget", AgentSettings.stopReason(step: 3, maxSteps: 30, spentUSD: 0.6, budgetUSD: 0.5)?.contains("budget") == true)
        check("agent: zero budget = unlimited", AgentSettings.stopReason(step: 3, maxSteps: 30, spentUSD: 99, budgetUSD: 0) == nil)
        check("agent: repeat guard counts consecutive only", { var g = RepeatGuard(); return g.observe("a") == 1 && g.observe("a") == 2 && g.observe("b") == 1 && g.observe("a") == 1 && g.observe("a") == 2 && g.observe("a") == 3 }())
        check("agent: older screenshots stripped from history", { let h = [AIMessage(role: .user, parts: [.toolResult(id: "1", text: "shot", isError: false, image: Data([1]))]), AIMessage(role: .user, parts: [.text("x")])]; let r = AgentPrompting.stripImages(from: h); if case .toolResult(_, let t, _, let img) = r[0].parts[0] { return img == nil && t.contains("omitted") && r[1].text == "x" } else { return false } }())
        check("anthropic: image tool result is a block list", { let p = AnthropicProvider.encodePart(.toolResult(id: "t", text: "ok", isError: false, image: Data([1, 2]))); return ((p?["content"] as? [[String: Any]])?.last?["type"] as? String) == "image" && (AnthropicProvider.encodePart(.toolResult(id: "t", text: "ok", isError: false))?["content"] as? String) == "ok" }())
        check("openai: image tool result → trailing user image", { let m = OpenAIProvider.encodeMessages([AIMessage(role: .user, parts: [.toolResult(id: "c", text: "ok", isError: false, image: Data([1]))])]); return m.count == 2 && (m[0]["role"] as? String) == "tool" && (m[1]["role"] as? String) == "user" }())
        check("turn output: call = calls.first", TurnOutput(text: "", calls: [AgentToolCall(id: "a", name: "x", args: [:]), AgentToolCall(id: "b", name: "y", args: [:])]).call?.name == "x" && TurnOutput(text: "", call: nil).calls.isEmpty)
        check("toolspec native: several calls, several steps", app.actionToolInstruction(native: true).contains("several in one step") && app.actionToolInstruction(native: true).contains("say what is done and what is not"))
    }

    func testPolicies() {
        check("policy: json round trip + defaults", { let p = AgentPolicy(allowedTools: ["a"], maxSteps: 7, budgetUSD: 0.1, standingConsent: true); let d = try! JSONEncoder().encode(p); return try! JSONDecoder().decode(AgentPolicy.self, from: d) == p && AgentPolicy().maxSteps == 15 && !AgentPolicy().standingConsent }())
        check("policy: child never gains consent or exceeds parent", { let c = AgentPolicy(maxSteps: 8, budgetUSD: 1.0, standingConsent: true).child(allowedTools: ["x"], maxSteps: 30); return c.maxSteps == 8 && c.budgetUSD == 0.25 && !c.standingConsent && c.depth == 1 && c.allows("x") && !c.allows("y") && AgentPolicy().allows("anything") }())
        check("policy: child tool list is parent ∩ requested", { let p = AgentPolicy(allowedTools: ["a", "b"]); let c = p.child(allowedTools: ["b", "c"], maxSteps: 5, label: "L"); let d = p.child(allowedTools: nil, maxSteps: 5); return c.allows("b") && !c.allows("a") && !c.allows("c") && d.allows("a") && !d.allows("z") && c.label == "L" && c.effort == .medium && AgentPolicy().child(allowedTools: ["q"], maxSteps: 3).allows("q") }())
        check("policy: effort + label round trip", { var p = AgentPolicy(); p.effort = .high; p.label = "routine:X"; let d = try! JSONEncoder().encode(p); return try! JSONDecoder().decode(AgentPolicy.self, from: d) == p }())
        check("anthropic: strict only for our schemas", (AnthropicProvider.encodeTool(AgentPrompting.pointAtSpec)["strict"] as? Bool) == true && AnthropicProvider.encodeTool(AIToolSpec(name: "mcp_x", description: "d", inputSchema: ["type": "object"]))["strict"] == nil)
        check("agent run: defaults", { let r = AgentRun(text: "t"); return r.costUSD == 0 && !r.cancelled && TurnOutput(text: "", calls: []).usage == nil }())
    }

    func testKillSwitchAuditParsing() {
        check("ledger: cancelAll marks running tasks", { let l = TaskLedger(); let id = l.start(goal: "g"); l.attach(id: id, task: Task { }); l.cancelAll(); return l.entries.first?.status == .cancelled && l.running.isEmpty && l.entries.first?.result == "Cancelled." }())
        check("audit: parseLine", { let r = AuditLog.parseLine(#"{"ts":"2026-09-20T09:00:00Z","tool":"routine:Morning","outcome":"ok","summary":"$0.01 · fine"}"#); return r?.tool == "routine:Morning" && r?.outcome == "ok" && AuditLog.parseLine("nope") == nil }())
        check("errors: provider ids read as names", AIProviderError.keyRejected(provider: "openai").errorDescription?.hasPrefix("OpenAI rejected") == true && AIProviderError.noAPIKey(provider: "anthropic").errorDescription?.contains("No Anthropic API key") == true)
        check("identity: local endpoint never claims a cloud", { let t = AgentPrompting.identity(providerName: "a local model server (localhost)", localEndpoint: true); return t.contains("runs on this Mac too") && !t.contains("own API key") }())
        check("aistate: every non-ready state explains itself", [AIState.notChosen, .missingKey(.anthropic), .unavailable(.openai)].allSatisfy { $0.userMessage?.contains("Settings → AI") == true } && AIState.ready(.anthropic).userMessage == nil)
        check("see: unsupported-vision caption + note", ScreenshotStatus.withheldUnsupported.caption.contains("can't see images") && SeeSettings.unsupportedNote.contains("No screenshot"))
        check("cost: sonnet 5 1M in = $2", AICost.estimate(model: "claude-sonnet-5", input: 1_000_000, output: 0) == 2.0)
        check("cost: cache read is 10% of input", AICost.estimate(model: "claude-sonnet-5", input: 0, output: 0, cacheRead: 1_000_000) == 0.2)
        check("cost: unknown model = nil", AICost.estimate(model: "mystery", input: 10, output: 10) == nil)
        check("key hint shows last 4 only", SecretStore.hint(for: "sk-ant-abcdef1234") == "••••1234" && SecretStore.hint(for: "") == "")
    }

    func testSeeConsent() {
        check("see: excluded match is case-insensitive", SeeSettings.isExcluded("COM.1password.1password", in: ["com.1password.1password"]))
        check("see: nil / empty / unlisted are not excluded", !SeeSettings.isExcluded(nil, in: ["a"]) && !SeeSettings.isExcluded("", in: ["a"]) && !SeeSettings.isExcluded("b", in: ["a"]))
        check("see: captions name the app / provider", ScreenshotStatus.withheldExcluded(app: "1Password").caption.contains("1Password") && ScreenshotStatus.sent(provider: "Anthropic").caption.contains("Anthropic") && ScreenshotStatus.withheldDeclined.symbol == "eye.slash")
        check("see: excluded note names the app", SeeSettings.excludedNote(app: "Bank").contains("Bank") && SeeSettings.excludedNote(app: "Bank").contains("NOT captured"))
        do {
            let ctx = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            let big = ctx.makeImage()!
            let jpeg = AIImage.jpegData(big)!
            let thumb = SentRecord.thumbnail(from: jpeg)
            check("sent: thumbnail ≤ 240px, keeps aspect", thumb.map { $0.width == 240 && $0.height == 160 } == true)
            let req = AIRequest(messages: [.system("S"), AIMessage(role: .user, parts: [.image(jpeg, mime: "image/jpeg"), .text("CTX\n\nwhat is this?")])], label: nil)
            let rec = SentRecord.skeleton(for: req, provider: "anthropic", model: "claude-sonnet-5")
            check("sent: skeleton takes last line as label + image bytes", rec.label == "what is this?" && rec.imageBytes == jpeg.count && rec.imageThumbnail != nil)
            check("sent: explicit label wins, cost nil before usage", SentRecord.skeleton(for: AIRequest(messages: [.user("x")], label: "one-shot · pick"), provider: "anthropic", model: "mystery").label == "one-shot · pick" && SentRecord.skeleton(for: req, provider: "anthropic", model: "mystery").cost == nil)
        }
    }

    func testAgentLoopRoutingResultFormatting() {
        check("asksToAct again", app.promptAsksToAct("look again at the screen"))
        check("asksToAct open", app.promptAsksToAct("open my downloads"))
        check("asksToAct calendar", app.promptAsksToAct("what's on my calendar this week"))
        check("asksToAct explain→false", !app.promptAsksToAct("explain what's on screen"))
        check("asksToAct describe→false", !app.promptAsksToAct("describe this window"))
        check("asksToAct desktop", app.promptAsksToAct("what's on my desktop"))   // the misroute we just fixed
        check("asksToAct applescript verb", app.promptAsksToAct("play some music"))
        check("asksToAct imperative", app.promptAsksToAct("lock my screen"))
        check("asksToAct filler→false", !app.promptAsksToAct("thanks"))
        check("toolResultText format", app.toolResultText("recapture_screen", "ok", isError: false).contains("[Tool result for recapture_screen]"))
        check("toolResultText error tag", app.toolResultText("x", "bad", isError: true).contains("(error)"))
        check("confirmTitle friendly", app.confirmTitle("create_calendar_event") == "Create calendar event?")
        check("confirmRows count", app.confirmRows(args: ["title": "X", "start_iso": "Y"]).count == 2)
        check("confirmRows drops empty", app.confirmRows(args: ["title": "X", "notes": ""]).count == 1)
        check("confirmRows applescript purpose-first", app.confirmRows(args: ["script": "tell app", "purpose": "do X"]).first?.label == "What it does")
        check("confirmRows truncates long", app.confirmRows(args: ["content": String(repeating: "x", count: 2000)]).first.map { $0.value.count < 1100 } ?? false)
        check("friendlyValue iso→local", !app.friendlyValue(key: "start_iso", raw: "2026-07-01T15:00:00+02:00").contains("T"))
        check("friendlyValue naked→local", !app.friendlyValue(key: "start_iso", raw: "2026-07-02T15:00").contains("T"))  // the 7B's zone-less form
        check("parseDate naked", CalendarTools.parseDate("2026-07-02T15:00") != nil)
        check("friendlyValue passthrough", app.friendlyValue(key: "title", raw: "Lunch") == "Lunch")
        check("sdef appName", AppleScriptDictionary.appName(in: "tell application \"Calculator\" to activate") == "Calculator")
        check("sdef appName none", AppleScriptDictionary.appName(in: "set x to 1") == nil)
        let sdefXML = "<class name=\"window\">\n<property name=\"index\" type=\"integer\"/>\n</class>\n<command name=\"close\"/>"
        check("sdef condense class", AppleScriptDictionary.condense(sdefXML, appName: "T").contains("class window: index (integer)"))
        check("sdef condense commands", AppleScriptDictionary.condense(sdefXML, appName: "T").contains("commands: close"))
    }

    func testMCPConfig() {
        let mcpJSON = #"{"mcpServers":{"weather":{"command":"npx","args":["-y","weather-mcp"],"env":{"KEY":"x"}},"files":{"command":"/usr/bin/python3","args":["/tmp/s.py"]}}}"#
        let mcpServers = MCPConfig.parse(Data(mcpJSON.utf8))
        check("mcp parse count", mcpServers.count == 2)
        check("mcp parse sorted", mcpServers.map(\.name) == ["files", "weather"])
        check("mcp parse args", mcpServers.last?.args == ["-y", "weather-mcp"])
        check("mcp parse env", mcpServers.last?.env == ["KEY": "x"])
        check("mcp parse env defaults empty", mcpServers.first?.env == [:])
        check("mcp parse malformed → []", MCPConfig.parse(Data("not json".utf8)).isEmpty)
        check("mcp parse no-command skipped", MCPConfig.parse(Data(#"{"mcpServers":{"bad":{"args":[]}}}"#.utf8)).isEmpty)
        check("mcp parse empty-command skipped", MCPConfig.parse(Data(#"{"mcpServers":{"bad":{"command":""}}}"#.utf8)).isEmpty)
        check("mcp resolve absolute", MCPConfig.resolveInvocation(command: "/usr/bin/python3", args: ["a.py"]).executable == "/usr/bin/python3")
        let bareInvocation = MCPConfig.resolveInvocation(command: "npx", args: ["-y", "x"])
        check("mcp resolve bare → env", bareInvocation.executable == "/usr/bin/env" && bareInvocation.args == ["npx", "-y", "x"])
        let mcpNow = Date()
        check("mcp crashloop 3 in window", MCPConfig.isCrashLooping([mcpNow.addingTimeInterval(-1), mcpNow.addingTimeInterval(-5), mcpNow.addingTimeInterval(-30)], now: mcpNow))
        check("mcp crashloop stale ok", !MCPConfig.isCrashLooping([mcpNow.addingTimeInterval(-120), mcpNow.addingTimeInterval(-90), mcpNow.addingTimeInterval(-70)], now: mcpNow))
        check("mcp crashloop 2 ok", !MCPConfig.isCrashLooping([mcpNow.addingTimeInterval(-1), mcpNow.addingTimeInterval(-2)], now: mcpNow))
        check("mcp crashloop none ok", !MCPConfig.isCrashLooping([], now: mcpNow))
        check("mcp config path", MCPConfig.url.path.hasSuffix("Handle/mcp.json"))
    }

    func testNativeToolSpecsTheTranscriptProjection() {
        let specs = ToolRegistry.all.map(AgentPrompting.spec)
        check("specs: one per registry tool", specs.count == ToolRegistry.all.count && !specs.isEmpty)
        check("specs: every schema is an object", specs.allSatisfy { ($0.inputSchema["type"] as? String) == "object" })
        check("specs: point_at requires index", (AgentPrompting.pointAtSpec.inputSchema["required"] as? [String]) == ["index"])
        check("specs: registry names unique", Set(specs.map(\.name)).count == specs.count)
        check("specs: uniqueByName keeps first", AgentPrompting.uniqueByName([AIToolSpec(name: "a", description: "1", inputSchema: [:]), AIToolSpec(name: "a", description: "2", inputSchema: [:])]).map(\.description) == ["1"])
        let projected = AgentPrompting.messages(from: [
            Message(role: .user, text: "first", isStreaming: false),
            Message(role: .assistant, text: "", isStreaming: false),      // tool chip — dropped
            Message(role: .assistant, text: "reply", isStreaming: false),
            Message(role: .user, text: "second", isStreaming: false),
        ], prefix: "CTX", image: nil)
        check("projection: chips dropped, roles kept", projected.count == 3 && projected[0].role == .user && projected[1].role == .assistant && projected[2].role == .user)
        check("projection: prefix on last user only", projected[2].text == "CTX\n\nsecond" && projected[0].text == "first")
        check("projection: empty without a user turn", AgentPrompting.messages(from: [Message(role: .assistant, text: "x", isStreaming: false)], prefix: "", image: nil).isEmpty)
        check("point instr native: no JSON, mentions -1", { let t = app.pointAtToolInstruction(elements: [AXElement(role: "AXButton", label: "Back", frame: .zero, value: nil)], native: true); return !t.contains("{\"name\"") && t.contains("-1") }())
    }

    func testRepeatGuardSignature() {
        check("sig identical args", AppDelegate.callSignature(name: "t", args: ["a": "X"]) == AppDelegate.callSignature(name: "t", args: ["a": "X"]))
        // A local time with no zone and the same instant written with this machine's UTC offset must match.
        let seconds = TimeZone.current.secondsFromGMT(for: CalendarTools.parseDate("2026-07-15T00:00") ?? Date())
        let offset = String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        check("sig date forms match", AppDelegate.callSignature(name: "t", args: ["start_iso": "2026-07-15T00:00:00\(offset)"]) == AppDelegate.callSignature(name: "t", args: ["start_iso": "2026-07-15T00:00"]))
        check("sig different dates differ", AppDelegate.callSignature(name: "t", args: ["start_iso": "2026-07-15T00:00"]) != AppDelegate.callSignature(name: "t", args: ["start_iso": "2026-07-16T00:00"]))
        check("sig case/space normalized", AppDelegate.callSignature(name: "t", args: ["q": " Mary "]) == AppDelegate.callSignature(name: "t", args: ["q": "mary"]))
        check("sig name matters", AppDelegate.callSignature(name: "a", args: [:]) != AppDelegate.callSignature(name: "b", args: [:]))
        check("sig key order stable", AppDelegate.callSignature(name: "t", args: ["a": "1", "b": "2"]) == AppDelegate.callSignature(name: "t", args: ["b": "2", "a": "1"]))
    }
}
