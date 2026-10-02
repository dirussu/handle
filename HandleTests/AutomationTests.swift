import XCTest
import AppKit
@testable import Handle

final class AutomationTests: AppTestCase {
    func testShortcutsTools() {
        check("reg list_shortcuts=auto", ToolRegistry.tool(named: "list_shortcuts")?.confirmation == .auto)
        check("reg run_shortcut=confirm", ToolRegistry.tool(named: "run_shortcut")?.confirmation == .confirm)
        check("shortcut decode name", (try? ShortcutsTools.shared.decodeRun(#"{"name":"Morning Routine"}"#))?.name == "Morning Routine")
        check("shortcut decode missing → throws", (try? ShortcutsTools.shared.decodeRun(#"{"title":"x"}"#)) == nil)
        check("promptSpec names run_shortcut", ToolRegistry.promptSpec(for: ShortcutsTools.tools).contains("run_shortcut(name)"))
    }

    func testAutomationEdit() {
        check("parseTime 18:30", AutomationSchedule.parseTime("18:30")?.hour == 18)
        check("parseTime 8:05 minute", AutomationSchedule.parseTime("8:05")?.minute == 5)
        check("parseTime pads back", AutomationSchedule(hour: 8, minute: 5, days: nil).timeText == "8:05")
        check("parseTime 24:00 → nil", AutomationSchedule.parseTime("24:00") == nil)
        check("parseTime 9:60 → nil", AutomationSchedule.parseTime("9:60") == nil)
        check("parseTime junk → nil", AutomationSchedule.parseTime("six pm") == nil)
    }

    func testRecipeEngine() {
        check("recipe resolve list", RecipeLibrary.all.first { $0.id == "quit-apps" }!.resolve("{${apps}}", with: ["apps": ["Mail", "Slack"]] as [String: Any]) == "{\"Mail\", \"Slack\"}")
        check("recipe resolve int", RecipeLibrary.all.first { $0.id == "set-volume" }!.resolve("vol ${level}", with: ["level": 30] as [String: Any]) == "vol 30")
        check("recipe prefilter music", RecipeLibrary.prefilter("pause my music").first?.id == "music-control")
        check("recipe prefilter volume", RecipeLibrary.prefilter("turn the volume down to 20").first?.id == "set-volume")
        check("recipe unwrap scalar-in-array", RecipeLibrary.all.first { $0.id == "set-volume" }!.resolve("v ${level}", with: ["level": [25]] as [String: Any]) == "v 25")
        check("recipe oneOf coerce bool", RecipeLibrary.all.first { $0.id == "dark-mode" }!.resolve("dm ${state}", with: ["state": 1] as [String: Any]) == "dm true")
    }

    func testFileLoadedRecipes() {
        let sampleMd = "---\nid: test-x\ntitle: Test recipe\nkeywords: foo, bar\nconfirm: Do ${n}\nparam: n | int | a number\n---\nset x to ${n}"
        let parsedRecipe = RecipeFile.parse(sampleMd)
        check("recipe .md parse id+param", parsedRecipe?.id == "test-x" && parsedRecipe?.params.first?.name == "n")
        check("recipe .md parse body", parsedRecipe?.body == "set x to ${n}")
    }

    func testAutomationScheduleLogic() {
        check("schedule isDue match", AutomationSchedule(hour: 9, minute: 30, days: nil).isDue(DateComponents(hour: 9, minute: 30)))
        check("schedule isDue miss", !AutomationSchedule(hour: 9, minute: 30, days: nil).isDue(DateComponents(hour: 9, minute: 31)))
        check("schedule describe pm", AutomationSchedule(hour: 18, minute: 0, days: nil).describe == "every day at 6:00 PM")
    }

    func testEventTriggers() {
        check("trigHint when+pdf", app.hasEventTriggerHint("when a pdf lands in downloads, open it"))
        check("trigHint whenever+screenshot", app.hasEventTriggerHint("whenever I take a screenshot, move it"))
        check("trigHint no-when→false", !app.hasEventTriggerHint("open the pdf in downloads"))
        check("trigHint when-no-file→false", !app.hasEventTriggerHint("when I say go, set the volume to 20"))
        check("trigger describe ext", AutomationTrigger(kind: "fileAppears", folder: "~/Downloads", ext: "pdf").describe == "when a .pdf file appears in ~/Downloads")
        check("trigger describe any", AutomationTrigger(kind: "fileAppears", folder: "~/Desktop", ext: nil).describe == "when a file appears in ~/Desktop")
        check("watcher diff new", FolderWatcher.newEntries(known: ["a.pdf"], now: ["a.pdf", "b.pdf", ".DS_Store"]) == ["b.pdf"])
        check("watcher diff none", FolderWatcher.newEntries(known: ["a.pdf"], now: ["a.pdf"]).isEmpty)
        check("trigger ext match", TriggerEngine.matches(ext: "pdf", filename: "report.PDF"))
        check("trigger ext reject", !TriggerEngine.matches(ext: "pdf", filename: "photo.png"))
        check("trigger ext any", TriggerEngine.matches(ext: nil, filename: "anything.zip"))
        check("trigger expand ~", TriggerEngine.expand("~/Downloads").hasPrefix("/"))
        check("trigHint when+open-app", app.hasEventTriggerHint("when I open zoom, set the volume to 30"))
        check("trigHint when+wifi", app.hasEventTriggerHint("whenever I join my home wifi, open downloads"))
        check("app match name", TriggerEngine.appMatches(want: "zoom", name: "zoom.us", bundleID: "us.zoom.xos"))
        check("app match bundle", TriggerEngine.appMatches(want: "Calculator", name: nil, bundleID: "com.apple.calculator"))
        check("app reject", !TriggerEngine.appMatches(want: "zoom", name: "Safari", bundleID: "com.apple.Safari"))
        check("app nil-want reject", !TriggerEngine.appMatches(want: nil, name: "Safari", bundleID: nil))
        check("ssid any", TriggerEngine.ssidMatches(want: nil, got: "Anything"))
        check("ssid exact ci", TriggerEngine.ssidMatches(want: "HomeNet 5G", got: "homenet5g"))
        check("ssid reject", !TriggerEngine.ssidMatches(want: "HomeNet", got: "CafeWifi"))
        check("ssid want-no-got reject", !TriggerEngine.ssidMatches(want: "HomeNet", got: nil))
        check("trigger describe app", AutomationTrigger(kind: "appLaunches", app: "Zoom").describe == "when Zoom opens")
        check("trigger describe wifi any", AutomationTrigger(kind: "wifiConnects").describe == "when Wi-Fi connects")
    }

    func testRoutines() {
        let routine = Automation(id: "r1", name: Automation.routineName("summarize my calendar\nsecond line"),
                                 recipeId: "", paramsJSON: "{}",
                                 schedule: AutomationSchedule(hour: 8, minute: 0, days: nil), routineGoal: "summarize my calendar")
        check("routine name = first line", routine.name == "summarize my calendar")
        check("routine name capped 60", Automation.routineName(String(repeating: "x", count: 200)).count == 60)
        let routineData = try? JSONEncoder().encode([routine])
        let routineBack = routineData.flatMap { try? JSONDecoder().decode([Automation].self, from: $0) }?.first
        check("routine codable roundtrip", routineBack?.routineGoal == "summarize my calendar")
        let legacyJSON = #"[{"id":"a","name":"n","recipeId":"set-volume","paramsJSON":"{}","enabled":true,"lastRunKey":""}]"#
        let legacy = (try? JSONDecoder().decode([Automation].self, from: Data(legacyJSON.utf8)))?.first
        check("legacy automation decodes", legacy?.recipeId == "set-volume" && legacy?.routineGoal == nil)
        let routineAutoTools = ToolRegistry.all.filter { $0.confirmation == .auto }
        check("routine auto tools nonempty", !routineAutoTools.isEmpty)
        check("routine auto excludes applescript", !routineAutoTools.contains { $0.name == "run_applescript" })
        check("routine auto excludes shell", !routineAutoTools.contains { $0.name == "run_shell" })
        check("routine auto excludes drafts", !routineAutoTools.contains { $0.name.hasPrefix("draft_") })
    }

    func testTriggersBatch() {
        check("trig window match ci", TriggerEngine.windowTitleMatches(want: "zoom meeting", title: "Zoom Meeting — Weekly Sync"))
        check("trig window reject", !TriggerEngine.windowTitleMatches(want: "zoom", title: "Safari"))
        check("trig window nil title", !TriggerEngine.windowTitleMatches(want: "zoom", title: nil))
        check("trig window empty want", !TriggerEngine.windowTitleMatches(want: "", title: "anything"))
        let trigNow = Date()
        check("trig cal due inside", TriggerEngine.calendarSoonDue(start: trigNow.addingTimeInterval(8 * 60), now: trigNow, minutesBefore: 10))
        check("trig cal not yet", !TriggerEngine.calendarSoonDue(start: trigNow.addingTimeInterval(15 * 60), now: trigNow, minutesBefore: 10))
        check("trig cal started → no", !TriggerEngine.calendarSoonDue(start: trigNow.addingTimeInterval(-60), now: trigNow, minutesBefore: 10))
        check("trig cal exact edge", TriggerEngine.calendarSoonDue(start: trigNow.addingTimeInterval(600), now: trigNow, minutesBefore: 10))
        check("trig lock default", TriggerEngine.lockStateMatches(want: nil, locked: true))
        check("trig lock unlock", TriggerEngine.lockStateMatches(want: "unlock", locked: false))
        check("trig lock mismatch", !TriggerEngine.lockStateMatches(want: "unlock", locked: true))
        check("trig describe window", AutomationTrigger(kind: "windowMatches", window: "Zoom Meeting").describe == "when a window titled “Zoom Meeting” is in front")
        check("trig describe calendar", AutomationTrigger(kind: "calendarSoon", minutesBefore: 5).describe == "5 min before a calendar event")
        check("trig describe cal default", AutomationTrigger(kind: "calendarSoon").describe == "10 min before a calendar event")
        check("trig describe lock", AutomationTrigger(kind: "screenLocks").describe == "when the screen locks")
        check("trig describe unlock", AutomationTrigger(kind: "screenLocks", state: "unlock").describe == "when the screen unlocks")
        check("trigHint lock", app.hasEventTriggerHint("when I lock my screen, pause the music"))
        check("trigHint window", app.hasEventTriggerHint("whenever a window titled invoice is in front, set volume to 20"))
        check("trigHint minutes-before", app.hasEventTriggerHint("10 minutes before my next meeting, set the volume to 15"))
        check("trigHint before-no-cal → false", !app.hasEventTriggerHint("10 minutes before lunch, remind me"))
        check("trig legacy decode new fields nil", (try? JSONDecoder().decode(AutomationTrigger.self, from: Data(#"{"kind":"fileAppears","folder":"~/Downloads"}"#.utf8)))?.minutesBefore == nil)
    }
}
