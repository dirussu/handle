import XCTest
import AppKit
@testable import Handle

final class AutomationTests: AppTestCase {
    func testShortcutsTools() {
        XCTAssertEqual(ToolRegistry.tool(named: "list_shortcuts")?.confirmation, .auto, "reg list_shortcuts=auto")
        XCTAssertEqual(ToolRegistry.tool(named: "run_shortcut")?.confirmation, .confirm, "reg run_shortcut=confirm")
        XCTAssertEqual((try? ShortcutsTools.shared.decodeRun(#"{"name":"Morning Routine"}"#))?.name, "Morning Routine", "shortcut decode name")
        XCTAssertNil((try? ShortcutsTools.shared.decodeRun(#"{"title":"x"}"#)), "shortcut decode missing → throws")
        XCTAssertTrue(ToolRegistry.promptSpec(for: ShortcutsTools.tools).contains("run_shortcut(name)"), "promptSpec names run_shortcut")
    }

    func testAutomationEdit() {
        XCTAssertEqual(AutomationSchedule.parseTime("18:30")?.hour, 18, "parseTime 18:30")
        XCTAssertEqual(AutomationSchedule.parseTime("8:05")?.minute, 5, "parseTime 8:05 minute")
        XCTAssertEqual(AutomationSchedule(hour: 8, minute: 5, days: nil).timeText, "8:05", "parseTime pads back")
        XCTAssertNil(AutomationSchedule.parseTime("24:00"), "parseTime 24:00 → nil")
        XCTAssertNil(AutomationSchedule.parseTime("9:60"), "parseTime 9:60 → nil")
        XCTAssertNil(AutomationSchedule.parseTime("six pm"), "parseTime junk → nil")
    }

    func testRecipeEngine() {
        XCTAssertEqual(RecipeLibrary.all.first { $0.id == "quit-apps" }!.resolve("{${apps}}", with: ["apps": ["Mail", "Slack"]] as [String: Any]), "{\"Mail\", \"Slack\"}", "recipe resolve list")
        XCTAssertEqual(RecipeLibrary.all.first { $0.id == "set-volume" }!.resolve("vol ${level}", with: ["level": 30] as [String: Any]), "vol 30", "recipe resolve int")
        XCTAssertEqual(RecipeLibrary.prefilter("pause my music").first?.id, "music-control", "recipe prefilter music")
        XCTAssertEqual(RecipeLibrary.prefilter("turn the volume down to 20").first?.id, "set-volume", "recipe prefilter volume")
        XCTAssertEqual(RecipeLibrary.all.first { $0.id == "set-volume" }!.resolve("v ${level}", with: ["level": [25]] as [String: Any]), "v 25", "recipe unwrap scalar-in-array")
        XCTAssertEqual(RecipeLibrary.all.first { $0.id == "dark-mode" }!.resolve("dm ${state}", with: ["state": 1] as [String: Any]), "dm true", "recipe oneOf coerce bool")
    }

    func testFileLoadedRecipes() {
        let sampleMd = "---\nid: test-x\ntitle: Test recipe\nkeywords: foo, bar\nconfirm: Do ${n}\nparam: n | int | a number\n---\nset x to ${n}"
        let parsedRecipe = RecipeFile.parse(sampleMd)
        XCTAssertEqual(parsedRecipe?.id, "test-x", "recipe .md parse id+param")
        XCTAssertEqual(parsedRecipe?.params.first?.name, "n", "recipe .md parse id+param")
        XCTAssertEqual(parsedRecipe?.body, "set x to ${n}", "recipe .md parse body")
    }

    func testAutomationScheduleLogic() {
        XCTAssertTrue(AutomationSchedule(hour: 9, minute: 30, days: nil).isDue(DateComponents(hour: 9, minute: 30)), "schedule isDue match")
        XCTAssertFalse(AutomationSchedule(hour: 9, minute: 30, days: nil).isDue(DateComponents(hour: 9, minute: 31)), "schedule isDue miss")
        XCTAssertEqual(AutomationSchedule(hour: 18, minute: 0, days: nil).describe, "every day at 6:00 PM", "schedule describe pm")
    }

    func testEventTriggers() {
        XCTAssertTrue(app.hasEventTriggerHint("when a pdf lands in downloads, open it"), "trigHint when+pdf")
        XCTAssertTrue(app.hasEventTriggerHint("whenever I take a screenshot, move it"), "trigHint whenever+screenshot")
        XCTAssertFalse(app.hasEventTriggerHint("open the pdf in downloads"), "trigHint no-when→false")
        XCTAssertFalse(app.hasEventTriggerHint("when I say go, set the volume to 20"), "trigHint when-no-file→false")
        XCTAssertEqual(AutomationTrigger(kind: "fileAppears", folder: "~/Downloads", ext: "pdf").describe, "when a .pdf file appears in ~/Downloads", "trigger describe ext")
        XCTAssertEqual(AutomationTrigger(kind: "fileAppears", folder: "~/Desktop", ext: nil).describe, "when a file appears in ~/Desktop", "trigger describe any")
        XCTAssertEqual(FolderWatcher.newEntries(known: ["a.pdf"], now: ["a.pdf", "b.pdf", ".DS_Store"]), ["b.pdf"], "watcher diff new")
        XCTAssertTrue(FolderWatcher.newEntries(known: ["a.pdf"], now: ["a.pdf"]).isEmpty, "watcher diff none")
        XCTAssertTrue(TriggerEngine.matches(ext: "pdf", filename: "report.PDF"), "trigger ext match")
        XCTAssertFalse(TriggerEngine.matches(ext: "pdf", filename: "photo.png"), "trigger ext reject")
        XCTAssertTrue(TriggerEngine.matches(ext: nil, filename: "anything.zip"), "trigger ext any")
        XCTAssertTrue(TriggerEngine.expand("~/Downloads").hasPrefix("/"), "trigger expand ~")
        XCTAssertTrue(app.hasEventTriggerHint("when I open zoom, set the volume to 30"), "trigHint when+open-app")
        XCTAssertTrue(app.hasEventTriggerHint("whenever I join my home wifi, open downloads"), "trigHint when+wifi")
        XCTAssertTrue(TriggerEngine.appMatches(want: "zoom", name: "zoom.us", bundleID: "us.zoom.xos"), "app match name")
        XCTAssertTrue(TriggerEngine.appMatches(want: "Calculator", name: nil, bundleID: "com.apple.calculator"), "app match bundle")
        XCTAssertFalse(TriggerEngine.appMatches(want: "zoom", name: "Safari", bundleID: "com.apple.Safari"), "app reject")
        XCTAssertFalse(TriggerEngine.appMatches(want: nil, name: "Safari", bundleID: nil), "app nil-want reject")
        XCTAssertTrue(TriggerEngine.ssidMatches(want: nil, got: "Anything"), "ssid any")
        XCTAssertTrue(TriggerEngine.ssidMatches(want: "HomeNet 5G", got: "homenet5g"), "ssid exact ci")
        XCTAssertFalse(TriggerEngine.ssidMatches(want: "HomeNet", got: "CafeWifi"), "ssid reject")
        XCTAssertFalse(TriggerEngine.ssidMatches(want: "HomeNet", got: nil), "ssid want-no-got reject")
        XCTAssertEqual(AutomationTrigger(kind: "appLaunches", app: "Zoom").describe, "when Zoom opens", "trigger describe app")
        XCTAssertEqual(AutomationTrigger(kind: "wifiConnects").describe, "when Wi-Fi connects", "trigger describe wifi any")
    }

    func testRoutines() {
        let routine = Automation(id: "r1", name: Automation.routineName("summarize my calendar\nsecond line"),
                                 recipeId: "", paramsJSON: "{}",
                                 schedule: AutomationSchedule(hour: 8, minute: 0, days: nil), routineGoal: "summarize my calendar")
        XCTAssertEqual(routine.name, "summarize my calendar", "routine name = first line")
        XCTAssertEqual(Automation.routineName(String(repeating: "x", count: 200)).count, 60, "routine name capped 60")
        let routineData = try? JSONEncoder().encode([routine])
        let routineBack = routineData.flatMap { try? JSONDecoder().decode([Automation].self, from: $0) }?.first
        XCTAssertEqual(routineBack?.routineGoal, "summarize my calendar", "routine codable roundtrip")
        let legacyJSON = #"[{"id":"a","name":"n","recipeId":"set-volume","paramsJSON":"{}","enabled":true,"lastRunKey":""}]"#
        let legacy = (try? JSONDecoder().decode([Automation].self, from: Data(legacyJSON.utf8)))?.first
        XCTAssertEqual(legacy?.recipeId, "set-volume", "legacy automation decodes")
        XCTAssertNil(legacy?.routineGoal, "legacy automation decodes")
        let routineAutoTools = ToolRegistry.all.filter { $0.confirmation == .auto }
        XCTAssertFalse(routineAutoTools.isEmpty, "routine auto tools nonempty")
        XCTAssertFalse(routineAutoTools.contains { $0.name == "run_applescript" }, "routine auto excludes applescript")
        XCTAssertFalse(routineAutoTools.contains { $0.name == "run_shell" }, "routine auto excludes shell")
        XCTAssertFalse(routineAutoTools.contains { $0.name.hasPrefix("draft_") }, "routine auto excludes drafts")
    }

    func testTriggersBatch() {
        XCTAssertTrue(TriggerEngine.windowTitleMatches(want: "zoom meeting", title: "Zoom Meeting — Weekly Sync"), "trig window match ci")
        XCTAssertFalse(TriggerEngine.windowTitleMatches(want: "zoom", title: "Safari"), "trig window reject")
        XCTAssertFalse(TriggerEngine.windowTitleMatches(want: "zoom", title: nil), "trig window nil title")
        XCTAssertFalse(TriggerEngine.windowTitleMatches(want: "", title: "anything"), "trig window empty want")
        let trigNow = Date()
        XCTAssertTrue(TriggerEngine.calendarSoonDue(start: trigNow.addingTimeInterval(8 * 60), now: trigNow, minutesBefore: 10), "trig cal due inside")
        XCTAssertFalse(TriggerEngine.calendarSoonDue(start: trigNow.addingTimeInterval(15 * 60), now: trigNow, minutesBefore: 10), "trig cal not yet")
        XCTAssertFalse(TriggerEngine.calendarSoonDue(start: trigNow.addingTimeInterval(-60), now: trigNow, minutesBefore: 10), "trig cal started → no")
        XCTAssertTrue(TriggerEngine.calendarSoonDue(start: trigNow.addingTimeInterval(600), now: trigNow, minutesBefore: 10), "trig cal exact edge")
        XCTAssertTrue(TriggerEngine.lockStateMatches(want: nil, locked: true), "trig lock default")
        XCTAssertTrue(TriggerEngine.lockStateMatches(want: "unlock", locked: false), "trig lock unlock")
        XCTAssertFalse(TriggerEngine.lockStateMatches(want: "unlock", locked: true), "trig lock mismatch")
        XCTAssertEqual(AutomationTrigger(kind: "windowMatches", window: "Zoom Meeting").describe, "when a window titled “Zoom Meeting” is in front", "trig describe window")
        XCTAssertEqual(AutomationTrigger(kind: "calendarSoon", minutesBefore: 5).describe, "5 min before a calendar event", "trig describe calendar")
        XCTAssertEqual(AutomationTrigger(kind: "calendarSoon").describe, "10 min before a calendar event", "trig describe cal default")
        XCTAssertEqual(AutomationTrigger(kind: "screenLocks").describe, "when the screen locks", "trig describe lock")
        XCTAssertEqual(AutomationTrigger(kind: "screenLocks", state: "unlock").describe, "when the screen unlocks", "trig describe unlock")
        XCTAssertTrue(app.hasEventTriggerHint("when I lock my screen, pause the music"), "trigHint lock")
        XCTAssertTrue(app.hasEventTriggerHint("whenever a window titled invoice is in front, set volume to 20"), "trigHint window")
        XCTAssertTrue(app.hasEventTriggerHint("10 minutes before my next meeting, set the volume to 15"), "trigHint minutes-before")
        XCTAssertFalse(app.hasEventTriggerHint("10 minutes before lunch, remind me"), "trigHint before-no-cal → false")
        XCTAssertNil((try? JSONDecoder().decode(AutomationTrigger.self, from: Data(#"{"kind":"fileAppears","folder":"~/Downloads"}"#.utf8)))?.minutesBefore, "trig legacy decode new fields nil")
    }
}
