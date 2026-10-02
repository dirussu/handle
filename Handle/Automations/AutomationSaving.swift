import AppKit
import UserNotifications
import OSLog

// Turning "every day at…" and "when…" requests into saved automations.

extension AppDelegate {
    static let scheduleSpec = AIToolSpec(
        name: "schedule_task",
        description: "Save a RECURRING scheduled task. Only for requests like \"every day at 8am, …\" / \"each weekday morning, …\". days: 1=Sunday … 7=Saturday; omit for every day. \"8am\"→8, \"6pm\"→18, \"morning\"→8, \"evening\"→18.",
        inputSchema: ["type": "object",
                      "properties": ["hour": ["type": "integer", "minimum": 0, "maximum": 23],
                                     "minute": ["type": "integer", "minimum": 0, "maximum": 59],
                                     "days": ["type": "array", "items": ["type": "integer"], "description": "1=Sunday … 7=Saturday; omit for every day"],
                                     "task": ["type": "string", "description": "The action, with the scheduling words removed"]],
                      "required": ["hour", "minute", "task"]])

    static let triggerSpec = AIToolSpec(
        name: "set_trigger",
        description: "Save a task that runs WHENEVER AN EVENT happens (\"when X happens, do Y\"). The event is the when-part; task is the do-Y part. fileAppears: folder (screenshots land on ~/Desktop, downloads in ~/Downloads) + optional ext. appLaunches: the app's name. wifiConnects: optional ssid. windowMatches: title text (\"Zoom Meeting\"). calendarSoon: minutesBefore (\"10 minutes before\"→10). screenLocks: state lock|unlock.",
        inputSchema: ["type": "object",
                      "properties": ["kind": ["type": "string", "enum": ["fileAppears", "appLaunches", "wifiConnects", "windowMatches", "calendarSoon", "screenLocks"]],
                                     "folder": ["type": "string"], "ext": ["type": "string"], "app": ["type": "string"],
                                     "ssid": ["type": "string"], "window": ["type": "string"],
                                     "minutesBefore": ["type": "integer"], "state": ["type": "string", "enum": ["lock", "unlock"]],
                                     "task": ["type": "string", "description": "The do-Y action"]],
                      "required": ["kind", "task"]])

    /// A parsed schedule object (from a tool call or scraped JSON) → the automation schedule. Pure.
    static func scheduleFrom(_ o: [String: Any]) -> (schedule: AutomationSchedule, task: String)? {
        guard let task = o["task"] as? String, !task.isEmpty else { return nil }
        let days = (o["days"] as? [Any])?.compactMap { Self.intArg($0) }
        let sched = AutomationSchedule(hour: max(0, min(23, Self.intArg(o["hour"]) ?? 8)),
                                       minute: max(0, min(59, Self.intArg(o["minute"]) ?? 0)),
                                       days: (days?.isEmpty ?? true) ? nil : days)
        return (sched, task)
    }

    /// A parsed trigger object → the automation trigger. Pure.
    static func triggerFrom(_ o: [String: Any]) -> (trigger: AutomationTrigger, task: String)? {
        guard let task = o["task"] as? String, !task.isEmpty, let kind = o["kind"] as? String else { return nil }
        func str(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 } }
        switch kind {
        case "fileAppears":
            guard let folder = str("folder") else { return nil }
            return (AutomationTrigger(kind: kind, folder: folder, ext: str("ext")), task)
        case "appLaunches":
            guard let app = str("app") else { return nil }
            return (AutomationTrigger(kind: kind, app: app), task)
        case "wifiConnects":
            return (AutomationTrigger(kind: kind, ssid: str("ssid")), task)
        case "windowMatches":
            guard let window = str("window") else { return nil }
            return (AutomationTrigger(kind: kind, window: window), task)
        case "calendarSoon":
            let lead = Self.intArg(o["minutesBefore"]).map { max(1, min(120, $0)) } ?? 10
            return (AutomationTrigger(kind: kind, minutesBefore: lead), task)
        case "screenLocks":
            let state = str("state").flatMap { ["lock", "unlock"].contains($0) ? $0 : nil }
            return (AutomationTrigger(kind: kind, state: state), task)
        default:
            return nil
        }
    }

    /// True if the goal reads like a RECURRING schedule request ("every day at 8am…").
    func hasScheduleHint(_ goal: String) -> Bool {
        let t = goal.lowercased()
        return ["every ", "each ", "daily", "weekday", "weekly"].contains { t.contains($0) }
    }

    /// Ask a small model to split a schedule request into a time trigger + the task to do
    /// (NL→structured, its strength). Returns nil if it's not actually a schedule.
    func parseSchedule(_ goal: String) async -> (schedule: AutomationSchedule, task: String)? {
        if AIConfig.nativeTools {
            let (args, _) = await askForStructured("""
            The user said: "\(goal)"

            If this asks to SCHEDULE a recurring task, call schedule_task. If it is NOT a recurring/scheduled request, call nothing and reply: none
            """, tool: Self.scheduleSpec, label: "schedule parse")
            return args.flatMap(Self.scheduleFrom)
        }
        let reply = await askModel("""
        The user said: "\(goal)"

        If this asks to SCHEDULE a recurring task, reply with ONLY this JSON:
        {"hour": <0-23>, "minute": <0-59>, "days": <[1-7] or null>, "task": "<the action, with scheduling words removed>"}
        (days: 1=Sunday … 7=Saturday; null = every day. "8am"→8, "6pm"→18, "morning"→8, "evening"→18.)
        If it is NOT a recurring/scheduled request, reply with ONLY: none
        """)
        for json in jsonObjectCandidates(in: reply) {
            guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let parsed = Self.scheduleFrom(o) else { continue }
            return parsed
        }
        return nil
    }

    /// SAVE-AND-SCHEDULE flow: parse the schedule, match+fill a recipe for the task,
    /// confirm ONCE (standing consent), and persist. Returns true if it handled the turn.
    func saveScheduledAutomationIfRequested(goal: String, in conversation: Conversation) async -> Bool {
        guard let (schedule, task) = await parseSchedule(goal) else { return false }
        guard let recipe = await matchRecipe(goal: task) else {
            // No recipe → offer a ROUTINE: the task saves as an agentic
            // goal that runs fresh at each fire — gather (read-only tools + MCP)
            // → synthesize → notch pill. One card = standing consent, audited.
            return await saveRoutine(task: task, schedule: schedule, in: conversation)
        }
        let params = await fillParams(recipe: recipe, goal: task)
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let approved = await awaitConfirmation(in: conversation, title: "Save automation?",
            rows: [("When", schedule.describe),
                   ("Does", recipe.resolve(recipe.confirmTemplate, with: params)),
                   ("Script", recipe.resolve(recipe.body, with: params))],
            label: "save-automation")
        if Task.isCancelled { return true }
        guard approved else { conversation.commitAssistantMessage("Okay, I didn't save it."); return true }
        AutomationStore.shared.add(Automation(id: UUID().uuidString, name: recipe.title, recipeId: recipe.id,
                                              paramsJSON: paramsJSON, schedule: schedule))
        // Stage TCC now, while the user is present — a scheduled fire can't answer dialogs.
        let unprimed = PermissionsService.primeAutomationTargets(inScript: recipe.resolve(recipe.body, with: params))
        conversation.addToolChip(name: "run_applescript", inputJSON: "{}",
                                 content: "Scheduled \(schedule.describe)", isError: false, displaySummary: "Automation saved")
        var msg = "Saved — I'll \(recipe.title.lowercased()) \(schedule.describe)."
        if !unprimed.isEmpty {
            msg += " The first run may ask permission to control \(unprimed.joined(separator: ", "))."
        }
        conversation.commitAssistantMessage(msg)
        return true
    }

    /// ROUTINE SAVE — the standing-consent card for an agentic scheduled task,
    /// then persist. The card is explicit that each run works UNSUPERVISED with
    /// read-only tools + the user's connectors.
    func saveRoutine(task: String, schedule: AutomationSchedule, in conversation: Conversation) async -> Bool {
        let approved = await awaitConfirmation(in: conversation, title: "Save routine?",
            rows: [("When", schedule.describe),
                   ("Task", task),
                   ("How", "Each run, Handle gathers what it needs with read-only tools and your connectors, then puts a short result under the notch. No confirmations at run time — every step is audited.")],
            label: "save-routine")
        if Task.isCancelled { return true }
        guard approved else { conversation.commitAssistantMessage("Okay, I didn't save it."); return true }
        AutomationStore.shared.add(Automation(id: UUID().uuidString, name: Automation.routineName(task),
                                              recipeId: "", paramsJSON: "{}", schedule: schedule,
                                              routineGoal: task))
        conversation.addToolChip(name: "routine", inputJSON: "{}",
                                 content: "Scheduled \(schedule.describe)", isError: false, displaySummary: "Routine saved")
        conversation.commitAssistantMessage("Saved — \(schedule.describe) I'll \(Automation.routineName(task).lowercased()) and leave the result under the notch.")
        return true
    }

    /// High-precision gate for "save an EVENT automation" turns: needs a
    /// when/whenever framing AND event vocabulary (file / app-open / Wi-Fi).
    /// (Precision over recall — a miss falls through to recipes/action-loop.)
    func hasEventTriggerHint(_ goal: String) -> Bool {
        let t = goal.lowercased()
        // "10 minutes before my meeting, do X" carries no when/whenever — the
        // lead-time phrasing IS the trigger framing (calendarSoon).
        if ["minutes before", "min before", "minute before"].contains(where: { t.contains($0) }),
           ["meeting", "event", "call", "appointment", "calendar"].contains(where: { t.contains($0) }) {
            return true
        }
        guard ["when ", "whenever ", "any time ", "anytime "].contains(where: { t.contains($0) }) else { return false }
        return ["file", "pdf", "screenshot", "image", "png", "download", "appears in",
                "added to", "lands in", "saved to", "dropped in",
                "open", "launch", "start", "quit",
                "wifi", "wi-fi", "network", "connect", "join",
                "lock", "unlock", "window", "titled", "meeting", "call"].contains { t.contains($0) }
    }

    /// NL → {kind-specific trigger, task} via the local model (the same
    /// split-the-request pattern as parseSchedule). Nil = not an event-trigger request.
    func parseEventTrigger(_ goal: String) async -> (trigger: AutomationTrigger, task: String)? {
        if AIConfig.nativeTools {
            let (args, _) = await askForStructured("""
            The user said: "\(goal)"

            If this asks to run a task WHENEVER AN EVENT happens (phrased like "when X happens, do Y"), call set_trigger. If it is NOT a when-X-do-Y request, call nothing and reply: none
            """, tool: Self.triggerSpec, label: "trigger parse")
            return args.flatMap(Self.triggerFrom)
        }
        let reply = await askModel("""
        The user said: "\(goal)"

        If this asks to run a task WHENEVER AN EVENT happens (phrased like "when X happens, do Y"),
        reply with ONLY ONE of these JSON shapes. The event is the "when…" part; "task" is the do-Y part:
        - event: a file appears in a folder → {"kind": "fileAppears", "folder": "<e.g. ~/Downloads or ~/Desktop>", "ext": <"pdf"/"png"/etc or null for any file>, "task": "<the do-Y action>"}
          (screenshots land on ~/Desktop; downloads in ~/Downloads.)
        - event: the user opens/launches/starts an app → {"kind": "appLaunches", "app": "<that app's name>", "task": "<the do-Y action>"}
          (example: "when I open Mail, do Y" → {"kind": "appLaunches", "app": "Mail", "task": "do Y"})
        - event: joining a Wi-Fi network → {"kind": "wifiConnects", "ssid": <"the network name" or null for any network>, "task": "<the do-Y action>"}
        - event: a window with some title text is in front → {"kind": "windowMatches", "window": "<that title text>", "task": "<the do-Y action>"}
          (example: "when I'm in a Zoom meeting window, do Y" → {"kind": "windowMatches", "window": "Zoom Meeting", "task": "do Y"})
        - event: shortly BEFORE a calendar event/meeting → {"kind": "calendarSoon", "minutesBefore": <the lead time in minutes, e.g. "10 minutes before"→10>, "task": "<the do-Y action>"}
        - event: the screen locks or unlocks → {"kind": "screenLocks", "state": <"lock" or "unlock">, "task": "<the do-Y action>"}
        If it is NOT a when-X-do-Y request, reply with ONLY: none
        """)
        for json in jsonObjectCandidates(in: reply) {
            guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let parsed = Self.triggerFrom(o) else { continue }
            return parsed
        }
        return nil
    }

    /// SAVE-AND-WATCH flow: parse the trigger, match+fill a recipe for the task,
    /// confirm ONCE (standing consent), persist, and start watching. Mirrors
    /// saveScheduledAutomationIfRequested. Returns true if it handled the turn.
    func saveTriggeredAutomationIfRequested(goal: String, in conversation: Conversation) async -> Bool {
        guard let (trigger, task) = await parseEventTrigger(goal) else { return false }
        guard let recipe = await matchRecipe(goal: task) else {
            conversation.commitAssistantMessage("I can react \(trigger.describe), but I don't have a recipe for “\(task)” yet."); return true
        }
        let params = await fillParams(recipe: recipe, goal: task)
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let approved = await awaitConfirmation(in: conversation, title: "Save automation?",
            rows: [("When", trigger.describe),
                   ("Does", recipe.resolve(recipe.confirmTemplate, with: params)),
                   ("Script", recipe.resolve(recipe.body, with: params))],
            label: "save-automation")
        if Task.isCancelled { return true }
        guard approved else { conversation.commitAssistantMessage("Okay, I didn't save it."); return true }
        AutomationStore.shared.add(Automation(id: UUID().uuidString, name: recipe.title, recipeId: recipe.id,
                                              paramsJSON: paramsJSON, trigger: trigger))
        TriggerEngine.shared.refresh()
        // Stage TCC now, while the user is present — a triggered fire can't answer dialogs.
        let unprimed = PermissionsService.primeAutomationTargets(inScript: recipe.resolve(recipe.body, with: params))
        if trigger.kind == "wifiConnects", trigger.ssid != nil, PermissionsService.location() == .notDetermined {
            PermissionsService.requestLocation()   // reading the SSID needs Location on macOS
        }
        conversation.addToolChip(name: "run_applescript", inputJSON: "{}",
                                 content: "Watching: \(trigger.describe)", isError: false, displaySummary: "Automation saved")
        var msg = "Saved — I'll \(recipe.title.lowercased()) \(trigger.describe)."
        if !unprimed.isEmpty {
            msg += " The first run may ask permission to control \(unprimed.joined(separator: ", "))."
        }
        conversation.commitAssistantMessage(msg)
        return true
    }
}
