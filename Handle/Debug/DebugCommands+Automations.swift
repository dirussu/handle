import SwiftUI
import AppKit
import OSLog

// Debug commands for routines, schedules and triggers.

#if DEBUG

extension AppDelegate {
    /// APP-LAUNCH TRIGGER TEST (`__trigapptest__`): set volume to 35 whenever
    /// Calculator launches — validates NSWorkspace source → match → fire.
    func runTrigAppTest() {
        AutomationStore.shared.add(Automation(id: "trigapptest", name: "app-launch test", recipeId: "set-volume",
                                              paramsJSON: "{\"level\": 35}",
                                              trigger: AutomationTrigger(kind: "appLaunches", app: "Calculator")))
        TriggerEngine.shared.refresh()
        agentLog.info("trigapptest: watching for Calculator launch — open it to fire")
    }

    /// TRIGGER TEST (`__trigtest__`): watch /tmp/handle_trigger_test for new .png files
    /// and set volume to 25 when one appears — validates the reactive path end to end
    /// (watcher → engine match → runAutomation, no card, audited).
    func runTrigTest() {
        let dir = "/tmp/handle_trigger_test"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        AutomationStore.shared.add(Automation(id: "trigtest", name: "trigger test", recipeId: "set-volume",
                                              paramsJSON: "{\"level\": 25}",
                                              trigger: AutomationTrigger(kind: "fileAppears", folder: dir, ext: "png")))
        TriggerEngine.shared.refresh()
        agentLog.info("trigtest: watching \(dir, privacy: .public) for .png — drop a file to fire")
    }

    /// SCHEDULER TEST (`__schedtest__`): save a "set volume to 12" automation firing ~70s
    /// out (no card) and let the live scheduler pick it up — validates the tick loop.
    func runSchedTest() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(70))
        AutomationStore.shared.add(Automation(id: "schedtest", name: "sched test", recipeId: "set-volume",
                                              paramsJSON: "{\"level\": 12}",
                                              schedule: AutomationSchedule(hour: c.hour ?? 0, minute: c.minute ?? 0, days: nil)))
        agentLog.info("schedtest: saved automation firing at \(c.hour ?? 0):\(c.minute ?? 0) — watch for the scheduler")
    }

    /// `__trigbatchtest__`
    func debugCheckTriggerBatch(_ cmd: String) async {
        // v2 TRIGGERS BATCH: save one automation per new kind, then
        // drive the REAL handlers with synthetic events (locking the
        // the screen or editing the calendar is off-limits) —
        // proves match → dedupe → fire → recipe run for all three.
        AutomationStore.shared.add(Automation(id: "trigwin", name: "window test", recipeId: "set-volume",
            paramsJSON: "{\"level\": 31}", trigger: AutomationTrigger(kind: "windowMatches", window: "Handle Probe")))
        AutomationStore.shared.add(Automation(id: "trigcal", name: "calendar test", recipeId: "set-volume",
            paramsJSON: "{\"level\": 32}", trigger: AutomationTrigger(kind: "calendarSoon", minutesBefore: 10)))
        AutomationStore.shared.add(Automation(id: "triglock", name: "lock test", recipeId: "set-volume",
            paramsJSON: "{\"level\": 33}", trigger: AutomationTrigger(kind: "screenLocks", state: "lock")))
        TriggerEngine.shared.refresh()
        agentLog.info("trigbatchtest: sources up — simulating events")
        // window: fires once, same title deduped, new title fires again
        TriggerEngine.shared.handleWindowTick(app: "TestApp", title: "Handle Probe — draft 1")
        TriggerEngine.shared.handleWindowTick(app: "TestApp", title: "Handle Probe — draft 1")   // deduped
        TriggerEngine.shared.handleWindowTick(app: "TestApp", title: "Handle Probe — draft 2")   // fires
        // calendar: one due event fires ONCE across two ticks; a far event never fires
        let synth = [(id: "ev1", title: "Standup", start: Date().addingTimeInterval(8 * 60)),
                     (id: "ev2", title: "Far away", start: Date().addingTimeInterval(90 * 60))]
        TriggerEngine.shared.handleCalendarTick(events: synth)
        TriggerEngine.shared.handleCalendarTick(events: synth)   // deduped
        // lock: lock fires the lock-state automation; unlock doesn't
        TriggerEngine.shared.handleLockChange(locked: true)
        TriggerEngine.shared.handleLockChange(locked: false)     // no match (state=lock)
        // real calendar read path (read-only, no prompt)
        let real = CalendarTools.shared.eventsStartingSoon(within: 120)
        agentLog.info("trigbatchtest: real calendar read — \(real.count) event(s) in next 2h")
        for id in ["trigwin", "trigcal", "triglock"] { AutomationStore.shared.remove(id: id) }
        TriggerEngine.shared.refresh()
        agentLog.info("trigbatchtest: DONE (want fires: window ×2, Standup ×1, lock ×1)")
    }

    /// `__routinesave__`
    func debugCheckRoutineSave(_ cmd: String) async {
        // ROUTINE SAVE FLOW: the real turn path (parseSchedule → no
        // recipe → routine card, auto-approved) on a throwaway convo.
        let goal = String(cmd.dropFirst("__routinesave__ ".count))
        let convo = Conversation(chatWithApp: "RoutineTest")
        let approver = Task { @MainActor in
            for _ in 0..<600 {
                if let req = convo.pendingConfirmation {
                    agentLog.info("routinesave: card shown — auto-approving")
                    req.onDecision(true); return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let handled = await self.saveScheduledAutomationIfRequested(goal: goal, in: convo)
        approver.cancel()
        let saved = AutomationStore.shared.automations.last
        agentLog.info("routinesave: handled=\(handled) saved=\"\(saved?.name ?? "-", privacy: .public)\" goal=\"\(saved?.routineGoal ?? "-", privacy: .public)\" when=\(saved?.schedule?.describe ?? "-", privacy: .public) last=\"\(convo.visibleMessages.last.map(\.text) ?? "-", privacy: .public)\"")
    }

    /// `__routineschedtest__`
    func debugCheckRoutineSchedule(_ cmd: String) async {
        // SCHEDULER→ROUTINE: persist a routine due ~70s out (no card,
        // DEBUG) and let the LIVE scheduler tick fire it — proves
        // tick → runRoutine → summary pill. Self-removes after.
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(70))
        let a = Automation(id: "routineschedtest", name: "Routine sched test",
                           recipeId: "", paramsJSON: "{}",
                           schedule: AutomationSchedule(hour: c.hour ?? 8, minute: c.minute ?? 0, days: nil),
                           routineGoal: "summarize what's on my calendar today")
        AutomationStore.shared.add(a)
        agentLog.info("routineschedtest: saved, due \(a.schedule?.describe ?? "?", privacy: .public) — watch for the scheduler fire")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(150))
            AutomationStore.shared.remove(id: "routineschedtest")
            agentLog.info("routineschedtest: cleaned up")
        }
    }

    /// `__routinetest__`
    func debugRunRoutineOnce(_ cmd: String) async {
        // ROUTINE E2E: run an EPHEMERAL routine (not saved) through the
        // real fire path right now — gather → synthesize → pill.
        let goal = String(cmd.dropFirst("__routinetest__ ".count))
        let a = Automation(id: "routinetest", name: Automation.routineName(goal),
                           recipeId: "", paramsJSON: "{}", schedule: nil, routineGoal: goal)
        agentLog.info("routinetest: goal=\"\(goal, privacy: .public)\"")
        await self.runAutomation(a)
        agentLog.info("routinetest: DONE")
    }

    /// `__trigparse__`
    func debugCheckTriggerParsing(_ cmd: String) async {
        let goal = String(cmd.dropFirst(14))
        let hit = self.hasEventTriggerHint(goal) ?? false
        if let (t, task) = await self.parseEventTrigger(goal) {
            agentLog.info("trigparse: hint=\(hit) trigger=\"\(t.describe, privacy: .public)\" task=\"\(task, privacy: .public)\"")
        } else {
            agentLog.info("trigparse: hint=\(hit) → nil (not an event-trigger request)")
        }
    }
}

#endif
