import SwiftUI
import AppKit
import EventKit
import UniformTypeIdentifiers
import UserNotifications
import KeyboardShortcuts
import OSLog

let agentLog = Logger(subsystem: "com.dimarussu.Handle", category: "Agent")

@main
struct HandleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Handle has no conventional windows — its whole UI lives in the notch
        // (Settings and About are pages there). This empty scene only satisfies
        // App's scene requirement for an accessory app. TextEditingCommands
        // puts an Edit menu in the (invisible) menu bar — without one, ⌘V/⌘C/
        // ⌘X/⌘A never reach ANY text field (SwiftUI's default accessory menu
        // is App/View/Window/Help, no Edit; found pasting a connector).
        Settings { EmptyView() }
            .commands { TextEditingCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    var hotkeyMonitor: HotkeyMonitor?
    var editKeyMonitor: Any?
    var isPresentingOverlay = false
    /// The most recently started conversation. Stays alive after the user
    /// dismisses the notch panel; replaced when a new capture starts.
    var activeConversation: Conversation?
    /// The task currently driving runTurn for the active conversation. Cancelled
    /// when a new capture starts.
    var activeTask: Task<Void, Never>?
    /// True while runTurn is in flight.
    var isAgentRunning = false
    var isVoiceRecording = false
    /// Automations currently executing (re-entrancy guard for run_automation).
    var runningAutomationIDs: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard. If another Handle is already running (e.g.
        // Spotlight + Finder both launched, or a stale dev binary still
        // alive), terminate this one. Two instances cause two menubar
        // icons, two global-hotkey registrations, and silently route the
        // user's typed message to the wrong conversation — exactly the
        // symptoms that prompted this bug report.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundle = Bundle.main.bundleIdentifier
        let runningSiblings = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == myBundle && $0.processIdentifier != myPID
        }
        if !runningSiblings.isEmpty {
            // Bring the existing instance to the front, then quit.
            runningSiblings.first?.activate()
            NSApp.terminate(nil)
            return
        }

        // DESIGN.md: Handle is always a solid-black, white-only surface, so
        // force the whole app dark before any UI is built — the menu, status
        // bar, system pickers, and every window render dark from the first
        // frame. (The user-facing appearance picker was removed alongside this.)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        installEditMenu()
        setupHotkey()
        setupAccessibilityPriming()
        startScheduler()     // fire due saved automations (time triggers)
        startTriggerEngine() // fire saved automations on local events (file triggers)
        #if DEBUG
        startTestHarness()   // file-watch trigger for the build/test loop
        #endif

        // Handle's primary surface: the notch. Install it at launch so the
        // closed pill is resident from the first frame.
        NotchController.shared.install()

        // Chats page → reopen a saved conversation (text-only, continuable).
        NotchController.shared.onOpenSaved = { [weak self] id in
            Task { @MainActor in await self?.openSavedConversation(id: id) }
        }
        // New chat → swap in a fresh blank conversation, opened + ready to type.
        NotchController.shared.onNewChat = { [weak self] in self?.startNewChat() }
        // Stop → cancel the running turn (the send button becomes Stop while working).
        NotchController.shared.onStop = { [weak self] in self?.stopGeneration() }
        NotchController.shared.onRunAutomation = { [weak self] a in Task { @MainActor in await self?.runAutomation(a) } }

        // Pre-wire a fresh text-only "Ask" conversation (no capture) so the
        // input bar is ready the instant the user opens the notch — chat is
        // the connective tissue between See and Do (PRODUCT.md).
        let chat = Conversation(chatWithApp: "")
        activeConversation = chat
        presentConversation(chat, andOpen: false)

        // First run: open the panel on the onboarding walk-through (hardware
        // check → staged permissions → model disclosure). Repeats each launch
        // until completed.
        if !Onboarding.isDone {
            NotchController.shared.showOnboarding()
            agentLog.info("onboarding: first run — walk-through shown (panel open: \(NotchController.shared.isPanelOpen))")
        }

        print("[Handle] Ready. Hover the notch, or double-tap ⌥ to capture.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // No async runway at quit — synchronously SIGTERM every MCP child so
        // no orphan servers outlive Handle.
        MCPService.shared.terminateAllChildren()
    }

    // System (UNUserNotification) notifications REMOVED :
    // every completion signal goes through Handle's own notification center — the
    // pill + result cards under the notch. One interface, no duplicate banners,
    // and no Notifications permission needed.

    /// Accessory (LSUIElement) apps never show a menu bar — and SwiftUI's
    /// default main menu for one has NO Edit menu (App/View/Window/Help), so
    /// ⌘V/⌘C/⌘X/⌘A/⌘Z never reach any text field: typing works, pasting
    /// silently doesn't (found in the connector paste box; the chat
    /// input had the same latent bug). Two fixes, belt and braces:
    /// 1. Insert an Edit menu AFTER SwiftUI installs its menu (it replaces
    ///    whatever exists at launch — verified by menu dump).
    /// 2. A local key monitor that routes the equivalents straight to the
    ///    focused responder — menu routing can be bypassed while a
    ///    nonactivating panel has key without the app being active.
    func installEditMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let main = NSApp.mainMenu,
                  !main.items.contains(where: { $0.submenu?.title == "Edit" }) else { return }
            let edit = NSMenu(title: "Edit")
            edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
            edit.addItem(.separator())
            edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            let editItem = NSMenuItem()
            editItem.submenu = edit
            main.insertItem(editItem, at: min(1, main.items.count))
        }

        editKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            let action: Selector?
            switch event.charactersIgnoringModifiers {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            default:  action = nil
            }
            guard let action, NSApp.sendAction(action, to: nil, from: nil) else { return event }
            return nil   // handled — don't let it double-dispatch
        }
    }

    func setupHotkey() {
        // ⌥ is the Handle key ("simpler than a chord"):
        // double-tap → full-screen capture; HOLD ⌥ alone → talk, release to run.
        let monitor = HotkeyMonitor(
            onDoubleTap: { [weak self] in self?.handleCapture() },
            onHoldBegan: { [weak self] in Task { @MainActor in await self?.beginVoiceCapture() } },
            onHoldEnded: { [weak self] in Task { @MainActor in await self?.endVoiceCaptureAndRun() } })
        monitor.start()
        hotkeyMonitor = monitor

        // Optional rebindable chord for full-screen
        KeyboardShortcuts.onKeyDown(for: .triggerCapture) { [weak self] in
            self?.handleCapture()
        }
    }
}
