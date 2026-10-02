import SwiftUI
import AppKit
import OSLog

// Debug builds only: a command hook for driving the app from the terminal, plus probes and UI renders.

#if DEBUG

extension AppDelegate {
    // A command hook for driving the app without touching its interface. The app polls a
    // command file; each command runs one path (a full turn, a routine, a UI render) and
    // logs the outcome to the unified log (subsystem com.dimarussu.Handle, category Agent).

    static let testCmdPath = "/tmp/handle_test_cmd"

    /// The repo's `tools/` folder (test doubles), from this source file's location.
    static let repoToolsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tools").path

    func startTestHarness() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let raw = try? String(contentsOfFile: Self.testCmdPath, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(atPath: Self.testCmdPath)   // consume immediately
            let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { return }
            Task { @MainActor in
                if cmd == "__uishot__" { self?.renderUIShots() }
                else if cmd.hasPrefix("__websearch__ ") {
                    // Toggle the Settings → AI web-search switch from the harness.
                    WebSettings.searchEnabled = cmd.hasSuffix(" on")
                    agentLog.info("harness: websearch=\(WebSettings.searchEnabled)")
                }
                else if cmd.hasPrefix("__autoapprove__") { Self.debugAutoApprove = cmd.hasSuffix("on"); agentLog.info("harness: autoapprove=\(Self.debugAutoApprove)") }
                else if cmd == "__seetest__" {
                    // Exclusion, live: put the FRONTMOST app on the list, try an
                    // ambient See turn, expect no capture + the withheld caption +
                    // a text-only cloud request; then restore the list.
                    guard let self else { return }
                    let saved = SeeSettings.excludedBundleIDs
                    let front = NSWorkspace.shared.frontmostApplication
                    SeeSettings.setExcluded(saved + [front?.bundleIdentifier ?? "none"])
                    let convo = Conversation(chatWithApp: "")
                    await self.handleAmbientTurn(text: "what is on my screen right now", in: convo)
                    let msg = convo.messages.last(where: { $0.role == .user })
                    agentLog.info("seetest: front=\(front?.localizedName ?? "?", privacy: .public) image=\(msg?.image != nil) status=\(msg?.screenshotStatus.map { $0.caption } ?? "nil", privacy: .public) preambleHasNote=\(convo.pendingContextPreamble.contains("NOT captured"))")
                    let before = CloudEngine.shared.sent.count
                    _ = await self.streamOneTurn(in: convo, instr: "", display: false)
                    let rec = CloudEngine.shared.sent.first
                    agentLog.info("seetest: sent +\(CloudEngine.shared.sent.count - before) label=\"\(rec?.label ?? "-", privacy: .public)\" image=\(rec?.imageThumbnail != nil) in=\(rec?.usage.input ?? -1) cost=\(rec?.cost.map { AICost.format($0) } ?? "nil", privacy: .public)")
                    SeeSettings.setExcluded(saved)
                    agentLog.info("seetest DONE (excluded list restored: \(saved.count) entries)")
                }
                else if cmd == "__comet__" { await self?.runCometProbe() }
                else if cmd == "__highlight__" { self?.runHighlightProbe() }
                else if cmd == "__axtree__" { self?.runAXTreeDump() }
                else if cmd.hasPrefix("__plan__ ") { await self?.runPlanProbe(goal: String(cmd.dropFirst(9))) }
                else if cmd.hasPrefix("__recipe__ ") { await self?.runRecipeProbe(goal: String(cmd.dropFirst(11))) }
                else if cmd == "__schedtest__" { self?.runSchedTest() }
                else if cmd == "__trigtest__" { self?.runTrigTest() }
                else if cmd == "__trigapptest__" { self?.runTrigAppTest() }
                else if cmd.hasPrefix("__chatprobe__ ") {
                    // Plain text turns straight through streamOneTurn — for tone/
                    // wording checks without driving the GUI. " || " separates
                    // successive turns of ONE conversation (multi-turn repros).
                    guard let self else { return }
                    let convo = Conversation(chatWithApp: "")
                    for turn in String(cmd.dropFirst("__chatprobe__ ".count)).components(separatedBy: " || ") {
                        convo.addUserMessage(turn)
                        let reply = await self.streamOneTurn(in: convo, instr: "", display: false)
                        let shown = Conversation.withoutEmoji(reply)
                        convo.commitAssistantMessage(shown)
                        // Log the DISPLAYED form — commit-time filtering applied.
                        agentLog.info("chatprobe [\(turn.prefix(40), privacy: .public)] → \(shown.prefix(300), privacy: .public)")
                    }
                }
                else if cmd == "__identityeval__" {
                    // Identity block eval (EVALS.md): the questions Handle must
                    // never fumble, cold and at depth. Judged on "mentions
                    // Handle" + (privacy) a stays-local claim; full replies
                    // logged for a wording pass.
                    guard let self else { return }
                    let cases = ["who are you?", "who made you?",
                                 "do you send my data to the cloud?",
                                 "are you ChatGPT?", "what can you do?"]
                    for q in cases {
                        let convo = Conversation(chatWithApp: "")
                        convo.addUserMessage(q)
                        let reply = await self.streamOneTurn(in: convo, instr: "", display: false)
                        let lower = reply.lowercased()
                        let named = lower.contains("handle")
                        let privacyOK = !q.contains("cloud") || lower.contains("local") || lower.contains("never leave") || lower.contains("on your mac") || lower.contains("on this mac")
                        agentLog.info("identityeval [\(q, privacy: .public)] named=\(named) privacy=\(privacyOK) → \(reply.prefix(220), privacy: .public)")
                    }
                    // Depth: the same question after 8 unrelated exchanges.
                    let deep = Conversation(chatWithApp: "")
                    for i in 1...8 {
                        deep.addUserMessage("random filler question number \(i) about cooking pasta")
                        deep.commitAssistantMessage("Filler answer \(i): boil water, add salt, cook until al dente.")
                    }
                    deep.addUserMessage("who are you?")
                    let deepReply = await self.streamOneTurn(in: deep, instr: "", display: false)
                    agentLog.info("identityeval [DEPTH who are you?] named=\(deepReply.lowercased().contains("handle")) → \(deepReply.prefix(220), privacy: .public)")
                    agentLog.info("identityeval DONE")
                }
                else if cmd == "__shelltest__" {
                    // Shell tool: quick command, the BIG-OUTPUT case (>64KB used
                    // to deadlock the pipe and masquerade as a timeout), and the
                    // disabled refusal. Enabled flag saved/restored.
                    let wasEnabled = ShellTool.shared.isEnabled
                    ShellTool.shared.setEnabled(true)
                    do {
                        let cwd = try WorkspaceManager.shared.ensureWorkspaceExists()
                        let quick = try await ShellTool.shared.run(command: "echo hello && pwd", cwd: cwd)
                        agentLog.info("shelltest: quick exit=\(quick.exitCode) out=\"\(quick.output.prefix(60), privacy: .public)\" (want 0, hello + path)")
                        let big = try await ShellTool.shared.run(command: "seq 1 30000", cwd: cwd)
                        let completed = big.exitCode == 0 && big.output.contains("truncated")
                        agentLog.info("shelltest: big-output exit=\(big.exitCode) len=\(big.output.count) truncated=\(big.output.contains("truncated")) completedNotTimeout=\(completed) (want true)")
                    } catch {
                        agentLog.error("shelltest: FAILED — \(error.localizedDescription, privacy: .public)")
                    }
                    ShellTool.shared.setEnabled(false)
                    agentLog.info("shelltest: disabled tools visible=\(ShellTool.tools.count) (want 0)")
                    ShellTool.shared.setEnabled(wasEnabled)
                    agentLog.info("shelltest: DONE (enabled restored to \(wasEnabled))")
                }
                else if cmd == "__queuetest__" {
                    // Message queue e2e: start a turn, queue a second mid-run
                    // (what onSubmit does while isAgentRunning), and verify BOTH
                    // answers land in order via the loop-exit drain.
                    guard let self else { return }
                    let convo = Conversation(chatWithApp: "")
                    self.runSubmittedTurn(text: "what is 2+2? answer with just the number", in: convo)
                    try? await Task.sleep(for: .seconds(1))
                    convo.queuedTexts.append("what is 3+3? answer with just the number")
                    agentLog.info("queuetest: queued second message mid-turn")
                    for _ in 0..<60 {
                        try? await Task.sleep(for: .seconds(2))
                        let answers = convo.visibleMessages.filter { $0.role == .assistant && !$0.text.isEmpty }
                        if answers.count >= 2 {
                            agentLog.info("queuetest: DONE — answers in order: \"\(answers[0].text.prefix(40), privacy: .public)\" then \"\(answers[1].text.prefix(40), privacy: .public)\" queueLeft=\(convo.queuedTexts.count)")
                            return
                        }
                    }
                    agentLog.error("queuetest: TIMEOUT — second answer never arrived")
                }
                else if cmd == "__holdopttest__" {
                    // HOLD-⌥ GESTURE: drive the REAL HotkeyMonitor with synthetic
                    // CGEvents. ① hold 0.7s alone → mic begins on threshold, ends
                    // on release; ② ⌥+key chord → pending hold cancelled, no mic.
                    func postOption(down: Bool) {
                        let e = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: down)
                        e?.flags = down ? .maskAlternate : []
                        e?.post(tap: .cghidEventTap)
                    }
                    guard let self else { return }
                    postOption(down: true)
                    try? await Task.sleep(for: .milliseconds(650))
                    agentLog.info("holdopttest: ① mid-hold recording=\(self.isVoiceRecording) (want true)")
                    postOption(down: false)
                    try? await Task.sleep(for: .seconds(3))   // release path transcribes + sucks
                    agentLog.info("holdopttest: ① after release recording=\(self.isVoiceRecording) (want false)")
                    postOption(down: true)
                    try? await Task.sleep(for: .milliseconds(120))
                    let arrow = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true)
                    arrow?.flags = .maskAlternate
                    arrow?.post(tap: .cghidEventTap)
                    let arrowUp = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: false)
                    arrowUp?.flags = .maskAlternate
                    arrowUp?.post(tap: .cghidEventTap)
                    try? await Task.sleep(for: .milliseconds(700))
                    agentLog.info("holdopttest: ② chord recording=\(self.isVoiceRecording) (want false)")
                    postOption(down: false)
                    try? await Task.sleep(for: .milliseconds(300))
                    agentLog.info("holdopttest: DONE")
                }
                else if cmd == "__trigbatchtest__" {
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
                else if cmd == "__permstest__" { await self?.runPermsTest() }
                else if cmd.hasPrefix("__routinesave__ ") {
                    // ROUTINE SAVE FLOW: the real turn path (parseSchedule → no
                    // recipe → routine card, auto-approved) on a throwaway convo.
                    guard let self else { return }
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
                else if cmd == "__routineschedtest__" {
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
                else if cmd.hasPrefix("__routinetest__ ") {
                    // ROUTINE E2E: run an EPHEMERAL routine (not saved) through the
                    // real fire path right now — gather → synthesize → pill.
                    guard let self else { return }
                    let goal = String(cmd.dropFirst("__routinetest__ ".count))
                    let a = Automation(id: "routinetest", name: Automation.routineName(goal),
                                       recipeId: "", paramsJSON: "{}", schedule: nil, routineGoal: goal)
                    agentLog.info("routinetest: goal=\"\(goal, privacy: .public)\"")
                    await self.runAutomation(a)
                    agentLog.info("routinetest: DONE")
                }
                else if cmd == "__keychaintest__" {
                    // Keychain round-trip on a THROWAWAY item, then the full
                    // chain live: secret in Keychain → `keychain:` env reference
                    // → resolved at spawn → visible in the CHILD's environment
                    // (fake server's read_env tool). Cleaned up after.
                    let key = "mcp-selftest-token", secret = "s3cret-handle-selftest"
                    MCPKeychain.set(secret, for: key)
                    let roundtrip = MCPKeychain.get(key) == secret
                    agentLog.info("keychaintest: set+get roundtrip=\(roundtrip) (want true)")
                    do {
                        let script = Self.repoToolsDir + "/fake_mcp_server.py"
                        let h = try await MCPService.shared.connect(
                            name: "kctest", command: "/usr/bin/python3", args: [script],
                            env: ["FAKE_TOKEN": "keychain:\(key)", "PLAIN_VAR": "plain-value"])
                        let viaKeychain = try await MCPService.shared.callTool(
                            h, name: "read_env", textArguments: ["name": "FAKE_TOKEN"])
                        let plain = try await MCPService.shared.callTool(
                            h, name: "read_env", textArguments: ["name": "PLAIN_VAR"])
                        await MCPService.shared.disconnect(name: "kctest")
                        agentLog.info("keychaintest: child sees FAKE_TOKEN=\"\(viaKeychain, privacy: .public)\" (want \"\(secret, privacy: .public)\") PLAIN_VAR=\"\(plain, privacy: .public)\" (want \"plain-value\")")
                    } catch {
                        agentLog.error("keychaintest: FAILED — \(error.localizedDescription, privacy: .public)")
                    }
                    MCPKeychain.delete(key)
                    agentLog.info("keychaintest: after delete get=\(MCPKeychain.get(key) ?? "nil", privacy: .public) (want nil) DONE")
                }
                else if cmd.hasPrefix("__mcpconnect__") {
                    // Connect a configured server and LEAVE it running — for
                    // proving the quit path (terminateAllChildren) kills it.
                    let name = cmd.dropFirst("__mcpconnect__".count)
                        .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
                    do {
                        let h = try await MCPService.shared.connect(configuredName: name)
                        agentLog.info("mcpconnect: \(name, privacy: .public) up, pid=\(h.process.processIdentifier) — left connected")
                    } catch {
                        agentLog.error("mcpconnect: FAILED — \(error.localizedDescription, privacy: .public)")
                    }
                }
                else if cmd.hasPrefix("__mcptest__") {
                    // MCP harness. No arg / a script path = the transport spike
                    // (direct spawn → list → call → disconnect). "@name" = the
                    // config lifecycle: connect via mcp.json, call, then KILL the
                    // child and prove reconnect-on-crash with a second call.
                    let arg = cmd.dropFirst("__mcptest__".count).trimmingCharacters(in: .whitespaces)
                    do {
                        if arg.hasPrefix("@") {
                            let name = String(arg.dropFirst())
                            let h1 = try await MCPService.shared.connect(configuredName: name)
                            let tools = try await MCPService.shared.listTools(h1)
                            agentLog.info("mcptest[@\(name, privacy: .public)]: pid=\(h1.process.processIdentifier) \(tools.count) tool(s): \(MCPService.toolNames(tools).joined(separator: ", "), privacy: .public)")
                            let out1 = try await MCPService.shared.callTool(
                                h1, name: "echo", textArguments: ["text": "via config"])
                            agentLog.info("mcptest: call#1 → \"\(out1, privacy: .public)\" (want \"echo: via config\")")
                            // Crash it. terminationHandler must drop the handle;
                            // the next connect must spawn a FRESH pid and work.
                            kill(h1.process.processIdentifier, SIGKILL)
                            try? await Task.sleep(for: .milliseconds(300))
                            let h2 = try await MCPService.shared.connect(configuredName: name)
                            let out2 = try await MCPService.shared.callTool(
                                h2, name: "echo", textArguments: ["text": "after crash"])
                            let respawned = h2.process.processIdentifier != h1.process.processIdentifier
                            agentLog.info("mcptest: crash→reconnect pid \(h1.process.processIdentifier)→\(h2.process.processIdentifier) respawned=\(respawned) call#2 → \"\(out2, privacy: .public)\" (want \"echo: after crash\")")
                            await MCPService.shared.disconnect(name: name)
                            agentLog.info("mcptest: DONE")
                        } else {
                            let script = arg.isEmpty
                                ? Self.repoToolsDir + "/fake_mcp_server.py"
                                : arg
                            let handle = try await MCPService.shared.connect(
                                name: "mcptest", command: "/usr/bin/python3", args: [script])
                            let tools = try await MCPService.shared.listTools(handle)
                            agentLog.info("mcptest: \(tools.count) tool(s): \(MCPService.toolNames(tools).joined(separator: ", "), privacy: .public)")
                            let out = try await MCPService.shared.callTool(
                                handle, name: "echo", textArguments: ["text": "hello from handle"])
                            agentLog.info("mcptest: call → \"\(out, privacy: .public)\" (want \"echo: hello from handle\")")
                            await MCPService.shared.disconnect(name: "mcptest")
                            agentLog.info("mcptest: DONE")
                        }
                    } catch {
                        agentLog.error("mcptest: FAILED — \(error.localizedDescription, privacy: .public)")
                    }
                }
                else if cmd == "__memtest__" {
                    // Round-trip + relevance on a THROWAWAY db.
                    let store = MemoryStore(filename: "memory_selftest.db")
                    await store.wipe()
                    _ = await store.remember("Mary Chen's email is mary@acme.com")
                    _ = await store.remember("the user schedules meetings in 30-minute slots")
                    _ = await store.remember("Stripe receipts go to Business Expenses")
                    let hit = await store.relevant(to: "draft an email to Mary")
                    let miss = await store.relevant(to: "play some jazz")
                    let dedup = await store.remember("mary chen's EMAIL is mary@acme.com")
                    let all = await store.all()
                    let firstHit = (hit.first?.content.prefix(30)).map(String.init) ?? "-"
                    let dedupLabel = (dedup?.id == all.last?.id) ? "reused" : "new"
                    agentLog.info("memtest: hit=\(hit.count) first=\"\(firstHit, privacy: .public)\" miss=\(miss.count) (want ≥1/mary, 0) kept=\(all.count) (want 3) dedup=\(dedupLabel, privacy: .public)")
                    await store.wipe()
                    let wiped = await store.all()
                    agentLog.info("memtest: after wipe=\(wiped.count) (want 0)")
                }
                else if cmd == "__convstoretest__" {
                    // Round-trip against a THROWAWAY db file (never the real history).
                    let store = ConversationStore(filename: "conversations_selftest.db")
                    await store.deleteAll()
                    let convo = Conversation(chatWithApp: "Probe")
                    convo.addUserMessage("remember the milk")
                    convo.commitAssistantMessage("Noted.")
                    if let snap = convo.snapshot() {
                        await store.save(snap)
                        let listed = await store.list()
                        let loaded = await store.load(id: snap.id)
                        agentLog.info("convstoretest: list=\(listed.count) title=\"\(listed.first?.title ?? "-", privacy: .public)\" loadedMsgs=\(loaded?.messages.count ?? -1)")
                        convo.addUserMessage("and the eggs")
                        convo.commitAssistantMessage("Eggs too.")
                        if let snap2 = convo.snapshot() { await store.save(snap2) }
                        let relisted = await store.list()
                        let reloaded = await store.load(id: snap.id)
                        agentLog.info("convstoretest: upsert list=\(relisted.count) msgs=\(reloaded?.messages.count ?? -1) (want 1, 4)")
                        await store.delete(id: snap.id)
                        let afterDelete = await store.list()
                        agentLog.info("convstoretest: after delete list=\(afterDelete.count) (want 0)")
                        // Search + count (the history-reach feature): title hit,
                        // body hit, no-match, and literal-% escaping.
                        let sc1 = Conversation(chatWithApp: "Probe")
                        sc1.addUserMessage("plan the birthday party")
                        sc1.commitAssistantMessage("Cake, candles, and a guest list.")
                        let sc2 = Conversation(chatWithApp: "Probe")
                        sc2.addUserMessage("weekly budget review")
                        sc2.commitAssistantMessage("Spending is 12% under target.")
                        if let s1 = sc1.snapshot(), let s2 = sc2.snapshot() {
                            await store.save(s1); await store.save(s2)
                            let byTitle = await store.search("birthday")
                            let byBody = await store.search("guest list")
                            let noHit = await store.search("zebra")
                            let literalPct = await store.search("12%")
                            let total = await store.count()
                            agentLog.info("convstoretest: search title=\(byTitle.count) body=\(byBody.count) none=\(noHit.count) literal%=\(literalPct.count) count=\(total) (want 1,1,0,1,2)")
                        }
                        await store.deleteAll()
                    } else {
                        agentLog.info("convstoretest: ERROR — snapshot was nil")
                    }
                }
                else if cmd == "__shortcutstest__" {
                    // list via the real tool path; run only if a shortcut named
                    // "Handle Test" exists (create one by hand for the full round-trip).
                    do {
                        let names = try await ShortcutsTools.shared.listNames()
                        agentLog.info("shortcutstest: \(names.count) installed — \(names.prefix(10).joined(separator: " | "), privacy: .public)")
                        if names.contains("Handle Test") {
                            let out = try await ShortcutsTools.shared.run(name: "Handle Test")
                            agentLog.info("shortcutstest: run → \(out, privacy: .public)")
                        } else {
                            agentLog.info("shortcutstest: no “Handle Test” shortcut — run skipped")
                        }
                    } catch {
                        agentLog.info("shortcutstest: ERROR \(error.localizedDescription, privacy: .public)")
                    }
                }
                else if cmd == "__voicereltest__" {
                    // The REAL push-to-talk path, headless: begin (mic records silence),
                    // hold 3s, release — exercises the exact keyUp code incl. transcribe.
                    await self?.beginVoiceCapture()
                    try? await Task.sleep(for: .seconds(3))
                    await self?.endVoiceCaptureAndRun()
                }
                else if cmd == "__listentest__" {
                    // Play the listening pointer (birth → bars idle-shimmer → suck) card-less.
                    let screen = NotchController.shared.openPanelScreen() ?? PointingOverlay.currentScreen()
                    MetaballPointer.shared.listen(on: screen)
                    Task { @MainActor in try? await Task.sleep(for: .seconds(7)); MetaballPointer.shared.stopListening() }
                }
                else if cmd == "__grabscreen__" {
                    // Handle writes its OWN screen capture to /tmp (it holds Screen
                    // Recording; the shell tool doesn't) — for eyeballing the notch UI.
                    if let screen = NSScreen.main,
                       let img = try? await ScreenCapture.captureRegion(CGRect(origin: .zero, size: screen.frame.size), on: screen) {
                        let rep = NSBitmapImageRep(cgImage: img)
                        if let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath: "/tmp/handle_grab.png"))
                            agentLog.info("grabscreen: wrote /tmp/handle_grab.png")
                        }
                    }
                }
                else if cmd.hasPrefix("__clicktest__ ") { await self?.runPointingHarness(query: String(cmd.dropFirst(14)), click: true) }
                else if cmd.hasPrefix("__voicefile__ ") {
                    let t = await SpeechService.shared.transcribe(fileURL: URL(fileURLWithPath: String(cmd.dropFirst(14))))
                    agentLog.info("voicefile: transcript=\"\(t, privacy: .public)\"")
                }
                else if cmd.hasPrefix("__voicecmd__ ") {
                    // Drive the transcript→capture→loop path with given text (no mic).
                    await self?.handleVoiceCommand(transcript: String(cmd.dropFirst(13)))
                }
                else if cmd.hasPrefix("__trigparse__ ") {
                    let goal = String(cmd.dropFirst(14))
                    let hit = self?.hasEventTriggerHint(goal) ?? false
                    if let (t, task) = await self?.parseEventTrigger(goal) {
                        agentLog.info("trigparse: hint=\(hit) trigger=\"\(t.describe, privacy: .public)\" task=\"\(task, privacy: .public)\"")
                    } else {
                        agentLog.info("trigparse: hint=\(hit) → nil (not an event-trigger request)")
                    }
                }
                else { await self?.runPointingHarness(query: cmd) }
            }
        }
        agentLog.info("test harness: watching \(Self.testCmdPath, privacy: .public)")
    }

    /// PLANNING PROBE (`__plan__ <goal>`): can a small local model decompose a multi-step
    /// automation into a sane ordered plan of tool calls? Text-only, NO execution —
    /// just logs the plan for eyeballing. Decides freeform-plan vs recipe-first.
    func runPlanProbe(goal: String) async {
        let tools = ToolRegistry.promptSpec(for: ToolRegistry.all)
        let prompt = """
        You are Handle, an assistant that automates a Mac using ONLY these tools:
        \(tools)

        The user's goal: "\(goal)"

        Produce a NUMBERED PLAN of the exact tool calls to achieve it, in order. For each
        step give: the tool name, its key arguments, and a short reason. If a step needs a
        previous step's result, say so. Use ONLY the tools listed. Do NOT execute — output
        only the plan.
        """
        agentLog.info("planprobe: goal=\"\(goal, privacy: .public)\"")
        var plan = ""
        do {
            for try await delta in CloudEngine.shared.chat(messages: [.user(prompt)], label: "plan probe") {
                plan += delta
            }
        } catch {
            agentLog.error("planprobe error: \(error.localizedDescription, privacy: .public)"); return
        }
        agentLog.info("planprobe PLAN for \"\(goal, privacy: .public)\":\n\(plan, privacy: .public)")
    }

    /// RECIPE PROBE (`__recipe__ <goal>`): match → fill → resolve, logging each stage
    /// (no execution) to validate retrieve+fill on the real model.
    func runRecipeProbe(goal: String) async {
        agentLog.info("recipe: goal=\"\(goal, privacy: .public)\"")
        guard let recipe = await matchRecipe(goal: goal) else {
            agentLog.info("recipe: NO MATCH — would decline"); return
        }
        agentLog.info("recipe: matched → \(recipe.id, privacy: .public) (\(recipe.title, privacy: .public))")
        let params = await fillParams(recipe: recipe, goal: goal)
        agentLog.info("recipe: params=\(String(describing: params), privacy: .public)")
        let card = recipe.resolve(recipe.confirmTemplate, with: params)
        let script = recipe.resolve(recipe.body, with: params)
        agentLog.info("recipe: CARD=\"\(card, privacy: .public)\"\nrecipe: RESOLVED SCRIPT:\n\(script, privacy: .public)")
    }

    /// PERMISSIONS TEST (`__permstest__`): log every TCC status non-interactively
    /// (Automation checked against Finder + System Events, no dialogs).
    func runPermsTest() async {
        agentLog.info("perms: accessibility=\(PermissionsService.accessibility().label, privacy: .public)")
        agentLog.info("perms: screenRecording=\(PermissionsService.screenRecording().label, privacy: .public)")
        agentLog.info("perms: calendars=\(PermissionsService.calendars().label, privacy: .public)")
        agentLog.info("perms: reminders=\(PermissionsService.reminders().label, privacy: .public)")
        agentLog.info("perms: location=\(PermissionsService.location().label, privacy: .public)")
        let n = await PermissionsService.notifications()
        agentLog.info("perms: notifications=\(n.label, privacy: .public)")
        for app in ["Finder", "System Events"] {
            agentLog.info("perms: automation(\(app, privacy: .public))=\(PermissionsService.automationStatus(for: app).label, privacy: .public)")
        }
        agentLog.info("perms: DONE")
    }

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

    /// Run the full pointing pipeline against the frontmost app for `query`, no GUI
    /// needed — capture, enumerate AX, See turn with the pointing instruction; the
    /// dispatch logs the selected element + live frame (and draws the highlight).
    func runPointingHarness(query: String, click: Bool = false) async {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else { return }
        let rect = CGRect(origin: .zero, size: screen.frame.size)
        guard let raw = try? await ScreenCapture.captureRegion(rect, on: screen) else {
            agentLog.error("harness: capture failed"); return
        }
        let prepared = ImagePreparation.prepareForAPI(raw)
        let axElements = AccessibilityProbe.elements(in: rect, of: bundleID, limit: 25)
        agentLog.info("harness: query=\"\(query, privacy: .public)\" app=\(bundleID ?? "?", privacy: .public) ax=\(axElements.count)")
        for (i, e) in axElements.enumerated() {
            agentLog.info("AX candidate [\(i)] \(e.role, privacy: .public) \"\(e.label, privacy: .public)\" (\(Int(e.frame.minX)),\(Int(e.frame.minY)),\(Int(e.frame.width))×\(Int(e.frame.height)))")
        }
        let convo = Conversation(chatWithApp: app?.localizedName ?? "")
        convo.updateCurrentCapture(rect: rect, screen: screen, imagePixelSize: prepared.pixelSize, axElements: axElements)
        convo.addUserMessage(query, image: prepared.image, imagePixelSize: prepared.pixelSize)
        if click {
            // __clicktest__: run the click pipeline card-less (DEBUG auto-approve) so
            // select → press is verifiable headlessly.
            let finalText = await streamOneTurn(in: convo, instr: pointAtToolInstruction(elements: axElements), display: false)
            if !(await dispatchClickIfPresent(finalText, conversation: convo, autoApprove: true)) {
                agentLog.info("click: NOT HANDLED — nothing selected")
            }
            return
        }
        await runToolLoop(in: convo, isInitial: false, action: convo.initialAction)
    }

    /// Render the Settings page and the onboarding connect step offscreen to
    /// /tmp/handle_settings.png and /tmp/handle_connect.png — visual verification
    /// of notch pages without driving the notch by hand.
    func renderUIShots() {
        // NSHostingView in an offscreen window + cacheDisplay: unlike ImageRenderer
        // this draws AppKit-backed SwiftUI (Form/List) and honours the dark appearance.
        func save(_ view: some View, width: CGFloat, height: CGFloat, to path: String) {
            let host = NSHostingView(rootView: view.frame(width: width, height: height).background(Color.black))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))   // never on a screen
            window.orderFrontRegardless()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.8))          // let List/Form lay out
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                defer { window.orderOut(nil) }
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    agentLog.error("uishot: no bitmap rep for \(path, privacy: .public)"); return
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    agentLog.error("uishot: png failed for \(path, privacy: .public)"); return
                }
                try? png.write(to: URL(fileURLWithPath: path))
                agentLog.info("uishot: wrote \(path, privacy: .public) \(Int(width))×\(Int(height))")
            }
        }
        save(SettingsBody(), width: 560, height: 1500, to: "/tmp/handle_settings.png")
        save(SettingsCustomizePreview(), width: 560, height: 1500, to: "/tmp/handle_customize.png")
        save(ConnectStep(onContinue: {}).padding(24), width: 560, height: 440, to: "/tmp/handle_connect.png")

        // README shots: the real conversation view with SAMPLE content (nothing from this Mac).
        let chat = Conversation(chatWithApp: "")
        chat.addUserMessage("What's on my calendar tomorrow?")
        chat.addToolChip(name: "read_calendar_events", inputJSON: #"{"start_iso":"2026-10-06T00:00","end_iso":"2026-10-06T23:59"}"#,
                         content: "3 events", isError: false, displaySummary: "3 event(s)")
        chat.commitAssistantMessage("You have three things tomorrow:\n\n- **09:30** Design review, 45 minutes\n- **13:00** Lunch with Sam\n- **16:00** Dentist\n\nThe morning is free until the review.")
        let card = Conversation(chatWithApp: "")
        card.addUserMessage("Remind me to call the dentist tomorrow at 10")
        card.pendingConfirmation = ConfirmationRequest(
            title: "Create reminder?",
            detailRows: [(label: "Title", value: "Call the dentist"), (label: "Due", value: "Tomorrow, 10:00")],
            confirmLabel: "Approve", cancelLabel: "Cancel", isDestructive: false, onDecision: { _ in })
        for (convo, path) in [(chat, "/tmp/handle_chat.png"), (card, "/tmp/handle_card.png")] {
            save(ConversationContent(conversation: convo, onSubmit: { _ in }, onAddPDF: {}, onClose: {}, onStop: {}).padding(18),
                 width: 600, height: 460, to: path)
        }
    }

    /// DEBUG: drive the "working" comet for 8s WITHOUT a model turn, so its
    /// main-thread cost can be sampled in isolation — validates the Canvas rewrite
    /// of BorderComet without a model in the picture. Fire `__comet__`, then `sample $(pgrep -x Handle) 3` during the window.
    func runCometProbe() async {
        agentLog.info("comet probe: ON for 8s (no model) — sample the process now")
        NotchController.shared.setWorking(true)
        try? await Task.sleep(for: .seconds(8))
        NotchController.shared.setWorking(false)
        agentLog.info("comet probe: OFF")
    }

    /// DEBUG: drive one metaball highlight (birth → morph → retract) with NO model,
    /// so the pointer animation's per-frame cost can be sampled — same TimelineView
    /// bug class as the comet; the metaball is the product centerpiece.
    func runHighlightProbe() {
        let screen = PointingOverlay.currentScreen()
        let r = CGRect(x: screen.frame.midX - 60, y: screen.frame.midY - 24, width: 120, height: 48)
        agentLog.info("highlight probe: driving a sample highlight — sample the process now")
        MetaballPointer.shared.guide(steps: [GuideStep(rect: r, message: "Sample highlight")], on: screen)
    }

    /// DEBUG: dump the frontmost app's RAW AX tree (no filter) to the log — to see
    /// what Electron/Chromium apps actually expose under AXManualAccessibility.
    func runAXTreeDump() {
        let front = NSWorkspace.shared.frontmostApplication
        let lines = AccessibilityProbe.rawTree(of: front?.bundleIdentifier)
        agentLog.info("AX raw tree — \(front?.localizedName ?? "?", privacy: .public) [\(front?.bundleIdentifier ?? "?", privacy: .public)] — \(lines.count) nodes:")
        for l in lines { agentLog.info("  \(l, privacy: .public)") }
    }
}

#endif
