import XCTest
import AppKit
@testable import Handle

@MainActor
final class ToolTests: XCTestCase {
    func testStructuredOneShotsAsTools() {
        XCTAssertEqual((OneShot.selectSpec(name: "select_automation", what: "automation").inputSchema["required"] as? [String]), ["index"], "oneshot: select spec requires index")
        do {
            let sch = OneShot.schema(for: [RecipeParam(name: "level", type: .int, prompt: "Volume"), RecipeParam(name: "apps", type: .stringList, prompt: "Apps"), RecipeParam(name: "mode", type: .oneOf(["on", "off"]), prompt: "Mode", default: "on")])
            let props = sch["properties"] as? [String: Any]
            XCTAssertEqual((props?["level"] as? [String: Any])?["type"] as? String, "integer", "oneshot: recipe params → schema types")
            XCTAssertEqual(((props?["apps"] as? [String: Any])?["items"] as? [String: String])?["type"], "string", "oneshot: recipe params → schema types")
            XCTAssertEqual((props?["mode"] as? [String: Any])?["enum"] as? [String], ["on", "off"], "oneshot: recipe params → schema types")
            XCTAssertEqual((sch["required"] as? [String]), ["level", "apps"], "oneshot: defaulted params are optional")
        }
        XCTAssertTrue({ let r = AppDelegate.scheduleFrom(["hour": 25, "minute": 30, "days": [2, 3], "task": "water"]); return r?.schedule.hour == 23 && r?.schedule.minute == 30 && r?.schedule.days == [2, 3] && r?.task == "water" }(), "oneshot: scheduleFrom maps + clamps")
        XCTAssertNil(AppDelegate.scheduleFrom(["hour": 8]), "oneshot: scheduleFrom maps + clamps")
        XCTAssertEqual(AppDelegate.triggerFrom(["kind": "appLaunches", "app": "Mail", "task": "mute"])?.trigger.kind, "appLaunches", "oneshot: triggerFrom maps kinds")
        XCTAssertEqual(AppDelegate.triggerFrom(["kind": "calendarSoon", "minutesBefore": 500, "task": "x"])?.trigger.minutesBefore, 120, "oneshot: triggerFrom maps kinds")
        XCTAssertNil(AppDelegate.triggerFrom(["kind": "fileAppears", "task": "x"]), "oneshot: triggerFrom maps kinds")
    }

    func testScreenTools() {
        XCTAssertEqual(ScreenTools.keyCode(for: "return"), 36, "screen: key codes")
        XCTAssertEqual(ScreenTools.keyCode(for: "a"), 0, "screen: key codes")
        XCTAssertEqual(ScreenTools.keyCode(for: "S"), 1, "screen: key codes")
        XCTAssertEqual(ScreenTools.keyCode(for: "m"), 46, "screen: key codes")
        XCTAssertEqual(ScreenTools.keyCode(for: "left"), 123, "screen: key codes")
        XCTAssertEqual(ScreenTools.keyCode(for: "1"), 18, "screen: key codes")
        XCTAssertNil(ScreenTools.keyCode(for: "nope"), "screen: key codes")
        XCTAssertTrue(ScreenTools.flags(for: ["command", "shift"]).contains(.maskCommand), "screen: modifier flags")
        XCTAssertTrue(ScreenTools.flags(for: ["cmd", "shift"]).contains(.maskShift), "screen: modifier flags")
        XCTAssertFalse(ScreenTools.flags(for: ["shift"]).contains(.maskCommand), "screen: modifier flags")
        XCTAssertEqual(ScreenTools.format([AXElement(role: "AXButton", label: "Send", frame: .zero, value: nil), AXElement(role: "AXTextField", label: "Search", frame: .zero, value: "foo")]), "[0] Button \"Send\"\n[1] TextField \"Search\" = \"foo\"", "screen: element list format")
        XCTAssertEqual(ScreenTools.chunks(of: "abcdefg", size: 3), ["abc", "def", "g"], "screen: text chunks")
        XCTAssertTrue(["list_windows": ToolConfirmation.auto, "focus_app": .auto, "read_window": .auto, "click_element": .confirm, "type_text": .confirm, "press_key": .confirm, "scroll": .auto, "read_screen_text": .auto].allSatisfy { name, kind in ToolRegistry.tool(named: name)?.confirmation == kind }, "screen: eight tools registered with the right consent")
    }

    func testCustomization() {
        do {
            let ok = UserToolDef(name: "my_tool2", description: "d", runner: "shell", script: "true")
            let r: Set<String> = ["list_files"]
            XCTAssertNil(UserTools.validate(ok, reserved: r, taken: []), "user tools: validate names + runners")
            XCTAssertNotNil(UserTools.validate(UserToolDef(name: "list_files", description: "d", runner: "shell", script: "x"), reserved: r, taken: []), "user tools: validate names + runners")
            XCTAssertNotNil(UserTools.validate(UserToolDef(name: "Bad-Name", description: "d", runner: "shell", script: "x"), reserved: r, taken: []), "user tools: validate names + runners")
            XCTAssertNotNil(UserTools.validate(UserToolDef(name: "mcp__x", description: "d", runner: "shell", script: "x"), reserved: r, taken: []), "user tools: validate names + runners")
            XCTAssertNotNil(UserTools.validate(UserToolDef(name: "t2", description: "d", runner: "python", script: "x"), reserved: r, taken: []), "user tools: validate names + runners")
            XCTAssertNotNil(UserTools.validate(ok, reserved: r, taken: ["my_tool2"]), "user tools: validate names + runners")
            XCTAssertNotNil(UserTools.validate(UserToolDef(name: "t3", description: "d", params: ["bad key": UserToolParam()], runner: "shell", script: "x"), reserved: r, taken: []), "user tools: validate names + runners")
        }
        XCTAssertTrue({ let d = UserToolDef(name: "t", description: "d", params: ["msg": UserToolParam(type: "string", description: "m", required: true), "n": UserToolParam(type: "integer"), "weird": UserToolParam(type: "array")], runner: "shell", script: "x"); let sch = UserTools.schema(for: d); let props = sch["properties"] as? [String: [String: Any]]; return (sch["type"] as? String) == "object" && (sch["required"] as? [String]) == ["msg"] && (props?["n"]?["type"] as? String) == "integer" && (props?["weird"]?["type"] as? String) == "string" && (sch["additionalProperties"] as? Bool) == false && UserTools.tool(for: d).confirmation == .confirm && UserTools.tool(for: UserToolDef(name: "t", description: "d", runner: "shell", script: "x", confirm: false)).confirmation == .auto }(), "user tools: schema from params")
        do {
            let d = UserToolDef(name: "t", description: "d", params: ["msg": UserToolParam(), "flag": UserToolParam(type: "boolean"), "n": UserToolParam(type: "number"), "missing": UserToolParam()], runner: "shell", script: "x")
            let args: [String: Any] = (try? JSONSerialization.jsonObject(with: Data(#"{"msg":"say \"hi\"","flag":true,"n":1}"#.utf8))) as? [String: Any] ?? [:]
            let v = UserTools.stringValues(args, for: d)
            XCTAssertEqual(v["msg"], "say \"hi\"", "user tools: placeholders + env names + values")
            XCTAssertEqual(v["flag"], "true", "user tools: placeholders + env names + values")
            XCTAssertEqual(v["n"], "1", "user tools: placeholders + env names + values")
            XCTAssertEqual(v["missing"], "", "user tools: placeholders + env names + values")
            XCTAssertEqual(UserTools.envName("file name-2"), "FILE_NAME_2", "user tools: placeholders + env names + values")
            XCTAssertEqual(UserTools.substitute("echo {{msg}} {{missing}}!", v, quoting: .none), "echo say \"hi\" !", "user tools: placeholders + env names + values")
            XCTAssertEqual(UserTools.substitute("display \"{{msg}}\"", v, quoting: .appleScript), "display \"say \\\"hi\\\"\"", "user tools: placeholders + env names + values")
        }
        do {
            let n = "__selftest_tool__"
            TrustSettings.setDisabled(n, true)
            let off = TrustSettings.isDisabled(n)
            TrustSettings.setDisabled(n, false)
            TrustSettings.setDontAsk(n, true)
            let trusted = TrustSettings.isTrusted(n)
            TrustSettings.setDontAsk(n, false)
            TrustSettings.setDontAsk("save_automation", true)
            let never = !TrustSettings.isTrusted("save_automation")
            TrustSettings.setDontAsk("save_automation", false)
            XCTAssertTrue(off, "trust: disabled + don't ask round trip; alwaysAsk never trusted")
            XCTAssertFalse(TrustSettings.isDisabled(n), "trust: disabled + don't ask round trip; alwaysAsk never trusted")
            XCTAssertTrue(trusted, "trust: disabled + don't ask round trip; alwaysAsk never trusted")
            XCTAssertFalse(TrustSettings.isTrusted(n), "trust: disabled + don't ask round trip; alwaysAsk never trusted")
            XCTAssertTrue(never, "trust: disabled + don't ask round trip; alwaysAsk never trusted")
        }
        XCTAssertTrue(UserInstructions.block(for: "  \n ").isEmpty, "instructions: block empty ↔ text; capped")
        XCTAssertTrue(UserInstructions.block(for: "Call me Dee").hasSuffix("Call me Dee"), "instructions: block empty ↔ text; capped")
        XCTAssertTrue(UserInstructions.block(for: String(repeating: "x", count: 9000)).count < 4300, "instructions: block empty ↔ text; capped")
        XCTAssertEqual(ToolRegistry.all.count, ToolRegistry.builtinTools.count + UserTools.tools.count, "registry: all = builtins + user tools")
        XCTAssertTrue(UserTools.reservedNames.contains("list_files"), "registry: all = builtins + user tools")
        XCTAssertTrue(UserTools.reservedNames.contains("run_subagent"), "registry: all = builtins + user tools")
        XCTAssertTrue(ScreenTools.appMatches("TextEdit", name: "TextEdit", bundleID: "com.apple.TextEdit"), "screen: keystrokes name their app")
        XCTAssertTrue(ScreenTools.appMatches(" textedit.app ", name: "TextEdit", bundleID: nil), "screen: keystrokes name their app")
        XCTAssertTrue(ScreenTools.appMatches("com.apple.Safari", name: "Safari", bundleID: "com.apple.Safari"), "screen: keystrokes name their app")
        XCTAssertFalse(ScreenTools.appMatches("TextEdit", name: "ChatGPT", bundleID: "com.openai.chat"), "screen: keystrokes name their app")
        XCTAssertFalse(ScreenTools.appMatches("", name: "X", bundleID: nil), "screen: keystrokes name their app")
        XCTAssertFalse(ScreenTools.appMatches("TextEdit", name: nil, bundleID: nil), "screen: keystrokes name their app")
        XCTAssertTrue(((ScreenTools.typeTextTool.inputSchema["required"] as? [String]) ?? []).contains("app"), "screen: type_text + press_key require app")
        XCTAssertTrue(((ScreenTools.pressKeyTool.inputSchema["required"] as? [String]) ?? []).contains("app"), "screen: type_text + press_key require app")
        XCTAssertTrue((ScreenToolError.wrongFrontApp(wanted: "TextEdit", front: "ChatGPT").errorDescription ?? "").hasPrefix("Nothing was sent: ChatGPT is in front"), "screen: type_text + press_key require app")
        do {
            let json = #"{"id":"1","name":"n","recipeId":"r","paramsJSON":"{}","enabled":true,"lastRunKey":""}"#
            let a = try? JSONDecoder().decode(Automation.self, from: Data(json.utf8))
            XCTAssertNil(a?.policy, "automation: old json decodes with no policy")
            XCTAssertEqual(a?.name, "n", "automation: old json decodes with no policy")
        }
        do {
            let l = TaskLedger()
            let id = l.start(goal: "g")
            let running = l.running.count == 1
            l.finish(id: id, result: "ok")
            XCTAssertTrue(running, "ledger: start → finish")
            XCTAssertEqual(l.entries.first?.status, .done, "ledger: start → finish")
            XCTAssertEqual(l.entries.first?.result, "ok", "ledger: start → finish")
            XCTAssertEqual(id.count, 8, "ledger: start → finish")
        }
        XCTAssertEqual(AgentTools.tools.count, 6, "agent tools: six, consent kinds")
        XCTAssertEqual(AgentTools.tools.filter { $0.confirmation == .confirm }.map(\.name).sorted(), ["delete_automation", "run_automation", "run_in_background", "run_subagent", "save_automation"], "agent tools: six, consent kinds")
        XCTAssertTrue(AgentTools.describe([Automation(id: "id1", name: "Morning", recipeId: "", paramsJSON: "{}", schedule: AutomationSchedule(hour: 9, minute: 0, days: nil), routineGoal: "check mail", policy: AgentPolicy(standingConsent: true))]).contains("id1 — Morning — "), "agent tools: automation lines")
        XCTAssertTrue(AgentTools.describe([]).contains("no saved"), "agent tools: automation lines")
    }

    func testFunctionCallFallback() {
        XCTAssertTrue(ToolCallParser.parse("create_reminder(title=\"Call mom\", priority=\"high\")").map { $0.name == "create_reminder" && ($0.args["title"] as? String) == "Call mom" } ?? false, "fncall parses")
        XCTAssertNil(ToolCallParser.parse("You can use open_url(url) to open a link."), "fncall prose→nil")
        XCTAssertEqual(ToolCallParser.parse("{\"name\": \"list_files\", \"arguments\": {}}")?.name, "list_files", "fncall json intact")
        XCTAssertEqual((try? ReminderTools.shared.decodeCreateReminder(from: "{\"title\":\"x\",\"priority\":\"high\"}")).flatMap { $0.priority }, 1, "reminder priority word")
    }

    func testToolUseChips() {
        let chipConv = Conversation(chatWithApp: "T")
        chipConv.addToolChip(name: "create_reminder", inputJSON: "{}", content: "ok", isError: false, displaySummary: "Reminder added")
        XCTAssertTrue(chipConv.visibleMessages.contains { $0.toolUses.first?.name == "create_reminder" }, "toolChip visible")
        XCTAssertNotNil(chipConv.messages.compactMap { $0.toolUses.first?.id }.first.flatMap { chipConv.toolResult(forUseId: $0) }, "toolChip result linked")
    }
}
