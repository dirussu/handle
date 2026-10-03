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
                else if cmd.hasPrefix("__websearch__ ") { await self?.debugSetWebSearch(cmd) }
                else if cmd.hasPrefix("__autoapprove__") { Self.debugAutoApprove = cmd.hasSuffix("on"); agentLog.info("harness: autoapprove=\(Self.debugAutoApprove)") }
                else if cmd == "__seetest__" { await self?.debugCheckScreenConsent(cmd) }
                else if cmd == "__comet__" { await self?.runCometProbe() }
                else if cmd == "__highlight__" { self?.runHighlightProbe() }
                else if cmd == "__axtree__" { self?.runAXTreeDump() }
                else if cmd.hasPrefix("__recipe__ ") { await self?.runRecipeProbe(goal: String(cmd.dropFirst(11))) }
                else if cmd == "__schedtest__" { self?.runSchedTest() }
                else if cmd == "__trigtest__" { self?.runTrigTest() }
                else if cmd == "__trigapptest__" { self?.runTrigAppTest() }
                else if cmd.hasPrefix("__chatprobe__ ") { await self?.debugProbeChat(cmd) }
                else if cmd == "__identityeval__" { await self?.debugEvaluateIdentity(cmd) }
                else if cmd == "__shelltest__" { await self?.debugCheckShellTool(cmd) }
                else if cmd == "__queuetest__" { await self?.debugCheckMessageQueue(cmd) }
                else if cmd == "__holdopttest__" { await self?.debugCheckHoldOption(cmd) }
                else if cmd == "__trigbatchtest__" { await self?.debugCheckTriggerBatch(cmd) }
                else if cmd == "__permstest__" { await self?.runPermsTest() }
                else if cmd.hasPrefix("__routinesave__ ") { await self?.debugCheckRoutineSave(cmd) }
                else if cmd == "__routineschedtest__" { await self?.debugCheckRoutineSchedule(cmd) }
                else if cmd.hasPrefix("__routinetest__ ") { await self?.debugRunRoutineOnce(cmd) }
                else if cmd == "__keychaintest__" { await self?.debugCheckKeychain(cmd) }
                else if cmd.hasPrefix("__mcpconnect__") { await self?.debugConnectServer(cmd) }
                else if cmd.hasPrefix("__mcptest__") { await self?.debugCheckConnectorTransport(cmd) }
                else if cmd == "__memtest__" { await self?.debugCheckMemoryStore(cmd) }
                else if cmd == "__convstoretest__" { await self?.debugCheckConversationStore(cmd) }
                else if cmd == "__shortcutstest__" { await self?.debugCheckShortcuts(cmd) }
                else if cmd == "__voicereltest__" { await self?.debugCheckVoiceRelease(cmd) }
                else if cmd == "__listentest__" { await self?.debugCheckListening(cmd) }
                else if cmd == "__grabscreen__" { await self?.debugGrabScreen(cmd) }
                else if cmd.hasPrefix("__clicktest__ ") { await self?.runPointingHarness(query: String(cmd.dropFirst(14)), click: true) }
                else if cmd.hasPrefix("__voicefile__ ") { await self?.debugTranscribeFile(cmd) }
                else if cmd.hasPrefix("__voicecmd__ ") { await self?.debugRunTurn(cmd) }
                else if cmd.hasPrefix("__trigparse__ ") { await self?.debugCheckTriggerParsing(cmd) }
                else { await self?.runPointingHarness(query: cmd) }
            }
        }
        agentLog.info("test harness: watching \(Self.testCmdPath, privacy: .public)")
    }
}

#endif
