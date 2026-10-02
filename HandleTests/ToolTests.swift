import XCTest
import AppKit
@testable import Handle

final class ToolTests: AppTestCase {
    func testStructuredOneShotsAsTools() {
        check("oneshot: select spec requires index", (AppDelegate.selectSpec(name: "select_automation", what: "automation").inputSchema["required"] as? [String]) == ["index"])
        do {
            let sch = AppDelegate.schema(for: [RecipeParam(name: "level", type: .int, prompt: "Volume"), RecipeParam(name: "apps", type: .stringList, prompt: "Apps"), RecipeParam(name: "mode", type: .oneOf(["on", "off"]), prompt: "Mode", default: "on")])
            let props = sch["properties"] as? [String: Any]
            check("oneshot: recipe params → schema types", (props?["level"] as? [String: Any])?["type"] as? String == "integer" && ((props?["apps"] as? [String: Any])?["items"] as? [String: String])?["type"] == "string" && (props?["mode"] as? [String: Any])?["enum"] as? [String] == ["on", "off"])
            check("oneshot: defaulted params are optional", (sch["required"] as? [String]) == ["level", "apps"])
        }
        check("oneshot: scheduleFrom maps + clamps", { let r = AppDelegate.scheduleFrom(["hour": 25, "minute": 30, "days": [2, 3], "task": "water"]); return r?.schedule.hour == 23 && r?.schedule.minute == 30 && r?.schedule.days == [2, 3] && r?.task == "water" }() && AppDelegate.scheduleFrom(["hour": 8]) == nil)
        check("oneshot: triggerFrom maps kinds", AppDelegate.triggerFrom(["kind": "appLaunches", "app": "Mail", "task": "mute"])?.trigger.kind == "appLaunches" && AppDelegate.triggerFrom(["kind": "calendarSoon", "minutesBefore": 500, "task": "x"])?.trigger.minutesBefore == 120 && AppDelegate.triggerFrom(["kind": "fileAppears", "task": "x"]) == nil)
    }

    func testScreenTools() {
        check("screen: key codes", ScreenTools.keyCode(for: "return") == 36 && ScreenTools.keyCode(for: "a") == 0 && ScreenTools.keyCode(for: "S") == 1 && ScreenTools.keyCode(for: "m") == 46 && ScreenTools.keyCode(for: "left") == 123 && ScreenTools.keyCode(for: "1") == 18 && ScreenTools.keyCode(for: "nope") == nil)
        check("screen: modifier flags", ScreenTools.flags(for: ["command", "shift"]).contains(.maskCommand) && ScreenTools.flags(for: ["cmd", "shift"]).contains(.maskShift) && !ScreenTools.flags(for: ["shift"]).contains(.maskCommand))
        check("screen: element list format", ScreenTools.format([AXElement(role: "AXButton", label: "Send", frame: .zero, value: nil), AXElement(role: "AXTextField", label: "Search", frame: .zero, value: "foo")]) == "[0] Button \"Send\"\n[1] TextField \"Search\" = \"foo\"")
        check("screen: text chunks", ScreenTools.chunks(of: "abcdefg", size: 3) == ["abc", "def", "g"])
        check("screen: eight tools registered with the right consent", ["list_windows": ToolConfirmation.auto, "focus_app": .auto, "read_window": .auto, "click_element": .confirm, "type_text": .confirm, "press_key": .confirm, "scroll": .auto, "read_screen_text": .auto].allSatisfy { name, kind in ToolRegistry.tool(named: name)?.confirmation == kind })
    }

    func testCustomization() {
        check("user tools: validate names + runners", { let ok = UserToolDef(name: "my_tool2", description: "d", runner: "shell", script: "true"); let r: Set<String> = ["list_files"]; return UserTools.validate(ok, reserved: r, taken: []) == nil && UserTools.validate(UserToolDef(name: "list_files", description: "d", runner: "shell", script: "x"), reserved: r, taken: []) != nil && UserTools.validate(UserToolDef(name: "Bad-Name", description: "d", runner: "shell", script: "x"), reserved: r, taken: []) != nil && UserTools.validate(UserToolDef(name: "mcp__x", description: "d", runner: "shell", script: "x"), reserved: r, taken: []) != nil && UserTools.validate(UserToolDef(name: "t2", description: "d", runner: "python", script: "x"), reserved: r, taken: []) != nil && UserTools.validate(ok, reserved: r, taken: ["my_tool2"]) != nil && UserTools.validate(UserToolDef(name: "t3", description: "d", params: ["bad key": UserToolParam()], runner: "shell", script: "x"), reserved: r, taken: []) != nil }())
        check("user tools: schema from params", { let d = UserToolDef(name: "t", description: "d", params: ["msg": UserToolParam(type: "string", description: "m", required: true), "n": UserToolParam(type: "integer"), "weird": UserToolParam(type: "array")], runner: "shell", script: "x"); let sch = UserTools.schema(for: d); let props = sch["properties"] as? [String: [String: Any]]; return (sch["type"] as? String) == "object" && (sch["required"] as? [String]) == ["msg"] && (props?["n"]?["type"] as? String) == "integer" && (props?["weird"]?["type"] as? String) == "string" && (sch["additionalProperties"] as? Bool) == false && UserTools.tool(for: d).confirmation == .confirm && UserTools.tool(for: UserToolDef(name: "t", description: "d", runner: "shell", script: "x", confirm: false)).confirmation == .auto }())
        check("user tools: placeholders + env names + values", { let d = UserToolDef(name: "t", description: "d", params: ["msg": UserToolParam(), "flag": UserToolParam(type: "boolean"), "n": UserToolParam(type: "number"), "missing": UserToolParam()], runner: "shell", script: "x"); let args: [String: Any] = (try? JSONSerialization.jsonObject(with: Data(#"{"msg":"say \"hi\"","flag":true,"n":1}"#.utf8))) as? [String: Any] ?? [:]; let v = UserTools.stringValues(args, for: d); return v["msg"] == "say \"hi\"" && v["flag"] == "true" && v["n"] == "1" && v["missing"] == "" && UserTools.envName("file name-2") == "FILE_NAME_2" && UserTools.substitute("echo {{msg}} {{missing}}!", v, quoting: .none) == "echo say \"hi\" !" && UserTools.substitute("display \"{{msg}}\"", v, quoting: .appleScript) == "display \"say \\\"hi\\\"\"" }())
        check("trust: disabled + don't ask round trip; alwaysAsk never trusted", { let n = "__selftest_tool__"; TrustSettings.setDisabled(n, true); let off = TrustSettings.isDisabled(n); TrustSettings.setDisabled(n, false); TrustSettings.setDontAsk(n, true); let trusted = TrustSettings.isTrusted(n); TrustSettings.setDontAsk(n, false); TrustSettings.setDontAsk("save_automation", true); let never = !TrustSettings.isTrusted("save_automation"); TrustSettings.setDontAsk("save_automation", false); return off && !TrustSettings.isDisabled(n) && trusted && !TrustSettings.isTrusted(n) && never }())
        check("instructions: block empty ↔ text; capped", UserInstructions.block(for: "  \n ").isEmpty && UserInstructions.block(for: "Call me Dee").hasSuffix("Call me Dee") && UserInstructions.block(for: String(repeating: "x", count: 9000)).count < 4300)
        check("registry: all = builtins + user tools", ToolRegistry.all.count == ToolRegistry.builtinTools.count + UserTools.tools.count && UserTools.reservedNames.contains("list_files") && UserTools.reservedNames.contains("run_subagent"))
        check("screen: keystrokes name their app", ScreenTools.appMatches("TextEdit", name: "TextEdit", bundleID: "com.apple.TextEdit") && ScreenTools.appMatches(" textedit.app ", name: "TextEdit", bundleID: nil) && ScreenTools.appMatches("com.apple.Safari", name: "Safari", bundleID: "com.apple.Safari") && !ScreenTools.appMatches("TextEdit", name: "ChatGPT", bundleID: "com.openai.chat") && !ScreenTools.appMatches("", name: "X", bundleID: nil) && !ScreenTools.appMatches("TextEdit", name: nil, bundleID: nil))
        check("screen: type_text + press_key require app", ((ScreenTools.typeTextTool.inputSchema["required"] as? [String]) ?? []).contains("app") && ((ScreenTools.pressKeyTool.inputSchema["required"] as? [String]) ?? []).contains("app") && (ScreenToolError.wrongFrontApp(wanted: "TextEdit", front: "ChatGPT").errorDescription ?? "").hasPrefix("Nothing was sent: ChatGPT is in front"))
        check("automation: old json decodes with no policy", { let json = #"{"id":"1","name":"n","recipeId":"r","paramsJSON":"{}","enabled":true,"lastRunKey":""}"#; let a = try? JSONDecoder().decode(Automation.self, from: Data(json.utf8)); return a?.policy == nil && a?.name == "n" }())
        check("ledger: start → finish", { let l = TaskLedger(); let id = l.start(goal: "g"); let running = l.running.count == 1; l.finish(id: id, result: "ok"); return running && l.entries.first?.status == .done && l.entries.first?.result == "ok" && id.count == 8 }())
        check("agent tools: six, consent kinds", AgentTools.tools.count == 6 && AgentTools.tools.filter { $0.confirmation == .confirm }.map(\.name).sorted() == ["delete_automation", "run_automation", "run_in_background", "run_subagent", "save_automation"])
        check("agent tools: automation lines", AgentTools.describe([Automation(id: "id1", name: "Morning", recipeId: "", paramsJSON: "{}", schedule: AutomationSchedule(hour: 9, minute: 0, days: nil), routineGoal: "check mail", policy: AgentPolicy(standingConsent: true))]).contains("id1 — Morning — ") && AgentTools.describe([]).contains("no saved"))
    }

    func testFunctionCallFallback() {
        check("fncall parses", app.parseToolCall("create_reminder(title=\"Call mom\", priority=\"high\")").map { $0.name == "create_reminder" && ($0.args["title"] as? String) == "Call mom" } ?? false)
        check("fncall prose→nil", app.parseToolCall("You can use open_url(url) to open a link.") == nil)
        check("fncall json intact", app.parseToolCall("{\"name\": \"list_files\", \"arguments\": {}}")?.name == "list_files")
        check("reminder priority word", (try? ReminderTools.shared.decodeCreateReminder(from: "{\"title\":\"x\",\"priority\":\"high\"}")).flatMap { $0.priority } == 1)
    }

    func testToolUseChips() {
        let chipConv = Conversation(chatWithApp: "T")
        chipConv.addToolChip(name: "create_reminder", inputJSON: "{}", content: "ok", isError: false, displaySummary: "Reminder added")
        check("toolChip visible", chipConv.visibleMessages.contains { $0.toolUses.first?.name == "create_reminder" })
        check("toolChip result linked", chipConv.messages.compactMap { $0.toolUses.first?.id }.first.flatMap { chipConv.toolResult(forUseId: $0) } != nil)
    }
}
