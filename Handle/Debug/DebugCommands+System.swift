import SwiftUI
import AppKit
import OSLog

// Debug commands for the system-facing parts: consent, shell, hotkey, Keychain, connectors, stores, voice.

#if DEBUG

extension AppDelegate {
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

    /// `__seetest__`
    func debugCheckScreenConsent(_ cmd: String) async {
        // Exclusion, live: put the FRONTMOST app on the list, try an
        // ambient See turn, expect no capture + the withheld caption +
        // a text-only cloud request; then restore the list.
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

    /// `__shelltest__`
    func debugCheckShellTool(_ cmd: String) async {
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

    /// `__holdopttest__`
    func debugCheckHoldOption(_ cmd: String) async {
        // HOLD-⌥ GESTURE: drive the REAL HotkeyMonitor with synthetic
        // CGEvents. ① hold 0.7s alone → mic begins on threshold, ends
        // on release; ② ⌥+key chord → pending hold cancelled, no mic.
        func postOption(down: Bool) {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: down)
            e?.flags = down ? .maskAlternate : []
            e?.post(tap: .cghidEventTap)
        }
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

    /// `__keychaintest__`
    func debugCheckKeychain(_ cmd: String) async {
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

    /// `__mcpconnect__`
    func debugConnectServer(_ cmd: String) async {
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

    /// `__mcptest__`
    func debugCheckConnectorTransport(_ cmd: String) async {
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

    /// `__memtest__`
    func debugCheckMemoryStore(_ cmd: String) async {
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

    /// `__convstoretest__`
    func debugCheckConversationStore(_ cmd: String) async {
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

    /// `__shortcutstest__`
    func debugCheckShortcuts(_ cmd: String) async {
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

    /// `__voicereltest__`
    func debugCheckVoiceRelease(_ cmd: String) async {
        // The REAL push-to-talk path, headless: begin (mic records silence),
        // hold 3s, release — exercises the exact keyUp code incl. transcribe.
        await self.beginVoiceCapture()
        try? await Task.sleep(for: .seconds(3))
        await self.endVoiceCaptureAndRun()
    }

    /// `__listentest__`
    func debugCheckListening(_ cmd: String) async {
        // Play the listening pointer (birth → bars idle-shimmer → suck) card-less.
        let screen = NotchController.shared.openPanelScreen() ?? PointingOverlay.currentScreen()
        MetaballPointer.shared.listen(on: screen)
        Task { @MainActor in try? await Task.sleep(for: .seconds(7)); MetaballPointer.shared.stopListening() }
    }

    /// `__grabscreen__`
    func debugGrabScreen(_ cmd: String) async {
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

    /// `__voicefile__`
    func debugTranscribeFile(_ cmd: String) async {
        let t = await SpeechService.shared.transcribe(fileURL: URL(fileURLWithPath: String(cmd.dropFirst(14))))
        agentLog.info("voicefile: transcript=\"\(t, privacy: .public)\"")
    }
}

#endif
