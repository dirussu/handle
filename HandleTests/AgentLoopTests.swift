import XCTest
import AppKit
@testable import Handle

final class AgentLoopTests: AppTestCase {
    func testToolRegistry() {
        XCTAssertNotNil(ToolRegistry.tool(named: "run_applescript"), "registry has run_applescript")
        XCTAssertNil(ToolRegistry.tool(named: "nonexistent_tool_xyz"), "registry unknown → nil")
        XCTAssertFalse(ToolRegistry.names.isEmpty, "registry names nonempty")
        XCTAssertNil(ToolRegistry.tool(named: "point_at"), "registry excludes point_at")
        XCTAssertTrue(ToolRegistry.tool(named: "run_applescript").map { ToolRegistry.promptSpec(for: [$0]).contains("run_applescript(") } ?? false, "promptSpec names tool")
    }

    func testConfirmationRoutingIsTheSafetyProperty() {
        XCTAssertEqual(ToolRegistry.tool(named: "create_reminder")?.confirmation, .confirm, "reg create_reminder=confirm")
        XCTAssertEqual(ToolRegistry.tool(named: "list_reminders")?.confirmation, .auto, "reg list_reminders=auto")
        XCTAssertEqual(ToolRegistry.tool(named: "delete_file")?.confirmation, .confirm, "reg delete_file=confirm")
        XCTAssertEqual(ToolRegistry.tool(named: "move_file")?.confirmation, .confirm, "reg move_file=confirm")
        XCTAssertEqual(ToolRegistry.tool(named: "read_file")?.confirmation, .auto, "reg read_file=auto")
        // preview before mutation
        XCTAssertEqual(ToolRegistry.tool(named: "write_file")?.confirmation, .confirm, "reg write_file=confirm")
        XCTAssertEqual(ToolRegistry.tool(named: "draft_email_reply")?.confirmation, .confirm, "reg draft_email=confirm")
        XCTAssertEqual(ToolRegistry.tool(named: "draft_imessage")?.confirmation, .confirm, "reg draft_imessage=confirm")
    }

    func testOnboardingHardwareBar() {
        XCTAssertTrue(Onboarding.voiceSupported(isAppleSilicon: true), "voice: apple silicon ok")
        XCTAssertFalse(Onboarding.voiceSupported(isAppleSilicon: false), "voice: intel unsupported (soft note, no gate)")
    }

    func testAgentLoopRails() {
        XCTAssertTrue(AgentSettings.stopReason(step: 30, maxSteps: 30, spentUSD: 0, budgetUSD: 0.5)?.contains("Step limit") == true && AgentSettings.stopReason(step: 29, maxSteps: 30, spentUSD: 0, budgetUSD: 0.5) == nil, "agent: stop on step cap")
        XCTAssertTrue(AgentSettings.stopReason(step: 3, maxSteps: 30, spentUSD: 0.6, budgetUSD: 0.5)?.contains("budget") == true, "agent: stop on budget")
        XCTAssertNil(AgentSettings.stopReason(step: 3, maxSteps: 30, spentUSD: 99, budgetUSD: 0), "agent: zero budget = unlimited")
        do {
            var g = RepeatGuard()
            XCTAssertEqual(g.observe("a"), 1, "agent: repeat guard counts consecutive only")
            XCTAssertEqual(g.observe("a"), 2, "agent: repeat guard counts consecutive only")
            XCTAssertEqual(g.observe("b"), 1, "agent: repeat guard counts consecutive only")
            XCTAssertEqual(g.observe("a"), 1, "agent: repeat guard counts consecutive only")
            XCTAssertEqual(g.observe("a"), 2, "agent: repeat guard counts consecutive only")
            XCTAssertEqual(g.observe("a"), 3, "agent: repeat guard counts consecutive only")
        }
        XCTAssertTrue({ let h = [AIMessage(role: .user, parts: [.toolResult(id: "1", text: "shot", isError: false, image: Data([1]))]), AIMessage(role: .user, parts: [.text("x")])]; let r = AgentPrompting.stripImages(from: h); if case .toolResult(_, let t, _, let img) = r[0].parts[0] { return img == nil && t.contains("omitted") && r[1].text == "x" } else { return false } }(), "agent: older screenshots stripped from history")
        do {
            let p = AnthropicProvider.encodePart(.toolResult(id: "t", text: "ok", isError: false, image: Data([1, 2])))
            XCTAssertEqual(((p?["content"] as? [[String: Any]])?.last?["type"] as? String), "image", "anthropic: image tool result is a block list")
            XCTAssertEqual((AnthropicProvider.encodePart(.toolResult(id: "t", text: "ok", isError: false))?["content"] as? String), "ok", "anthropic: image tool result is a block list")
        }
        do {
            let m = OpenAIProvider.encodeMessages([AIMessage(role: .user, parts: [.toolResult(id: "c", text: "ok", isError: false, image: Data([1]))])])
            XCTAssertEqual(m.count, 2, "openai: image tool result → trailing user image")
            XCTAssertEqual((m[0]["role"] as? String), "tool", "openai: image tool result → trailing user image")
            XCTAssertEqual((m[1]["role"] as? String), "user", "openai: image tool result → trailing user image")
        }
        XCTAssertEqual(TurnOutput(text: "", calls: [AgentToolCall(id: "a", name: "x", args: [:]), AgentToolCall(id: "b", name: "y", args: [:])]).call?.name, "x", "turn output: call = calls.first")
        XCTAssertTrue(TurnOutput(text: "", call: nil).calls.isEmpty, "turn output: call = calls.first")
        XCTAssertTrue(AgentPrompting.toolGuide(native: true).contains("several in one step"), "toolspec native: several calls, several steps")
        XCTAssertTrue(AgentPrompting.toolGuide(native: true).contains("say what is done and what is not"), "toolspec native: several calls, several steps")
    }

    func testPolicies() {
        do {
            let p = AgentPolicy(allowedTools: ["a"], maxSteps: 7, budgetUSD: 0.1, standingConsent: true)
            let d = try! JSONEncoder().encode(p)
            XCTAssertEqual(try! JSONDecoder().decode(AgentPolicy.self, from: d), p, "policy: json round trip + defaults")
            XCTAssertEqual(AgentPolicy().maxSteps, 15, "policy: json round trip + defaults")
            XCTAssertFalse(AgentPolicy().standingConsent, "policy: json round trip + defaults")
        }
        do {
            let c = AgentPolicy(maxSteps: 8, budgetUSD: 1.0, standingConsent: true).child(allowedTools: ["x"], maxSteps: 30)
            XCTAssertEqual(c.maxSteps, 8, "policy: child never gains consent or exceeds parent")
            XCTAssertEqual(c.budgetUSD, 0.25, "policy: child never gains consent or exceeds parent")
            XCTAssertFalse(c.standingConsent, "policy: child never gains consent or exceeds parent")
            XCTAssertEqual(c.depth, 1, "policy: child never gains consent or exceeds parent")
            XCTAssertTrue(c.allows("x"), "policy: child never gains consent or exceeds parent")
            XCTAssertFalse(c.allows("y"), "policy: child never gains consent or exceeds parent")
            XCTAssertTrue(AgentPolicy().allows("anything"), "policy: child never gains consent or exceeds parent")
        }
        do {
            let p = AgentPolicy(allowedTools: ["a", "b"])
            let c = p.child(allowedTools: ["b", "c"], maxSteps: 5, label: "L")
            let d = p.child(allowedTools: nil, maxSteps: 5)
            XCTAssertTrue(c.allows("b"), "policy: child tool list is parent ∩ requested")
            XCTAssertFalse(c.allows("a"), "policy: child tool list is parent ∩ requested")
            XCTAssertFalse(c.allows("c"), "policy: child tool list is parent ∩ requested")
            XCTAssertTrue(d.allows("a"), "policy: child tool list is parent ∩ requested")
            XCTAssertFalse(d.allows("z"), "policy: child tool list is parent ∩ requested")
            XCTAssertEqual(c.label, "L", "policy: child tool list is parent ∩ requested")
            XCTAssertEqual(c.effort, .medium, "policy: child tool list is parent ∩ requested")
            XCTAssertTrue(AgentPolicy().child(allowedTools: ["q"], maxSteps: 3).allows("q"), "policy: child tool list is parent ∩ requested")
        }
        do {
            var p = AgentPolicy()
            p.effort = .high
            p.label = "routine:X"
            let d = try! JSONEncoder().encode(p)
            XCTAssertEqual(try! JSONDecoder().decode(AgentPolicy.self, from: d), p, "policy: effort + label round trip")
        }
        XCTAssertTrue((AnthropicProvider.encodeTool(AgentPrompting.pointAtSpec)["strict"] as? Bool) == true && AnthropicProvider.encodeTool(AIToolSpec(name: "mcp_x", description: "d", inputSchema: ["type": "object"]))["strict"] == nil, "anthropic: strict only for our schemas")
        do {
            let r = AgentRun(text: "t")
            XCTAssertEqual(r.costUSD, 0, "agent run: defaults")
            XCTAssertFalse(r.cancelled, "agent run: defaults")
            XCTAssertNil(TurnOutput(text: "", calls: []).usage, "agent run: defaults")
        }
    }

    func testKillSwitchAuditParsing() {
        do {
            let l = TaskLedger()
            let id = l.start(goal: "g")
            l.attach(id: id, task: Task { })
            l.cancelAll()
            XCTAssertEqual(l.entries.first?.status, .cancelled, "ledger: cancelAll marks running tasks")
            XCTAssertTrue(l.running.isEmpty, "ledger: cancelAll marks running tasks")
            XCTAssertEqual(l.entries.first?.result, "Cancelled.", "ledger: cancelAll marks running tasks")
        }
        do {
            let r = AuditLog.parseLine(#"{"ts":"2026-09-20T09:00:00Z","tool":"routine:Morning","outcome":"ok","summary":"$0.01 · fine"}"#)
            XCTAssertEqual(r?.tool, "routine:Morning", "audit: parseLine")
            XCTAssertEqual(r?.outcome, "ok", "audit: parseLine")
            XCTAssertNil(AuditLog.parseLine("nope"), "audit: parseLine")
        }
        XCTAssertTrue(AIProviderError.keyRejected(provider: "openai").errorDescription?.hasPrefix("OpenAI rejected") == true && AIProviderError.noAPIKey(provider: "anthropic").errorDescription?.contains("No Anthropic API key") == true, "errors: provider ids read as names")
        do {
            let t = AgentPrompting.identity(providerName: "a local model server (localhost)", localEndpoint: true)
            XCTAssertTrue(t.contains("runs on this Mac too"), "identity: local endpoint never claims a cloud")
            XCTAssertFalse(t.contains("own API key"), "identity: local endpoint never claims a cloud")
        }
        XCTAssertTrue([AIState.notChosen, .missingKey(.anthropic), .unavailable(.openai)].allSatisfy { $0.userMessage?.contains("Settings → AI") == true }, "aistate: every non-ready state explains itself")
        XCTAssertNil(AIState.ready(.anthropic).userMessage, "aistate: every non-ready state explains itself")
        XCTAssertTrue(ScreenshotStatus.withheldUnsupported.caption.contains("can't see images"), "see: unsupported-vision caption + note")
        XCTAssertTrue(SeeSettings.unsupportedNote.contains("No screenshot"), "see: unsupported-vision caption + note")
        XCTAssertEqual(AICost.estimate(model: "claude-sonnet-5", input: 1_000_000, output: 0), 2.0, "cost: sonnet 5 1M in = $2")
        XCTAssertEqual(AICost.estimate(model: "claude-sonnet-5", input: 0, output: 0, cacheRead: 1_000_000), 0.2, "cost: cache read is 10% of input")
        XCTAssertNil(AICost.estimate(model: "mystery", input: 10, output: 10), "cost: unknown model = nil")
        XCTAssertEqual(SecretStore.hint(for: "sk-ant-abcdef1234"), "••••1234", "key hint shows last 4 only")
        XCTAssertEqual(SecretStore.hint(for: ""), "", "key hint shows last 4 only")
    }

    func testSeeConsent() {
        XCTAssertTrue(SeeSettings.isExcluded("COM.1password.1password", in: ["com.1password.1password"]), "see: excluded match is case-insensitive")
        XCTAssertFalse(SeeSettings.isExcluded(nil, in: ["a"]), "see: nil / empty / unlisted are not excluded")
        XCTAssertFalse(SeeSettings.isExcluded("", in: ["a"]), "see: nil / empty / unlisted are not excluded")
        XCTAssertFalse(SeeSettings.isExcluded("b", in: ["a"]), "see: nil / empty / unlisted are not excluded")
        XCTAssertTrue(ScreenshotStatus.withheldExcluded(app: "1Password").caption.contains("1Password"), "see: captions name the app / provider")
        XCTAssertTrue(ScreenshotStatus.sent(provider: "Anthropic").caption.contains("Anthropic"), "see: captions name the app / provider")
        XCTAssertEqual(ScreenshotStatus.withheldDeclined.symbol, "eye.slash", "see: captions name the app / provider")
        XCTAssertTrue(SeeSettings.excludedNote(app: "Bank").contains("Bank"), "see: excluded note names the app")
        XCTAssertTrue(SeeSettings.excludedNote(app: "Bank").contains("NOT captured"), "see: excluded note names the app")
        do {
            let ctx = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            let big = ctx.makeImage()!
            let jpeg = AIImage.jpegData(big)!
            let thumb = SentRecord.thumbnail(from: jpeg)
            XCTAssertTrue(thumb.map { $0.width == 240 && $0.height == 160 } == true, "sent: thumbnail ≤ 240px, keeps aspect")
            let req = AIRequest(messages: [.system("S"), AIMessage(role: .user, parts: [.image(jpeg, mime: "image/jpeg"), .text("CTX\n\nwhat is this?")])], label: nil)
            let rec = SentRecord.skeleton(for: req, provider: "anthropic", model: "claude-sonnet-5")
            XCTAssertEqual(rec.label, "what is this?", "sent: skeleton takes last line as label + image bytes")
            XCTAssertEqual(rec.imageBytes, jpeg.count, "sent: skeleton takes last line as label + image bytes")
            XCTAssertNotNil(rec.imageThumbnail, "sent: skeleton takes last line as label + image bytes")
            XCTAssertEqual(SentRecord.skeleton(for: AIRequest(messages: [.user("x")], label: "one-shot · pick"), provider: "anthropic", model: "mystery").label, "one-shot · pick", "sent: explicit label wins, cost nil before usage")
            XCTAssertNil(SentRecord.skeleton(for: req, provider: "anthropic", model: "mystery").cost, "sent: explicit label wins, cost nil before usage")
        }
    }

    func testAgentLoopRoutingResultFormatting() {
        XCTAssertTrue(Intent.asksToAct("look again at the screen"), "asksToAct again")
        XCTAssertTrue(Intent.asksToAct("open my downloads"), "asksToAct open")
        XCTAssertTrue(Intent.asksToAct("what's on my calendar this week"), "asksToAct calendar")
        XCTAssertFalse(Intent.asksToAct("explain what's on screen"), "asksToAct explain→false")
        XCTAssertFalse(Intent.asksToAct("describe this window"), "asksToAct describe→false")
        // the misroute we just fixed
        XCTAssertTrue(Intent.asksToAct("what's on my desktop"), "asksToAct desktop")
        XCTAssertTrue(Intent.asksToAct("play some music"), "asksToAct applescript verb")
        XCTAssertTrue(Intent.asksToAct("lock my screen"), "asksToAct imperative")
        XCTAssertFalse(Intent.asksToAct("thanks"), "asksToAct filler→false")
        XCTAssertTrue(AgentPrompting.toolResultText("recapture_screen", "ok", isError: false).contains("[Tool result for recapture_screen]"), "toolResultText format")
        XCTAssertTrue(AgentPrompting.toolResultText("x", "bad", isError: true).contains("(error)"), "toolResultText error tag")
        XCTAssertEqual(ConfirmationText.title("create_calendar_event"), "Create calendar event?", "confirmTitle friendly")
        XCTAssertEqual(ConfirmationText.rows(args: ["title": "X", "start_iso": "Y"]).count, 2, "confirmRows count")
        XCTAssertEqual(ConfirmationText.rows(args: ["title": "X", "notes": ""]).count, 1, "confirmRows drops empty")
        XCTAssertEqual(ConfirmationText.rows(args: ["script": "tell app", "purpose": "do X"]).first?.label, "What it does", "confirmRows applescript purpose-first")
        XCTAssertTrue(ConfirmationText.rows(args: ["content": String(repeating: "x", count: 2000)]).first.map { $0.value.count < 1100 } ?? false, "confirmRows truncates long")
        XCTAssertFalse(ConfirmationText.friendlyValue(key: "start_iso", raw: "2026-07-01T15:00:00+02:00").contains("T"), "friendlyValue iso→local")
        // the 7B's zone-less form
        XCTAssertFalse(ConfirmationText.friendlyValue(key: "start_iso", raw: "2026-07-02T15:00").contains("T"), "friendlyValue naked→local")
        XCTAssertNotNil(CalendarTools.parseDate("2026-07-02T15:00"), "parseDate naked")
        XCTAssertEqual(ConfirmationText.friendlyValue(key: "title", raw: "Lunch"), "Lunch", "friendlyValue passthrough")
        XCTAssertEqual(AppleScriptDictionary.appName(in: "tell application \"Calculator\" to activate"), "Calculator", "sdef appName")
        XCTAssertNil(AppleScriptDictionary.appName(in: "set x to 1"), "sdef appName none")
        let sdefXML = "<class name=\"window\">\n<property name=\"index\" type=\"integer\"/>\n</class>\n<command name=\"close\"/>"
        XCTAssertTrue(AppleScriptDictionary.condense(sdefXML, appName: "T").contains("class window: index (integer)"), "sdef condense class")
        XCTAssertTrue(AppleScriptDictionary.condense(sdefXML, appName: "T").contains("commands: close"), "sdef condense commands")
    }

    func testMCPConfig() {
        let mcpJSON = #"{"mcpServers":{"weather":{"command":"npx","args":["-y","weather-mcp"],"env":{"KEY":"x"}},"files":{"command":"/usr/bin/python3","args":["/tmp/s.py"]}}}"#
        let mcpServers = MCPConfig.parse(Data(mcpJSON.utf8))
        XCTAssertEqual(mcpServers.count, 2, "mcp parse count")
        XCTAssertEqual(mcpServers.map(\.name), ["files", "weather"], "mcp parse sorted")
        XCTAssertEqual(mcpServers.last?.args, ["-y", "weather-mcp"], "mcp parse args")
        XCTAssertEqual(mcpServers.last?.env, ["KEY": "x"], "mcp parse env")
        XCTAssertEqual(mcpServers.first?.env, [:], "mcp parse env defaults empty")
        XCTAssertTrue(MCPConfig.parse(Data("not json".utf8)).isEmpty, "mcp parse malformed → []")
        XCTAssertTrue(MCPConfig.parse(Data(#"{"mcpServers":{"bad":{"args":[]}}}"#.utf8)).isEmpty, "mcp parse no-command skipped")
        XCTAssertTrue(MCPConfig.parse(Data(#"{"mcpServers":{"bad":{"command":""}}}"#.utf8)).isEmpty, "mcp parse empty-command skipped")
        XCTAssertEqual(MCPConfig.resolveInvocation(command: "/usr/bin/python3", args: ["a.py"]).executable, "/usr/bin/python3", "mcp resolve absolute")
        let bareInvocation = MCPConfig.resolveInvocation(command: "npx", args: ["-y", "x"])
        XCTAssertEqual(bareInvocation.executable, "/usr/bin/env", "mcp resolve bare → env")
        XCTAssertEqual(bareInvocation.args, ["npx", "-y", "x"], "mcp resolve bare → env")
        let mcpNow = Date()
        XCTAssertTrue(MCPConfig.isCrashLooping([mcpNow.addingTimeInterval(-1), mcpNow.addingTimeInterval(-5), mcpNow.addingTimeInterval(-30)], now: mcpNow), "mcp crashloop 3 in window")
        XCTAssertFalse(MCPConfig.isCrashLooping([mcpNow.addingTimeInterval(-120), mcpNow.addingTimeInterval(-90), mcpNow.addingTimeInterval(-70)], now: mcpNow), "mcp crashloop stale ok")
        XCTAssertFalse(MCPConfig.isCrashLooping([mcpNow.addingTimeInterval(-1), mcpNow.addingTimeInterval(-2)], now: mcpNow), "mcp crashloop 2 ok")
        XCTAssertFalse(MCPConfig.isCrashLooping([], now: mcpNow), "mcp crashloop none ok")
        XCTAssertTrue(MCPConfig.url.path.hasSuffix("Handle/mcp.json"), "mcp config path")
    }

    func testNativeToolSpecsTheTranscriptProjection() {
        let specs = ToolRegistry.all.map(AgentPrompting.spec)
        XCTAssertEqual(specs.count, ToolRegistry.all.count, "specs: one per registry tool")
        XCTAssertFalse(specs.isEmpty, "specs: one per registry tool")
        XCTAssertTrue(specs.allSatisfy { ($0.inputSchema["type"] as? String) == "object" }, "specs: every schema is an object")
        XCTAssertEqual((AgentPrompting.pointAtSpec.inputSchema["required"] as? [String]), ["index"], "specs: point_at requires index")
        XCTAssertEqual(Set(specs.map(\.name)).count, specs.count, "specs: registry names unique")
        XCTAssertEqual(AgentPrompting.uniqueByName([AIToolSpec(name: "a", description: "1", inputSchema: [:]), AIToolSpec(name: "a", description: "2", inputSchema: [:])]).map(\.description), ["1"], "specs: uniqueByName keeps first")
        let projected = AgentPrompting.messages(from: [
            Message(role: .user, text: "first", isStreaming: false),
            Message(role: .assistant, text: "", isStreaming: false),      // tool chip — dropped
            Message(role: .assistant, text: "reply", isStreaming: false),
            Message(role: .user, text: "second", isStreaming: false),
        ], prefix: "CTX", image: nil)
        XCTAssertEqual(projected.count, 3, "projection: chips dropped, roles kept")
        XCTAssertEqual(projected[0].role, .user, "projection: chips dropped, roles kept")
        XCTAssertEqual(projected[1].role, .assistant, "projection: chips dropped, roles kept")
        XCTAssertEqual(projected[2].role, .user, "projection: chips dropped, roles kept")
        XCTAssertEqual(projected[2].text, "CTX\n\nsecond", "projection: prefix on last user only")
        XCTAssertEqual(projected[0].text, "first", "projection: prefix on last user only")
        XCTAssertTrue(AgentPrompting.messages(from: [Message(role: .assistant, text: "x", isStreaming: false)], prefix: "", image: nil).isEmpty, "projection: empty without a user turn")
        do {
            let t = AgentPrompting.pointingGuide(elements: [AXElement(role: "AXButton", label: "Back", frame: .zero, value: nil)], native: true)
            XCTAssertFalse(t.contains("{\"name\""), "point instr native: no JSON, mentions -1")
            XCTAssertTrue(t.contains("-1"), "point instr native: no JSON, mentions -1")
        }
    }

    func testRepeatGuardSignature() {
        XCTAssertEqual(RepeatGuard.signature(name: "t", args: ["a": "X"]), RepeatGuard.signature(name: "t", args: ["a": "X"]), "sig identical args")
        // A local time with no zone and the same instant written with this machine's UTC offset must match.
        let seconds = TimeZone.current.secondsFromGMT(for: CalendarTools.parseDate("2026-07-15T00:00") ?? Date())
        let offset = String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        XCTAssertEqual(RepeatGuard.signature(name: "t", args: ["start_iso": "2026-07-15T00:00:00\(offset)"]), RepeatGuard.signature(name: "t", args: ["start_iso": "2026-07-15T00:00"]), "sig date forms match")
        XCTAssertNotEqual(RepeatGuard.signature(name: "t", args: ["start_iso": "2026-07-15T00:00"]), RepeatGuard.signature(name: "t", args: ["start_iso": "2026-07-16T00:00"]), "sig different dates differ")
        XCTAssertEqual(RepeatGuard.signature(name: "t", args: ["q": " Mary "]), RepeatGuard.signature(name: "t", args: ["q": "mary"]), "sig case/space normalized")
        XCTAssertNotEqual(RepeatGuard.signature(name: "a", args: [:]), RepeatGuard.signature(name: "b", args: [:]), "sig name matters")
        XCTAssertEqual(RepeatGuard.signature(name: "t", args: ["a": "1", "b": "2"]), RepeatGuard.signature(name: "t", args: ["b": "2", "a": "1"]), "sig key order stable")
    }
}
