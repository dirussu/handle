import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import KeyboardShortcuts
import OSLog

private let agentLog = Logger(subsystem: "com.dimarussu.Akari", category: "Agent")

@main
struct AkariApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Akari has no conventional windows — its whole UI lives in the notch
        // (Settings and About are pages there). This empty scene only satisfies
        // App's scene requirement for an accessory app.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var hotkeyMonitor: HotkeyMonitor?
    private var isPresentingOverlay = false

    /// The most recently started conversation. Stays alive after the user
    /// dismisses the notch panel; replaced when a new capture starts.
    private var activeConversation: Conversation?
    /// The task currently driving runTurn for the active conversation. Cancelled
    /// when a new capture starts.
    private var activeTask: Task<Void, Never>?
    /// True while runTurn is in flight.
    private var isAgentRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard. If another Akari is already running (e.g.
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

        // DESIGN.md: Akari is always a solid-black, white-only surface, so
        // force the whole app dark before any UI is built — the menu, status
        // bar, system pickers, and every window render dark from the first
        // frame. (The user-facing appearance picker was removed alongside this.)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        setupHotkey()
        setupAccessibilityPriming()
        startScheduler()     // fire due saved automations (time triggers)
        startTriggerEngine() // fire saved automations on local events (file triggers)
        #if DEBUG
        startTestHarness()   // file-watch trigger for the autonomous build/test loop
        #endif

        // Akari's primary surface: the notch. Install it at launch so the
        // closed pill is resident from the first frame.
        NotchController.shared.install()

        // History page → reopen a saved conversation (text-only, continuable).
        NotchController.shared.onOpenSaved = { [weak self] id in
            Task { @MainActor in await self?.openSavedConversation(id: id) }
        }

        // Pre-wire a fresh text-only "Ask" conversation (no capture) so the
        // input bar is ready the instant the user opens the notch — chat is
        // the connective tissue between See and Do (PRODUCT.md).
        let chat = Conversation(chatWithApp: "")
        activeConversation = chat
        presentConversation(chat, andOpen: false)

        UNUserNotificationCenter.current().delegate = self
        Task { await NotificationsService.shared.requestAuthorization() }

        // First run: open the panel on the onboarding walk-through (hardware
        // check → staged permissions → model disclosure). Repeats each launch
        // until completed.
        if !Onboarding.isDone {
            NotchController.shared.showOnboarding()
            agentLog.info("onboarding: first run — walk-through shown (panel open: \(NotchController.shared.isPanelOpen))")
        }

        print("[Akari] Ready. Hover the notch, or double-tap ⌥ to capture.")
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner + sound even when our app is foreground.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            // Tapping the "task complete" notification opens the notch on the
            // active conversation.
            if let conversation = self.activeConversation {
                self.presentConversation(conversation)
            }
            completionHandler()
        }
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        // Default: double-tap ⌥ → full-screen capture
        let monitor = HotkeyMonitor { [weak self] in
            self?.handleCapture(mode: .fullScreen)
        }
        monitor.start()
        hotkeyMonitor = monitor

        // Optional rebindable chord for full-screen
        KeyboardShortcuts.onKeyDown(for: .triggerCapture) { [weak self] in
            self?.handleCapture(mode: .fullScreen)
        }

        // Rebindable chord for region capture
        KeyboardShortcuts.onKeyDown(for: .captureRegion) { [weak self] in
            self?.handleCapture(mode: .region)
        }

        // TEMP — demo the metaball pointer spit-out (⌘⌥P). Remove when the
        // pointer is wired to visual mode / point_at.
        KeyboardShortcuts.setShortcut(.init(.p, modifiers: [.command, .option]), for: .demoMetaball)
        KeyboardShortcuts.onKeyDown(for: .demoMetaball) { [weak self] in
            self?.runHighlightTest()
        }

        // Push-to-talk: HOLD the shortcut to record, release to transcribe + run.
        // Default ⌃⌥Space if unset; rebindable in Settings.
        if KeyboardShortcuts.getShortcut(for: .pushToTalk) == nil {
            KeyboardShortcuts.setShortcut(.init(.space, modifiers: [.control, .option]), for: .pushToTalk)
        }
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            Task { @MainActor in await self?.beginVoiceCapture() }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            Task { @MainActor in await self?.endVoiceCaptureAndRun() }
        }
    }

    // MARK: - Voice (push-to-talk)

    private var isVoiceRecording = false

    /// Key-down: start on-device recording (WhisperKit). First use prompts for Mic.
    private func beginVoiceCapture() async {
        guard !isVoiceRecording, !isPresentingOverlay else { return }
        isVoiceRecording = true
        // The pointer's own birth animation, settling into the dictation bars
        // instead of the glow ring. Sucks back in when the key is released.
        let screen = NotchController.shared.openPanelScreen() ?? PointingOverlay.currentScreen()
        MetaballPointer.shared.listen(on: screen)
        await SpeechService.shared.startRecording()
    }

    /// Key-up: stop, transcribe, and run the spoken command like a typed one.
    /// The release cue IS the pointer's reverse suck — the notch swallows the blob
    /// (brand identity). Transcription runs DURING the suck; the panel waits for the
    /// collapse to finish so it never opens over the animation and hides it.
    private func endVoiceCaptureAndRun() async {
        guard isVoiceRecording else { return }
        isVoiceRecording = false
        MetaballPointer.shared.stopListening()               // suck starts (~1.05s + fade)
        let suckBeat = Task { try? await Task.sleep(for: .seconds(1.15)) }
        let transcript = await SpeechService.shared.stopRecordingAndTranscribe()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await suckBeat.value                             // let the collapse land
        guard !text.isEmpty else { NSSound.beep(); return }
        await handleVoiceCommand(transcript: text)
    }

    /// A spoken command IS a screen-aware command: capture what the user is looking at,
    /// stage the transcript as the user message, and run the SAME loop as a typed turn
    /// (isInitial:false → click/point/recipe/act routing all apply). Then, if enabled,
    /// speak the reply. Mirrors the capture + runToolLoop setup used everywhere else.
    @MainActor
    private func handleVoiceCommand(transcript: String) async {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "(unknown)"
        let bundleID = frontApp?.bundleIdentifier
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main
        let rect = screen.map { CGRect(origin: .zero, size: $0.frame.size) } ?? .zero

        var image: CGImage? = nil
        var pixelSize: CGSize = .zero
        var axElements: [AXElement] = []
        if let screen, let raw = try? await ScreenCapture.captureRegion(rect, on: screen) {
            let prepared = ImagePreparation.prepareForAPI(raw)
            image = prepared.image; pixelSize = prepared.pixelSize
            axElements = AccessibilityProbe.elements(in: rect, of: bundleID, limit: 25)
        }
        let convo = Conversation(chatWithApp: appName)
        convo.updateCurrentCapture(rect: rect, screen: screen, imagePixelSize: pixelSize, axElements: axElements)
        convo.addUserMessage(transcript, image: image, imagePixelSize: image != nil ? pixelSize : nil)
        activeConversation = convo
        presentConversation(convo)
        agentLog.info("voice: command=\"\(transcript, privacy: .public)\" app=\(bundleID ?? "?", privacy: .public) ax=\(axElements.count)")
        await runToolLoop(in: convo, isInitial: false, action: convo.initialAction)
        if VoiceSettings.speakReplies,
           let reply = convo.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text {
            SpeechSynth.shared.speak(reply)
        }
    }

    /// Force-enable accessibility on each app as it comes to the foreground, so
    /// Chromium/Electron apps have their a11y tree BUILT before we ever capture or
    /// hit-test them — no warm-up. Native apps ignore it. Also primes whatever's
    /// frontmost right now.
    private func setupAccessibilityPriming() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                AccessibilityProbe.primeChromiumAccessibility(pid: app.processIdentifier)
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            AccessibilityProbe.primeChromiumAccessibility(pid: front.processIdentifier)
        }
    }

    /// TEMP — demonstrate the "vision points, AX pins" precision primitive. ⌘⌥P
    /// hit-tests the element directly under the cursor (in ANY app) and snaps an
    /// exact outline to it. This stands in for the model's rough point; if it lands
    /// tight across apps, AX hit-testing is the precision spine. Nothing accessible
    /// under the cursor → scripted demo.
    private func runHighlightTest() {
        let screen = PointingOverlay.currentScreen()
        let mouse = NSEvent.mouseLocation                       // global, bottom-left
        if let el = AccessibilityProbe.elementUnderCursor() {
            agentLog.info("⌘⌥P isolation: mouse(global BL)=(\(Int(mouse.x)),\(Int(mouse.y))) screen.frame=(\(Int(screen.frame.minX)),\(Int(screen.frame.minY)),\(Int(screen.frame.width))×\(Int(screen.frame.height))) → \(el.role, privacy: .public) \"\(el.label, privacy: .public)\" frame(\(Int(el.frame.minX)),\(Int(el.frame.minY)),\(Int(el.frame.width))×\(Int(el.frame.height)))")
            let short = el.role.replacingOccurrences(of: "AX", with: "")
            let msg = el.label.isEmpty ? short : "\(short): \(el.label)"
            MetaballPointer.shared.guide(steps: [GuideStep(rect: el.frame, message: msg)], on: screen)
        } else {
            MetaballPointer.shared.demo()
        }
    }

    enum CaptureMode { case fullScreen, region }

    @objc private func triggerCaptureFullScreen() {
        handleCapture(mode: .fullScreen)
    }

    @objc private func triggerCaptureRegion() {
        handleCapture(mode: .region)
    }

    private func handleCapture(mode: CaptureMode) {
        guard !isPresentingOverlay else { return }
        isPresentingOverlay = true

        // Cancel any in-flight conversation when a new capture starts.
        activeTask?.cancel()
        activeTask = nil

        let task = Task { @MainActor in
            defer { isPresentingOverlay = false }

            // Snapshot frontmost app BEFORE overlay shows (overlay temporarily activates Akari).
            let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "(unknown)"
            let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            print("[Akari] Frontmost app: \(frontmostApp) (\(frontmostBundleID ?? "?"))")

            // No privacy exclude-list: Akari is local and captures are
            // ephemeral (never written to disk, never sent off-device), so
            // there's nothing to protect against by refusing to look.

            // Pick the screen under the cursor.
            let cursor = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else {
                print("[Akari] No screen for cursor at \(cursor)")
                return
            }

            // 1. Determine the capture rect — either from a drag-select overlay
            //    or the full screen, depending on mode.
            let captureRect: CGRect
            switch mode {
            case .fullScreen:
                captureRect = CGRect(origin: .zero, size: screen.frame.size)
                print("[Akari] Mode: fullScreen — \(Int(captureRect.width))×\(Int(captureRect.height)) pt")
            case .region:
                let overlay = SelectionOverlay()
                guard let dragged = await overlay.present(on: screen) else {
                    print("[Akari] Selection cancelled.")
                    return
                }
                captureRect = dragged
                print("[Akari] Mode: region — \(captureRect)")
            }

            // 2. Capture pixels, then downsample for the API.
            let rawImage: CGImage
            do {
                rawImage = try await ScreenCapture.captureRegion(captureRect, on: screen)
                print("[Akari] Captured \(rawImage.width)×\(rawImage.height)px (raw)")
            } catch {
                print("[Akari] Capture failed: \(error)")
                return
            }
            let prepared = ImagePreparation.prepareForAPI(rawImage)
            let image = prepared.image
            let imagePixelSize = prepared.pixelSize
            print("[Akari] Prepared for API: \(Int(imagePixelSize.width))×\(Int(imagePixelSize.height))px")

            // 3a. Probe AX tree for ground-truth element coordinates (synchronous, fast).
            let axElements = AccessibilityProbe.elements(
                in: captureRect,
                of: frontmostBundleID,
                limit: 25
            )
            print("[Akari] AX elements found: \(axElements.count)")
            // Dump the candidate list to the unified log — this is what an
            // "AX enumerates, model selects" pointing path would choose from.
            for (i, e) in axElements.enumerated() {
                agentLog.info("AX candidate [\(i)] \(e.role, privacy: .public) \"\(e.label, privacy: .public)\" (\(Int(e.frame.minX)),\(Int(e.frame.minY)),\(Int(e.frame.width))×\(Int(e.frame.height)))")
            }

            // 3b. Kick off OCR concurrently while the user picks an action.
            let ocrTask = Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    let text = try await OCR.recognize(in: image)
                    return text.isEmpty ? nil : text
                } catch {
                    return nil
                }
            }

            // 4. No action picker — capture goes straight to a streamed
            //    explanation. (The user asks follow-ups in the open panel.)
            let request = ActionRequest(type: .explain)

            // 5. Build conversation, show panel, run initial turn.
            let ocr = await ocrTask.value
            let initialPrompt = Prompts.userMessage(
                request: request,
                appName: frontmostApp,
                ocrText: ocr
            )
            let conversation = Conversation(
                image: image,
                imagePixelSize: imagePixelSize,
                appName: frontmostApp,
                originalBundleID: frontmostBundleID,
                action: request.type,
                initialUserMessage: initialPrompt,
                captureRect: captureRect,
                captureScreen: screen,
                axElements: axElements
            )
            self.activeConversation = conversation
            presentConversation(conversation)
            await runToolLoop(in: conversation, isInitial: true, action: request.type)
        }
        self.activeTask = task
    }

    /// Ambient sight — capture the screen the user is looking at (the display
    /// under the cursor), excluding Akari's own windows, and stage it as the
    /// context for this turn. Local + ephemeral: the pixels go to the on-device
    /// model and are discarded; nothing is written to disk or sent anywhere,
    /// which is why no privacy exclude-list is needed.
    private func captureCurrentScreen(into conversation: Conversation) async -> (image: CGImage, pixelSize: CGSize)? {
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else {
            return nil
        }
        let rect = CGRect(origin: .zero, size: screen.frame.size)
        do {
            let raw = try await ScreenCapture.captureRegion(rect, on: screen)
            let prepared = ImagePreparation.prepareForAPI(raw)
            // Re-enumerate the target app's AX elements for THIS capture — the model
            // selects one by index to point at. Akari is frontmost on a follow-up,
            // so target the originally-captured app explicitly, not the frontmost.
            let axElements = AccessibilityProbe.elements(in: rect, of: conversation.originalBundleID, limit: 25)
            conversation.updateCurrentCapture(rect: rect, screen: screen, imagePixelSize: prepared.pixelSize, axElements: axElements)
            for (i, e) in axElements.enumerated() {
                agentLog.info("AX candidate [\(i)] \(e.role, privacy: .public) \"\(e.label, privacy: .public)\" (\(Int(e.frame.minX)),\(Int(e.frame.minY)),\(Int(e.frame.width))×\(Int(e.frame.height)))")
            }
            return (prepared.image, prepared.pixelSize)
        } catch {
            agentLog.error("ambient capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Cheap heuristic: does this typed prompt plausibly refer to what's on
    /// screen? Gates ambient capture so self-contained prompts ("write a
    /// haiku", "what is recursion") skip the expensive vision turn and answer
    /// at text speed, while screen-referential ones ("what's this error?",
    /// "summarize this") trigger a look. Imperfect by design — the user can
    /// always force a look with ⌥⌥, or add "this" to a phrasing.
    private func promptReferencesScreen(_ text: String) -> Bool {
        let lower = text.lowercased()
        let tokens = lower.split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard !tokens.isEmpty else { return false }

        // Deictic / screen-reference cues anywhere in the prompt.
        let cues: Set<String> = [
            "this", "that", "these", "those", "here", "screen", "page", "tab",
            "window", "above", "below", "selected", "highlighted", "error",
            "output", "log", "visible", "shown", "displayed", "dialog",
            "button", "menu", "onscreen",
            // Locating / pointing cues — "where is the search field" etc.
            "where", "where's", "locate", "find", "point", "click", "press",
            "icon", "field", "search", "box", "bar", "link", "toolbar", "sidebar",
        ]
        if tokens.contains(where: cues.contains) { return true }

        // Bare imperatives that imply "the thing in front of me."
        let screenVerbs: Set<String> = [
            "explain", "summarize", "summarise", "translate", "describe",
            "read", "transcribe", "debug", "fix",
        ]
        if let first = tokens.first, screenVerbs.contains(first), tokens.count <= 3 {
            return true
        }

        return false
    }

    /// Ambient-sight router for a typed turn. Decides what (if anything) Akari
    /// looks at, and what machine context the model receives:
    ///  1. Prompt names an OPEN WINDOW ("the error in Xcode") → capture that
    ///     exact window, even buried behind others or on another display.
    ///  2. Prompt references the screen generically ("what's this?") → capture
    ///     the visible display under the cursor.
    ///  3. Prompt asks about the machine ("what apps do I have open?") → no
    ///     screenshot, but pass the window manifest so Akari can answer.
    ///  4. Self-contained ("write a haiku") → no capture, no manifest, text speed.
    ///
    /// The manifest is a cheap system query (no pixels), so we always build it
    /// to detect window references; only the pixel capture in (1)/(2) costs a
    /// vision turn. This is the heuristic stage; M3's tool-use will let the
    /// model request a specific window itself.
    private func handleAmbientTurn(text: String, in conversation: Conversation) async {
        let windows = await ScreenCapture.windowManifest()

        if let target = windowReferenced(in: windows, by: text),
           let cap = await captureWindow(target, into: conversation) {
            conversation.pendingContextPreamble = contextPreamble(windows: windows, lookingAt: target)
            conversation.addUserMessage(text, image: cap.image, imagePixelSize: cap.pixelSize)
        } else if promptReferencesScreen(text),
                  let cap = await captureCurrentScreen(into: conversation) {
            conversation.pendingContextPreamble = contextPreamble(windows: windows, lookingAt: nil)
            conversation.addUserMessage(text, image: cap.image, imagePixelSize: cap.pixelSize)
        } else if referencesOpenWindows(text) {
            conversation.pendingContextPreamble = contextPreamble(windows: windows, lookingAt: nil)
            conversation.addUserMessage(text)
        } else {
            conversation.pendingContextPreamble = ""
            conversation.addUserMessage(text)
        }
    }

    /// Capture one specific (possibly occluded) window and stage it as this
    /// turn's context. Ephemeral, like the full-screen path.
    private func captureWindow(_ window: WindowInfo, into conversation: Conversation) async -> (image: CGImage, pixelSize: CGSize)? {
        do {
            let raw = try await ScreenCapture.captureWindow(id: window.id)
            let prepared = ImagePreparation.prepareForAPI(raw)
            conversation.updateCurrentCapture(
                rect: CGRect(origin: .zero, size: prepared.pixelSize),
                screen: nil,
                imagePixelSize: prepared.pixelSize,
                axElements: []   // occluded-window pointing is a separate case (pixel-origin coords)
            )
            return (prepared.image, prepared.pixelSize)
        } catch {
            agentLog.error("window capture failed for \(window.appName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Does the prompt name one of the currently-open windows? Scores prompt
    /// tokens against each window's app name (weighted) and title words,
    /// ignoring generic tokens ("code", "app") that cause false hits. Returns
    /// the best match, or nil.
    private func windowReferenced(in windows: [WindowInfo], by text: String) -> WindowInfo? {
        let promptTokens = Set(
            text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        )
        guard !promptTokens.isEmpty, !windows.isEmpty else { return nil }

        let stop: Set<String> = [
            "app", "application", "window", "windows", "code", "studio",
            "google", "microsoft", "apple", "helper", "beta", "document",
        ]
        func sigTokens(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter }.map(String.init)
                .filter { $0.count >= 4 && !stop.contains($0) })
        }

        func score(_ w: WindowInfo) -> Int {
            let appTokens = sigTokens(w.appName)
            let titleTokens = sigTokens(w.title)
            var s = 0
            for t in promptTokens {
                if appTokens.contains(t) { s += 3 }        // app-name hit: strong
                else if titleTokens.contains(t) { s += 1 } // title-word hit: weak
            }
            return s
        }

        return windows.map { ($0, score($0)) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    /// Cheap check for "tell me about my machine" prompts that want the window
    /// list but no screenshot ("what apps do I have open?", "what's running?").
    private func referencesOpenWindows(_ text: String) -> Bool {
        let tokens = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return !tokens.isDisjoint(with: ["apps", "running", "tabs", "spaces", "desktops", "windows"])
    }

    /// Render the window manifest as a short text preamble for the model. When
    /// `lookingAt` is set, it notes which window the attached screenshot shows.
    private func contextPreamble(windows: [WindowInfo], lookingAt: WindowInfo?) -> String {
        guard !windows.isEmpty else { return "" }
        var lines = ["[Windows currently open on this Mac:"]
        for w in windows {
            let display = w.displayIndex.map { " (Display \($0))" } ?? ""
            let title = w.title.isEmpty ? "" : " — \"\(w.title)\""
            lines.append("- \(w.appName)\(title)\(display)")
        }
        if let look = lookingAt {
            let title = look.title.isEmpty ? "" : " (\"\(look.title)\")"
            lines.append("The attached screenshot is the \(look.appName) window\(title).")
        }
        lines.append("]")
        return lines.joined(separator: "\n")
    }

    /// Reopen a saved conversation from the History page: restore the text
    /// transcript, make it the active conversation, and mount it. It keeps its
    /// persistent id, so continuing it updates the same stored row.
    private func openSavedConversation(id: String) async {
        guard let snap = await ConversationStore.shared.load(id: id) else {
            agentLog.info("history: no stored conversation for id \(id, privacy: .public)")
            return
        }
        let convo = Conversation.restore(from: snap)
        activeConversation = convo
        presentConversation(convo)
    }

    private func presentConversation(_ conversation: Conversation, andOpen: Bool = true) {
        NotchController.shared.present(
            conversation: conversation,
            onSubmit: { [weak self] text in
                Task { @MainActor in
                    let attachedPDF = conversation.pendingPDF
                    conversation.clearPendingPDF()

                    if let pdf = attachedPDF {
                        conversation.addUserMessage(text, pdfData: pdf.data, pdfFilename: pdf.filename)
                    } else {
                        // Ambient sight: route to the visible screen, a specific
                        // (even occluded) window, or a pure text turn — and hand
                        // the model a manifest of what's open. See handleAmbientTurn.
                        await self?.handleAmbientTurn(text: text, in: conversation)
                    }

                    await self?.runToolLoop(in: conversation, isInitial: false, action: conversation.initialAction)
                }
            },
            onAddPDF: { [weak self] in
                Task { @MainActor in
                    self?.attachPDF(to: conversation)
                }
            },
            andOpen: andOpen
        )
    }

    /// Show an open panel to pick a PDF, then stage it as the pending PDF on the conversation.
    private func attachPDF(to conversation: Conversation) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        panel.title = "Choose a PDF to attach"
        panel.prompt = "Attach"
        // While the panel is showing we want to be able to interact with it; activate as regular.
        let priorPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        NSApp.setActivationPolicy(priorPolicy)
        guard response == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            // Soft cap at ~30MB to stay under Anthropic's 32MB PDF limit after base64 inflation.
            let maxBytes = 30 * 1024 * 1024
            guard data.count <= maxBytes else {
                conversation.errorMessage = "PDF is too large (\(data.count / 1024 / 1024) MB). Anthropic's limit is ~32 MB."
                return
            }
            conversation.setPendingPDF(PendingPDF(data: data, filename: url.lastPathComponent))

        } catch {
            conversation.errorMessage = "Couldn't read PDF: \(error.localizedDescription)"
        }
    }

    /// Hide the chat panel, run a fresh selection overlay, capture a region,
    /// and stage it as the pending attachment on the conversation.
    /// The agent loop (M3). Replaces the old single-shot `runTurn` at every call
    /// site. Three paths, in priority order:
    ///   1. POINTING turn (image + asked to point + not the initial explain) →
    ///      ONE step, the validated index-select `point_at` path. Unchanged.
    ///   2. ACTION turn (asked to do/recapture something) → a bounded multi-step
    ///      loop: stream → parse a tool call → execute → fold the result into the
    ///      next prompt → repeat, until no call (final answer) or `maxSteps`.
    ///   3. PLAIN explain/ask → ONE step, no tools. Identical to the old behavior.
    /// Owns the working-comet + completion notification for the WHOLE run.
    private func runToolLoop(in conversation: Conversation, isInitial: Bool, action: ActionType) async {
        guard !isAgentRunning else { agentLog.info("runToolLoop: re-entry ignored (already running)"); return }
        isAgentRunning = true
        NotchController.shared.setWorking(true)
        defer {
            isAgentRunning = false
            NotchController.shared.setWorking(false)
            // Persist the transcript on EVERY exit path (text-only snapshot; the
            // loop is the single choke point all turns — typed, voice, capture —
            // flow through).
            if let snap = conversation.snapshot() {
                Task.detached(priority: .utility) { await ConversationStore.shared.save(snap) }
            }
            if !NotchController.shared.isPanelOpen {
                let last = conversation.visibleMessages.last
                let body = last.flatMap { $0.text.isEmpty ? nil : String($0.text.prefix(140)) } ?? "Task complete."
                NotificationsService.shared.notifyTaskComplete(body: body)
                NotchController.shared.notifyResult((last?.text).map { String($0.prefix(800)) } ?? "Done")
            }
        }

        let image = conversation.messages.last(where: { $0.role == .user })?.image
        let userText = conversation.messages.last(where: { $0.role == .user })?.text ?? ""
        agentLog.info("runToolLoop: ENTER isInitial=\(isInitial) text=\"\(userText, privacy: .public)\"")

        // 0. CLICK turn — the same select-by-index as pointing, but ACTED on:
        // highlight → confirm card → AXPress → audit. Checked before pointing so
        // "click the send button" presses rather than just highlights.
        if image != nil, !isInitial, promptAsksToClick(userText) {
            let finalText = await streamOneTurn(in: conversation, instr: pointAtToolInstruction(elements: conversation.axElements), display: false)
            if !(await dispatchClickIfPresent(finalText, conversation: conversation)) {
                conversation.commitAssistantMessage("I don't see that on the screen.")
            }
            return
        }

        // 1. Pointing turn — single step, validated index-select path. Buffered
        // (display:false) so the raw point_at JSON never shows; the highlight IS the
        // answer, so we add a message only when nothing was highlighted.
        if image != nil, !isInitial, promptAsksToPoint(userText) {
            let finalText = await streamOneTurn(in: conversation, instr: pointAtToolInstruction(elements: conversation.axElements), display: false)
            if !dispatchPointAtIfPresent(finalText, conversation: conversation) {
                conversation.commitAssistantMessage("I don't see that on the screen.")
            }
            return
        }

        // 2b. MEMORY — explicit "remember that…" / "forget…" turns are handled by
        // deterministic code, never a model turn (facts enter memory only
        // explicitly — PRODUCT.md memory layer; the user can read the whole store
        // in Settings → Memory).
        if !isInitial, let fact = parseRememberCommand(userText) {
            let stored = await MemoryStore.shared.remember(fact)
            let reply = stored != nil ? "Remembered: \(fact)" : "I couldn't save that."
            conversation.commitAssistantMessage(reply)
            Task { await AuditLog.shared.record(tool: "remember", argsJSON: "{}", outcome: stored != nil ? "ok" : "error", summary: String(fact.prefix(80)), confirmed: false) }
            return
        }
        if !isInitial, let phrase = parseForgetCommand(userText) {
            let matches = await MemoryStore.shared.matching(phrase)
            switch matches.count {
            case 0:
                conversation.commitAssistantMessage("I don't have anything remembered about that.")
            case 1:
                await MemoryStore.shared.delete(id: matches[0].id)
                conversation.commitAssistantMessage("Forgotten: \(matches[0].content)")
                Task { await AuditLog.shared.record(tool: "forget", argsJSON: "{}", outcome: "ok", summary: String(matches[0].content.prefix(80)), confirmed: false) }
            default:
                conversation.commitAssistantMessage("That matches \(matches.count) remembered facts — remove the right one in Settings → Memory.")
            }
            return
        }

        // Memory injection — the top keyword-matched facts, folded RIGHT NEXT
        // to the user's text by streamOneTurn (its own slot, not the context
        // preamble: sandwiched before the tool spec the 4B ignored it —
        // verified live). Empty for prompts that touch nothing remembered.
        if !userText.isEmpty {
            let facts = await MemoryStore.shared.relevant(to: userText)
            conversation.pendingMemory = MemoryStore.preamble(for: facts)
            if !facts.isEmpty {
                agentLog.info("memory: injecting \(facts.count) fact(s) for this turn")
            }
        }

        // 3. Plain explain/ask — no tools, identical to the old single-turn path.
        guard !isInitial, promptAsksToAct(userText) else {
            _ = await streamOneTurn(in: conversation, instr: "")
            return
        }

        // 2a-0a. EVENT TRIGGER — "when(ever) a PDF lands in Downloads, …" saves a
        // reactive automation (approved once; fired by TriggerEngine, no card).
        if hasEventTriggerHint(userText), await saveTriggeredAutomationIfRequested(goal: userText, in: conversation) { return }

        // 2a-0. SCHEDULE — if the goal is a recurring request ("every day at 8am…"),
        // save it as a scheduled automation (approved once) instead of running now.
        if hasScheduleHint(userText), await saveScheduledAutomationIfRequested(goal: userText, in: conversation) { return }

        // 2a. RECIPE path — if a recipe matches the goal, run the RELIABLE
        // retrieve→fill→AppleScript path (the 7B does app-control badly freeform; a
        // recipe fixes that). Keyword-gated, so non-recipe turns skip it with no cost.
        if await runRecipeIfMatched(goal: userText, in: conversation) { return }

        // 2. Action loop. (Increment 1: only the read-only, no-permission
        // `recapture_screen` is wired; registry action tools are the next step.)
        let maxSteps = 5
        var pendingResult = ""
        var lastToolSummary = ""   // fallback shown if the 7B returns an empty final answer — the user always gets feedback
        var terminalDone = false   // set once a consequential action completes (or is declined) → conclude, never re-call
        for step in 0..<maxSteps {
            if Task.isCancelled { return }
            let instr = [actionToolInstruction(), pendingResult].filter { !$0.isEmpty }.joined(separator: "\n\n")
            pendingResult = ""
            let finalText = await streamOneTurn(in: conversation, instr: instr, display: false)
            guard let call = parseToolCall(finalText) else {            // no tool call → final answer
                conversation.commitAssistantMessage(finalText.isEmpty ? lastToolSummary : finalText)
                return
            }
            agentLog.info("runToolLoop: step \(step) → tool=\(call.name, privacy: .public) args=\(String(describing: call.args), privacy: .public)")
            switch call.name {
            case "recapture_screen":
                if let cap = await captureCurrentScreen(into: conversation) {
                    pendingResult = toolResultText("recapture_screen", "Re-captured the current screen (\(Int(cap.pixelSize.width))×\(Int(cap.pixelSize.height)) px); the on-screen element list is refreshed.", isError: false)
                } else {
                    pendingResult = toolResultText("recapture_screen", "Couldn't recapture the screen.", isError: true)
                }
            default:
                // Registry action tools. `.confirm` (write/send/destructive) tools
                // wait for the confirm flow (next increment) — refuse for now; `.auto`
                // (read-only) tools execute and feed the result back into the loop.
                if let tool = ToolRegistry.tool(named: call.name) {
                    let argsJSON = (try? JSONSerialization.data(withJSONObject: call.args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    var approved = true
                    if tool.confirmation == .confirm {
                        approved = await awaitConfirmation(in: conversation, toolName: call.name, args: call.args)
                        if Task.isCancelled { return }
                    }
                    if approved {
                        let r = await ToolRegistry.execute(name: call.name, args: call.args, in: conversation)
                        // Audit trail — every executed tool, local-only (PRODUCT.md headline differentiator).
                        Task { await AuditLog.shared.record(tool: call.name, argsJSON: argsJSON, outcome: r.isError ? "error" : "ok", summary: r.displaySummary ?? String(r.content.prefix(80)), confirmed: tool.confirmation == .confirm) }
                        if !r.isError {
                            lastToolSummary = r.content
                            // Transparency: a chip for what ran — SUCCESSES only, so intermediate
                            // retry failures (wrong path, etc.) don't clutter the transcript.
                            conversation.addToolChip(name: call.name, inputJSON: argsJSON, content: r.content, isError: false, displaySummary: r.displaySummary)
                            // A mutating/consequential tool is DONE — conclude; never let the loop
                            // re-call it (that would double-act: two drafts, two events). Read-only
                            // tools stay non-terminal so the model can use the data to answer.
                            let readOnly: Set<String> = ["read_calendar_events", "list_reminders", "list_files", "read_file", "list_shortcuts"]
                            if !readOnly.contains(call.name) { terminalDone = true }
                        }
                        var hint = ""
                        if r.isError {
                            // Self-correct: steer a FIXED retry, not an apology.
                            hint = "\n\nThis failed. Fix the cause and call \(call.name) again with corrected input — do NOT repeat the same failing call. If it genuinely can't be done, say so briefly in plain text."
                            // Failed AppleScript → inject the target app's REAL dictionary so the
                            // corrected script uses valid vocabulary (sdef subprocess, fetched off-main).
                            if call.name == "run_applescript", let script = call.args["script"] as? String,
                               let app = AppleScriptDictionary.appName(in: script),
                               let dict = await Task.detached(priority: .userInitiated,
                                                              operation: { AppleScriptDictionary.condensed(forApp: app) }).value {
                                hint += "\n\n\(dict)"
                            }
                        }
                        pendingResult = toolResultText(call.name, r.content + hint, isError: r.isError)
                    } else {
                        Task { await AuditLog.shared.record(tool: call.name, argsJSON: argsJSON, outcome: "declined", summary: "declined by user", confirmed: true) }
                        terminalDone = true   // user cancelled — acknowledge and stop, never re-prompt
                        lastToolSummary = "Okay, I've left that alone."
                        pendingResult = toolResultText(call.name, "The user declined this action. Acknowledge briefly and stop — do not retry.", isError: false)
                    }
                } else {
                    pendingResult = toolResultText(call.name, "Unknown tool '\(call.name)'. Answer the user directly.", isError: true)
                }
            }
            if terminalDone {   // consequential action finished (or was declined) — conclude now, no re-call
                agentLog.info("runToolLoop: terminalDone after \(call.name, privacy: .public) — concluding, loop ends")
                conversation.commitAssistantMessage(lastToolSummary)
                return
            }
        }
        // Cap reached — force one final plain-text answer (no tools).
        _ = await streamOneTurn(in: conversation, instr: pendingResult + "\n\n[Step limit reached — give your final answer now in plain text, no tools.]")
    }

    /// ONE model turn: See (image) or Ask (text). `instr` is extra context folded
    /// into the user prompt (a candidate list, a tool spec, or a tool result —
    /// never a system message, which segfaults the local chat template). Returns
    /// the final assistant text. The single-step primitive `runToolLoop` calls.
    private func streamOneTurn(in conversation: Conversation, instr: String, display: Bool = true) async -> String {
        let preamble = conversation.pendingContextPreamble
        conversation.pendingContextPreamble = ""
        // Memory sits CLOSEST to the user's text — last position wins the 4B's
        // attention; before the tool spec it gets ignored (verified live).
        let memory = conversation.pendingMemory
        conversation.pendingMemory = ""
        let image = conversation.messages.last(where: { $0.role == .user })?.image
        let stream: AsyncThrowingStream<String, Error>
        if let image {
            let userText = conversation.messages.last(where: { $0.role == .user })?.text ?? ""
            let prompt = [preamble, instr, memory, userText].filter { !$0.isEmpty }.joined(separator: "\n\n")
            agentLog.info("streamOneTurn: See. prompt=\"\(userText, privacy: .public)\"")
            stream = LocalEngine.shared.explain(image: image, prompt: prompt)
        } else {
            var history = conversation.visibleMessages
                .filter { !$0.text.isEmpty }
                .map { LocalEngine.ChatTurn(role: $0.role == .user ? .user : .assistant, text: $0.text) }
            guard !history.isEmpty else { return "" }
            let fold = [preamble, instr, memory].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !fold.isEmpty, let last = history.indices.last {
                history[last] = LocalEngine.ChatTurn(role: .user, text: fold + "\n\n" + history[last].text)
            }
            agentLog.info("streamOneTurn: Ask (text chat, \(history.count) turns)")
            stream = LocalEngine.shared.chat(history: history)
        }

        // When `display` is false (agent-loop turns), deltas are buffered off-screen
        // rather than streamed into a visible bubble — so a raw tool-call payload
        // never reaches the transcript. The caller commits the final answer instead.
        let assistantIdx = display ? conversation.startAssistantStream() : -1
        if !display { conversation.isAwaitingResponse = true }
        var buf = ""
        var deltaCount = 0
        let streamStart = Date()
        do {
            for try await delta in stream {
                deltaCount += 1
                if deltaCount == 1 {
                    agentLog.info("streamOneTurn: first delta after \(String(format: "%.1f", Date().timeIntervalSince(streamStart)))s")
                }
                buf += delta
                if display { conversation.appendChunk(at: assistantIdx, delta) }
            }
            agentLog.info("streamOneTurn: finished — \(deltaCount) deltas, \(buf.count) chars, \(String(format: "%.1f", Date().timeIntervalSince(streamStart)))s")
            #if DEBUG
            agentLog.info("streamOneTurn: answer=\"\(buf.replacingOccurrences(of: "\n", with: " ").prefix(600), privacy: .public)\"")
            #endif
            if display { conversation.finishAssistantStream(at: assistantIdx) } else { conversation.isAwaitingResponse = false }
            return buf
        } catch {
            agentLog.error("streamOneTurn threw after \(deltaCount) deltas: \(error.localizedDescription, privacy: .public)")
            conversation.setError(error.localizedDescription)
            if display { conversation.finishAssistantStream(at: assistantIdx) } else { conversation.isAwaitingResponse = false }
            return ""
        }
    }

    /// Format a tool result for folding back into the next USER prompt (text only).
    private func toolResultText(_ name: String, _ content: String, isError: Bool) -> String {
        "[Tool result for \(name)\(isError ? " (error)" : "")]:\n\(content)"
    }

    /// The (currently minimal) action-tool spec, folded into the prompt on an
    /// action turn. Increment 1 wires only the read-only `recapture_screen`.
    private func actionToolInstruction() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let now = f.string(from: Date())
        return """
        # Tools
        You have REAL access to this Mac through the tools below — you CAN read the user's files, calendar, and reminders, and act on their apps. To answer a question about their stuff or to do something, CALL THE RELEVANT TOOL. Never reply that you "can't access" their computer or that you're "just an AI" — use a tool instead.
        You CANNOT send email or messages — the draft tools only OPEN a pre-filled compose window. If the user says "send it" (or similar) after you've drafted, DON'T draft again: tell them it's ready in their mail/Messages app and they can send it there themselves.
        You can call ONE tool by replying with ONLY this JSON: {"name": "<tool>", "arguments": { … }}. To finish, write your answer in plain text (no JSON).
        The current local date/time is \(now). Use THIS timezone offset in all event times unless the user names another — do not output a "Z"/UTC time.
        - read_calendar_events(start_iso, end_iso) — the user's calendar events in a date range. Use a FULL span, never a zero-width range: "today" = 00:00→23:59 today, "this week" = the week's start→end, "next 3 days" = now→+3 days.
        - create_calendar_event(title, start_iso, end_iso, [location], [notes]) — add an event to the calendar (the user confirms before it's saved). Use a specific title drawn from the request.
        - list_reminders([state]) — the user's reminders/to-dos (state: incomplete|complete|all; default incomplete).
        - create_reminder(title, [due_iso], [notes], [priority]) — add a to-do/reminder (the user confirms). due_iso is optional; same local-time rule as events.
        - list_files([path]) / read_file(path) / write_file(path, content) — list a folder, read a text file, or save a text file. Use ABSOLUTE paths for the user's folders: Desktop = "~/Desktop", Documents = "~/Documents", Downloads = "~/Downloads". A bare/relative name resolves to Akari's own workspace (usually NOT what the user means).
        - open_file(path) — open a file in its default app. open_url(url) — open a web URL in the browser.
        - delete_file(path) / move_file(src, dst) — move a file to Trash, or move/rename it (the user confirms).
        - draft_email_reply([to], [subject], body) — open an email draft in the mail app for the user to review and send (you NEVER send). Use for "reply to this email", "draft a response".
        - draft_imessage([to], body) — open a Messages draft for the user to review and send.
        - run_applescript(script, [purpose]) — do ANYTHING else on the Mac the other tools don't cover: open/quit apps, control Music/Mail/Finder/Safari, move files, change system settings, type or paste text. The user sees the script and confirms before it runs. Prefer simple, reliable idioms — open or focus an app with 'tell application "X" to activate'; for text longer than a few words set the clipboard then paste with Command-V rather than typing via System Events. Set `purpose` to one plain sentence saying what it does.
        - list_shortcuts() / run_shortcut(name) — the user's Shortcuts.app shortcuts: list their names, or run one by its EXACT name (the user confirms). When the user says "run my X shortcut" use run_shortcut; if unsure of the exact name, call list_shortcuts first.\(ShellTool.shared.isEnabled ? "\n- run_shell(command, [working_directory]) — run one zsh command line (developer workflows: git, brew, npm, find). The user sees the exact command and confirms. Prefer the file tools for file operations." : "")
        - recapture_screen — a fresh screenshot of what's on screen now (call before answering if the screen may have changed).
        """
    }

    /// "remember that X" / "remember my X" / "remember I X" → the fact to store.
    /// "remember to X" is deliberately NOT memory — that's a reminder request and
    /// falls through to the normal loop (create_reminder).
    func parseRememberCommand(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        guard lower.hasPrefix("remember ") else { return nil }
        if lower.hasPrefix("remember to ") { return nil }
        var rest = String(t.dropFirst("remember ".count))
        if rest.lowercased().hasPrefix("that ") { rest = String(rest.dropFirst("that ".count)) }
        let fact = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return fact.isEmpty ? nil : fact
    }

    /// "forget (that|about|my) X" → the phrase to match against stored facts.
    /// Bare "forget it" is colloquial, not a deletion.
    func parseForgetCommand(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        guard lower.hasPrefix("forget ") else { return nil }
        if lower == "forget it" || lower == "forget about it" { return nil }
        var rest = String(t.dropFirst("forget ".count))
        for prefix in ["that ", "about ", "what i said about "] where rest.lowercased().hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
        }
        let phrase = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return phrase.isEmpty ? nil : phrase
    }

    /// Does the prompt ask Akari to DO something (vs. explain/ask)? Gates the
    /// action loop so plain explain/ask turns keep their validated single-turn
    /// behavior. Conservative for Increment 1 (recapture-style intent).
    private func promptAsksToAct(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // HIGH-RECALL gate: offer tools for almost everything and let the model decide.
        // Missing a needed tool ("what's on my desktop" → list_files, "am I free?" →
        // read_calendar_events) makes Akari look broken; offering an unused one just
        // costs a little prompt. Only a pure screen-DESCRIBE (handled by the tool-less
        // vision path) and short conversational filler opt out.
        if t.hasPrefix("explain") || t.hasPrefix("describe") { return false }
        let fillers: Set<String> = ["hi", "hello", "hey", "thanks", "thank you", "ty", "ok", "okay",
                                    "cool", "nice", "great", "got it", "yes", "no", "yep", "nope", "sure"]
        return !fillers.contains(t)
    }

    /// Present a confirmation card for a `.confirm` tool and SUSPEND the loop until
    /// the user decides — bridging the existing `ConfirmationRequest.onDecision`
    /// callback to a continuation. `withCheckedContinuation` suspends the loop task
    /// without blocking the MainActor, so the card renders + the tap is processed
    /// normally. The working-comet pauses while the user decides (the model isn't
    /// working), and resumes after.
    @MainActor
    private func awaitConfirmation(in conversation: Conversation, toolName: String, args: [String: Any]) async -> Bool {
        await awaitConfirmation(in: conversation, title: confirmTitle(toolName),
                                rows: confirmRows(args: args), label: toolName,
                                destructive: ["delete_file", "move_file", "run_shell"].contains(toolName))
    }

    /// Core confirm-card await — present the card with explicit title + rows and SUSPEND
    /// the loop until the user taps (bridging `onDecision` → continuation). The comet
    /// pauses while they decide. Reused by tool calls AND recipe runs.
    @MainActor
    private func awaitConfirmation(in conversation: Conversation, title: String,
                                  rows: [(label: String, value: String)], label: String,
                                  destructive: Bool = false) async -> Bool {
        agentLog.info("awaitConfirmation: SHOW card for \(label, privacy: .public)")
        NotchController.shared.setWorking(false)
        defer { NotchController.shared.setWorking(true) }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            conversation.pendingConfirmation = ConfirmationRequest(
                title: title, detailRows: rows, confirmLabel: "Run", cancelLabel: "Cancel",
                isDestructive: destructive,
                onDecision: { approved in
                    agentLog.info("awaitConfirmation: decision=\(approved) for \(label, privacy: .public)")
                    conversation.pendingConfirmation = nil
                    cont.resume(returning: approved)
                }
            )
        }
    }

    /// Friendly card title from a tool name: "create_calendar_event" → "Create calendar event?".
    private func confirmTitle(_ toolName: String) -> String {
        let phrase = toolName.split(separator: "_").joined(separator: " ")
        return phrase.isEmpty ? "Run this action?" : "\(phrase.prefix(1).uppercased())\(phrase.dropFirst())?"
    }

    /// One card row per NON-EMPTY argument, in a sensible order with friendly labels
    /// and (for ISO dates) human-readable local times — so the user can verify the
    /// action at a glance before approving.
    private func confirmRows(args: [String: Any]) -> [(label: String, value: String)] {
        let pretty = ["purpose": "What it does", "title": "Title", "start_iso": "Starts", "end_iso": "Ends",
                      "due_iso": "Due", "priority": "Priority", "path": "File", "src": "From", "dst": "To",
                      "location": "Location", "notes": "Notes", "to": "To", "subject": "Subject",
                      "body": "Body", "message": "Message", "content": "Contents", "script": "Script"]
        // Long fields (content, script) go LAST; everything else reads top-down.
        let order = ["purpose", "title", "start_iso", "end_iso", "due_iso", "priority", "to", "subject",
                     "location", "notes", "path", "src", "dst", "message", "body", "content", "script"]
        func rank(_ k: String) -> Int { order.firstIndex(of: k) ?? order.count }
        return args
            .sorted { rank($0.key) < rank($1.key) }
            .compactMap { (k, v) -> (label: String, value: String)? in
                var val = friendlyValue(key: k, raw: String(describing: v))
                guard !val.isEmpty else { return nil }
                if val.count > 1000 { val = String(val.prefix(1000)) + "\n… (+\(val.count - 1000) more characters)" }
                return (label: pretty[k] ?? k, value: val)
            }
    }

    /// Render an argument value for display: ISO datetimes become a local
    /// "Jul 1, 2026 at 3:00 PM"; everything else is passed through (trimmed).
    private func friendlyValue(key: String, raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasSuffix("_iso"), !trimmed.isEmpty, let d = CalendarTools.parseDate(trimmed) {
            let out = DateFormatter(); out.dateStyle = .medium; out.timeStyle = .short
            return out.string(from: d)
        }
        return trimmed
    }

    #if DEBUG
    // MARK: - DEBUG test harness (autonomous build/test loop)
    //
    // Lets the edit→build→test loop run WITHOUT driving the GUI. Poll a command
    // file: write a pointing query → the pipeline runs against the frontmost app
    // and the dispatch logs the selected element + live frame; write "__selftest__"
    // → pure-logic checks (parser + ranking) log PASS/FAIL. Read outcomes from the
    // unified log (subsystem com.dimarussu.Akari, category Agent). DEBUG-only.

    private static let testCmdPath = "/tmp/akari_test_cmd"

    private func startTestHarness() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let raw = try? String(contentsOfFile: Self.testCmdPath, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(atPath: Self.testCmdPath)   // consume immediately
            let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { return }
            Task { @MainActor in
                if cmd == "__selftest__" { self?.runSelfTest() }
                else if cmd == "__comet__" { await self?.runCometProbe() }
                else if cmd == "__highlight__" { self?.runHighlightProbe() }
                else if cmd == "__axtree__" { self?.runAXTreeDump() }
                else if cmd.hasPrefix("__plan__ ") { await self?.runPlanProbe(goal: String(cmd.dropFirst(9))) }
                else if cmd.hasPrefix("__recipe__ ") { await self?.runRecipeProbe(goal: String(cmd.dropFirst(11))) }
                else if cmd == "__schedtest__" { self?.runSchedTest() }
                else if cmd == "__trigtest__" { self?.runTrigTest() }
                else if cmd == "__trigapptest__" { self?.runTrigAppTest() }
                else if cmd == "__permstest__" { await self?.runPermsTest() }
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
                    } else {
                        agentLog.info("convstoretest: ERROR — snapshot was nil")
                    }
                }
                else if cmd == "__shortcutstest__" {
                    // list via the real tool path; run only if a shortcut named
                    // "Akari Test" exists (create one by hand for the full round-trip).
                    do {
                        let names = try await ShortcutsTools.shared.listNames()
                        agentLog.info("shortcutstest: \(names.count) installed — \(names.prefix(10).joined(separator: " | "), privacy: .public)")
                        if names.contains("Akari Test") {
                            let out = try await ShortcutsTools.shared.run(name: "Akari Test")
                            agentLog.info("shortcutstest: run → \(out, privacy: .public)")
                        } else {
                            agentLog.info("shortcutstest: no “Akari Test” shortcut — run skipped")
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
                    // Akari writes its OWN screen capture to /tmp (it holds Screen
                    // Recording; the shell tool doesn't) — for eyeballing the notch UI.
                    if let screen = NSScreen.main,
                       let img = try? await ScreenCapture.captureRegion(CGRect(origin: .zero, size: screen.frame.size), on: screen) {
                        let rep = NSBitmapImageRep(cgImage: img)
                        if let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath: "/tmp/akari_grab.png"))
                            agentLog.info("grabscreen: wrote /tmp/akari_grab.png")
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

    /// PLANNING PROBE (`__plan__ <goal>`): can the local 7B decompose a multi-step
    /// automation into a sane ordered plan of tool calls? Text-only, NO execution —
    /// just logs the plan for eyeballing. Decides freeform-plan vs recipe-first.
    private func runPlanProbe(goal: String) async {
        let tools = ToolRegistry.promptSpec(for: ToolRegistry.all)
        let prompt = """
        You are Akari, an assistant that automates a Mac using ONLY these tools:
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
            for try await delta in LocalEngine.shared.chat(history: [LocalEngine.ChatTurn(role: .user, text: prompt)]) {
                plan += delta
            }
        } catch {
            agentLog.error("planprobe error: \(error.localizedDescription, privacy: .public)"); return
        }
        agentLog.info("planprobe PLAN for \"\(goal, privacy: .public)\":\n\(plan, privacy: .public)")
    }

    // MARK: - Recipe engine (Phase 1 prototype — see AGENTS.md)

    /// One text-only model turn → the reply string.
    private func askModel(_ prompt: String) async -> String {
        var out = ""
        do {
            for try await d in LocalEngine.shared.chat(history: [LocalEngine.ChatTurn(role: .user, text: prompt)]) { out += d }
        } catch { return "" }
        return out
    }

    /// RECIPE MATCH — prefilter by keyword, then the 7B SELECTS one by index (the
    /// pointing trick: enumerate candidates → pick an index; -1 = none fit). No free
    /// generation, so it can't hallucinate a tool.
    private func matchRecipe(goal: String) async -> Recipe? {
        let candidates = RecipeLibrary.prefilter(goal, in: RecipeStore.shared.recipes)
        guard !candidates.isEmpty else { return nil }
        let list = candidates.enumerated().map { "[\($0)] \($1.title) — \($1.description)" }.joined(separator: "\n")
        let reply = await askModel("""
        The user wants: "\(goal)"

        Which automation best matches? Reply with ONLY the number of the best match, or -1 if NONE fit.
        \(list)
        """)
        guard let idx = firstInt(in: reply) else { return nil }
        return (idx >= 0 && idx < candidates.count) ? candidates[idx] : nil
    }

    /// RECIPE FILL — the 7B emits a JSON object of parameter values from the goal
    /// (structured output = its strength). `[:]` for a param-less recipe.
    private func fillParams(recipe: Recipe, goal: String) async -> [String: Any] {
        guard !recipe.params.isEmpty else { return [:] }
        let spec = recipe.params.map { "- \($0.name) (\($0.type.describe)): \($0.prompt)" }.joined(separator: "\n")
        let reply = await askModel("""
        The user wants: "\(goal)"

        Fill the parameters for the "\(recipe.title)" automation. Reply with ONLY a JSON object
        mapping each parameter name to its value. Use the value DIRECTLY — a number as a number,
        text as a string; ONLY a "list of names" param takes a JSON array:
        \(spec)
        """)
        for json in jsonObjectCandidates(in: reply) {
            if let d = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return obj
            }
        }
        return [:]
    }

    /// First integer (incl. negative) in a string.
    private func firstInt(in s: String) -> Int? {
        guard let r = s.range(of: "-?\\d+", options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    /// RECIPE PROBE (`__recipe__ <goal>`): match → fill → resolve, logging each stage
    /// (no execution) to validate retrieve+fill on the real model.
    private func runRecipeProbe(goal: String) async {
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

    /// RECIPE RUNNER — if a recipe matches the goal, run it end-to-end: fill params →
    /// confirm card (recipe title + resolved script = preview) → `run_applescript` →
    /// audit + chip. Returns true if a recipe handled the turn (loop concludes), false
    /// to fall through to freeform tools. This is the live agentic path.
    private func runRecipeIfMatched(goal: String, in conversation: Conversation) async -> Bool {
        guard let recipe = await matchRecipe(goal: goal) else { return false }
        agentLog.info("recipe: matched → \(recipe.id, privacy: .public)")
        let params = await fillParams(recipe: recipe, goal: goal)
        let script = recipe.resolve(recipe.body, with: params)
        let title = recipe.resolve(recipe.confirmTemplate, with: params)
        let argsJSON = (try? JSONSerialization.data(withJSONObject: ["recipe": recipe.id, "params": params]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let chipJSON = (try? JSONSerialization.data(withJSONObject: ["purpose": recipe.title]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let approved = await awaitConfirmation(in: conversation, title: "\(title)?",
                                               rows: [("Recipe", recipe.title), ("Script", script)],
                                               label: "recipe:\(recipe.id)", destructive: recipe.id == "empty-trash")
        if Task.isCancelled { return true }
        guard approved else {
            Task { await AuditLog.shared.record(tool: "recipe:\(recipe.id)", argsJSON: argsJSON, outcome: "declined", summary: "declined by user", confirmed: true) }
            conversation.commitAssistantMessage("Okay, I've left that alone.")
            return true
        }
        do {
            let output = try AppleScriptTool.shared.runScript(script)
            Task { await AuditLog.shared.record(tool: "recipe:\(recipe.id)", argsJSON: argsJSON, outcome: "ok", summary: recipe.title, confirmed: true) }
            conversation.addToolChip(name: "run_applescript", inputJSON: chipJSON,
                                     content: output.isEmpty ? recipe.title : output, isError: false, displaySummary: recipe.title)
            conversation.commitAssistantMessage("Done — \(recipe.title.lowercased()).")
        } catch {
            Task { await AuditLog.shared.record(tool: "recipe:\(recipe.id)", argsJSON: argsJSON, outcome: "error", summary: error.localizedDescription, confirmed: true) }
            conversation.commitAssistantMessage("That didn't work — \(error.localizedDescription)")
        }
        return true
    }

    // MARK: - Automations (save + schedule)

    /// True if the goal reads like a RECURRING schedule request ("every day at 8am…").
    private func hasScheduleHint(_ goal: String) -> Bool {
        let t = goal.lowercased()
        return ["every ", "each ", "daily", "weekday", "weekly"].contains { t.contains($0) }
    }

    /// Ask the 7B to split a schedule request into a time trigger + the task to do
    /// (NL→structured, its strength). Returns nil if it's not actually a schedule.
    private func parseSchedule(_ goal: String) async -> (schedule: AutomationSchedule, task: String)? {
        let reply = await askModel("""
        The user said: "\(goal)"

        If this asks to SCHEDULE a recurring task, reply with ONLY this JSON:
        {"hour": <0-23>, "minute": <0-59>, "days": <[1-7] or null>, "task": "<the action, with scheduling words removed>"}
        (days: 1=Sunday … 7=Saturday; null = every day. "8am"→8, "6pm"→18, "morning"→8, "evening"→18.)
        If it is NOT a recurring/scheduled request, reply with ONLY: none
        """)
        for json in jsonObjectCandidates(in: reply) {
            guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let task = (o["task"] as? String), !task.isEmpty else { continue }
            let days = (o["days"] as? [Any])?.compactMap { Self.intArg($0) }
            let sched = AutomationSchedule(hour: max(0, min(23, Self.intArg(o["hour"]) ?? 8)),
                                           minute: max(0, min(59, Self.intArg(o["minute"]) ?? 0)),
                                           days: (days?.isEmpty ?? true) ? nil : days)
            return (sched, task)
        }
        return nil
    }

    /// SAVE-AND-SCHEDULE flow: parse the schedule, match+fill a recipe for the task,
    /// confirm ONCE (standing consent), and persist. Returns true if it handled the turn.
    private func saveScheduledAutomationIfRequested(goal: String, in conversation: Conversation) async -> Bool {
        guard let (schedule, task) = await parseSchedule(goal) else { return false }
        guard let recipe = await matchRecipe(goal: task) else {
            conversation.commitAssistantMessage("I can schedule things, but I don't have a recipe for “\(task)” yet."); return true
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

    /// Run a saved automation WITHOUT a card (standing consent granted at save time).
    /// `extra` carries trigger context (e.g. trigger_file = the new file's path) that
    /// substitutes into the body AFTER the recipe's own params.
    private func runAutomation(_ a: Automation, extra: [String: String] = [:]) async {
        guard let recipe = RecipeStore.shared.recipes.first(where: { $0.id == a.recipeId }) else {
            agentLog.error("automation \(a.name, privacy: .public): recipe \(a.recipeId, privacy: .public) missing"); return
        }
        let params = a.paramsJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var body = recipe.resolve(recipe.body, with: params)
        for (k, v) in extra { body = body.replacingOccurrences(of: "${\(k)}", with: v) }
        do {
            _ = try AppleScriptTool.shared.runScript(body)
            agentLog.info("automation \(a.name, privacy: .public): ran OK")
            await AuditLog.shared.record(tool: "automation:\(a.name)", argsJSON: a.paramsJSON, outcome: "ok", summary: recipe.title, confirmed: true)
        } catch {
            await AuditLog.shared.record(tool: "automation:\(a.name)", argsJSON: a.paramsJSON, outcome: "error", summary: error.localizedDescription, confirmed: true)
        }
    }

    // MARK: - Event triggers (Phase 6 — reactive automations)

    /// High-precision gate for "save an EVENT automation" turns: needs a
    /// when/whenever framing AND event vocabulary (file / app-open / Wi-Fi).
    /// (Precision over recall — a miss falls through to recipes/action-loop.)
    private func hasEventTriggerHint(_ goal: String) -> Bool {
        let t = goal.lowercased()
        guard ["when ", "whenever ", "any time ", "anytime "].contains(where: { t.contains($0) }) else { return false }
        return ["file", "pdf", "screenshot", "image", "png", "download", "appears in",
                "added to", "lands in", "saved to", "dropped in",
                "open", "launch", "start", "quit",
                "wifi", "wi-fi", "network", "connect", "join"].contains { t.contains($0) }
    }

    /// NL → {kind-specific trigger, task} via the local model (the same
    /// split-the-request pattern as parseSchedule). Nil = not an event-trigger request.
    private func parseEventTrigger(_ goal: String) async -> (trigger: AutomationTrigger, task: String)? {
        let reply = await askModel("""
        The user said: "\(goal)"

        If this asks to run a task WHENEVER AN EVENT happens (phrased like "when X happens, do Y"),
        reply with ONLY ONE of these JSON shapes. The event is the "when…" part; "task" is the do-Y part:
        - event: a file appears in a folder → {"kind": "fileAppears", "folder": "<e.g. ~/Downloads or ~/Desktop>", "ext": <"pdf"/"png"/etc or null for any file>, "task": "<the do-Y action>"}
          (screenshots land on ~/Desktop; downloads in ~/Downloads.)
        - event: the user opens/launches/starts an app → {"kind": "appLaunches", "app": "<that app's name>", "task": "<the do-Y action>"}
          (example: "when I open Mail, do Y" → {"kind": "appLaunches", "app": "Mail", "task": "do Y"})
        - event: joining a Wi-Fi network → {"kind": "wifiConnects", "ssid": <"the network name" or null for any network>, "task": "<the do-Y action>"}
        If it is NOT a when-X-do-Y request, reply with ONLY: none
        """)
        for json in jsonObjectCandidates(in: reply) {
            guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let task = o["task"] as? String, !task.isEmpty,
                  let kind = o["kind"] as? String else { continue }
            func str(_ k: String) -> String? {
                (o[k] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
            }
            switch kind {
            case "fileAppears":
                guard let folder = str("folder") else { continue }
                return (AutomationTrigger(kind: kind, folder: folder, ext: str("ext")), task)
            case "appLaunches":
                guard let app = str("app") else { continue }
                return (AutomationTrigger(kind: kind, app: app), task)
            case "wifiConnects":
                return (AutomationTrigger(kind: kind, ssid: str("ssid")), task)
            default:
                continue
            }
        }
        return nil
    }

    /// SAVE-AND-WATCH flow: parse the trigger, match+fill a recipe for the task,
    /// confirm ONCE (standing consent), persist, and start watching. Mirrors
    /// saveScheduledAutomationIfRequested. Returns true if it handled the turn.
    private func saveTriggeredAutomationIfRequested(goal: String, in conversation: Conversation) async -> Bool {
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

    /// Wire the TriggerEngine to the automation runner and start watching. The engine
    /// is event-driven (no polling); refresh() reconciles watchers with the store.
    private func startTriggerEngine() {
        TriggerEngine.shared.onFire = { [weak self] automation, extra in
            Task { @MainActor in
                await self?.runAutomation(automation, extra: extra)
                if !NotchController.shared.isPanelOpen {
                    NotificationsService.shared.notifyTaskComplete(body: "Ran automation: \(automation.name)")
                }
            }
        }
        TriggerEngine.shared.refresh()
    }

    /// PERMISSIONS TEST (`__permstest__`): log every TCC status non-interactively
    /// (Automation checked against Finder + System Events, no dialogs).
    private func runPermsTest() async {
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
    private func runTrigAppTest() {
        AutomationStore.shared.add(Automation(id: "trigapptest", name: "app-launch test", recipeId: "set-volume",
                                              paramsJSON: "{\"level\": 35}",
                                              trigger: AutomationTrigger(kind: "appLaunches", app: "Calculator")))
        TriggerEngine.shared.refresh()
        agentLog.info("trigapptest: watching for Calculator launch — open it to fire")
    }

    /// TRIGGER TEST (`__trigtest__`): watch /tmp/akari_trigger_test for new .png files
    /// and set volume to 25 when one appears — validates the reactive path end to end
    /// (watcher → engine match → runAutomation, no card, audited).
    private func runTrigTest() {
        let dir = "/tmp/akari_trigger_test"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        AutomationStore.shared.add(Automation(id: "trigtest", name: "trigger test", recipeId: "set-volume",
                                              paramsJSON: "{\"level\": 25}",
                                              trigger: AutomationTrigger(kind: "fileAppears", folder: dir, ext: "png")))
        TriggerEngine.shared.refresh()
        agentLog.info("trigtest: watching \(dir, privacy: .public) for .png — drop a file to fire")
    }

    /// Once-a-tick scheduler: run any enabled automation whose time is due (deduped per
    /// minute via `lastRunKey`). Started on launch.
    private func startScheduler() {
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tickScheduler() }
        }
        agentLog.info("scheduler: started (\(AutomationStore.shared.automations.count) automation(s))")
    }

    private func tickScheduler() async {
        let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: Date())
        guard let y = now.year, let mo = now.month, let d = now.day, let h = now.hour, let mi = now.minute else { return }
        let key = String(format: "%04d-%02d-%02d-%02d-%02d", y, mo, d, h, mi)
        for a in AutomationStore.shared.automations where a.enabled && a.lastRunKey != key {
            guard let s = a.schedule, s.isDue(now) else { continue }
            var updated = a; updated.lastRunKey = key
            AutomationStore.shared.replace(updated)
            agentLog.info("scheduler: firing \"\(a.name, privacy: .public)\" (\(s.describe, privacy: .public))")
            await runAutomation(a)
            if !NotchController.shared.isPanelOpen { NotificationsService.shared.notifyTaskComplete(body: "Ran automation: \(a.name)") }
        }
    }

    /// SCHEDULER TEST (`__schedtest__`): save a "set volume to 12" automation firing ~70s
    /// out (no card) and let the live scheduler pick it up — validates the tick loop.
    private func runSchedTest() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(70))
        AutomationStore.shared.add(Automation(id: "schedtest", name: "sched test", recipeId: "set-volume",
                                              paramsJSON: "{\"level\": 12}",
                                              schedule: AutomationSchedule(hour: c.hour ?? 0, minute: c.minute ?? 0, days: nil)))
        agentLog.info("schedtest: saved automation firing at \(c.hour ?? 0):\(c.minute ?? 0) — watch for the scheduler")
    }

    /// Run the full pointing pipeline against the frontmost app for `query`, no GUI
    /// needed — capture, enumerate AX, See turn with the pointing instruction; the
    /// dispatch logs the selected element + live frame (and draws the highlight).
    private func runPointingHarness(query: String, click: Bool = false) async {
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

    /// Pure-logic checks — the parser (every wrapper) + candidate ranking/dedup.
    /// Logs PASS/FAIL per case so the loop can grep the result. No GUI, no model.
    private func runSelfTest() {
        var pass = 0, fail = 0
        func check(_ name: String, _ cond: Bool) {
            cond ? (pass += 1) : (fail += 1)
            agentLog.info("selftest \(cond ? "PASS" : "FAIL", privacy: .public): \(name, privacy: .public)")
        }
        // parseToolCall — fenced, tagged, bare-with-prose, and prose-only.
        check("parse ```json fence", parseToolCall("```json\n{\"name\":\"point_at\",\"arguments\":{\"index\":3}}\n```")?.name == "point_at")
        check("parse <tool_call> tags", parseToolCall("<tool_call>{\"name\":\"point_at\",\"arguments\":{\"index\":3}}</tool_call>")?.name == "point_at")
        check("parse bare json + prose", ((parseToolCall("It's here: {\"name\":\"point_at\",\"arguments\":{\"index\":7}}")?.args["index"]) as? NSNumber)?.intValue == 7)
        check("parse prose-only → nil", parseToolCall("the back button is in the top-left") == nil)
        // intArg coercion — the 7B emits indices as a number OR a string.
        check("intArg number", Self.intArg(7 as NSNumber) == 7)
        check("intArg string", Self.intArg("16") == 16)
        check("intArg spaced string", Self.intArg(" 3 ") == 3)
        check("intArg garbage → nil", Self.intArg("nope") == nil)
        check("intArg nil → nil", Self.intArg(nil) == nil)
        check("parse+coerce string index", Self.intArg(parseToolCall("```json\n{\"name\":\"point_at\",\"arguments\":{\"index\":\"16\"}}\n```")?.args["index"]) == 16)
        check("parse brace inside string value", parseToolCall("{\"name\":\"point_at\",\"arguments\":{\"index\":3},\"note\":\"press }\"}")?.name == "point_at")
        // rankAndDedup — a button after static text ranks first; dupes removed.
        let f = CGRect(x: 0, y: 0, width: 10, height: 10)
        let syn = [
            AXElement(role: "AXStaticText", label: "Documents", frame: f, value: nil),
            AXElement(role: "AXStaticText", label: "Documents", frame: f, value: nil),                          // dupe
            AXElement(role: "AXStaticText", label: "Images", frame: CGRect(x: 20, y: 0, width: 10, height: 10), value: nil),
            AXElement(role: "AXButton", label: "Back", frame: CGRect(x: 40, y: 0, width: 10, height: 10), value: nil),
        ]
        let ranked = AccessibilityProbe.rankAndDedup(syn, limit: 25)
        check("rank: button first", ranked.first?.label == "Back")
        check("dedup: one Documents", ranked.filter { $0.label == "Documents" }.count == 1)
        check("dedup: count 3", ranked.count == 3)
        // promptAsksToPoint gating (#3 — only pointing turns send candidates/dispatch)
        check("asksToPoint where", promptAsksToPoint("where is the back button"))
        check("asksToPoint show me", promptAsksToPoint("show me the sidebar"))
        check("asksToPoint explain→false", !promptAsksToPoint("explain what's on screen"))
        check("asksToPoint haiku→false", !promptAsksToPoint("write a haiku about cats"))
        // candidate list: prompt indices align with element order + labels present
        let instr = pointAtToolInstruction(elements: [
            AXElement(role: "AXButton", label: "Back", frame: f, value: nil),
            AXElement(role: "AXTextField", label: "Search", frame: f, value: nil),
        ])
        check("instr [0] Back", instr.contains("[0] Button \"Back\""))
        check("instr [1] Search", instr.contains("[1] TextField \"Search\""))
        check("instr has decline path (-1)", instr.contains("index -1"))
        check("dispatch declines on -1", Self.intArg(-1 as NSNumber) == -1)   // -1 parses; dispatch guards idx<0
        check("instr empty→\"\"", pointAtToolInstruction(elements: []).isEmpty)
        // ToolRegistry (agent-loop foundation)
        check("registry has run_applescript", ToolRegistry.tool(named: "run_applescript") != nil)
        check("registry unknown → nil", ToolRegistry.tool(named: "nonexistent_tool_xyz") == nil)
        check("registry names nonempty", !ToolRegistry.names.isEmpty)
        check("registry excludes point_at", ToolRegistry.tool(named: "point_at") == nil)
        check("promptSpec names tool", ToolRegistry.tool(named: "run_applescript").map { ToolRegistry.promptSpec(for: [$0]).contains("run_applescript(") } ?? false)
        // Confirmation routing is the safety property: writes/deletes MUST be .confirm, reads .auto.
        check("reg create_reminder=confirm", ToolRegistry.tool(named: "create_reminder")?.confirmation == .confirm)
        check("reg list_reminders=auto", ToolRegistry.tool(named: "list_reminders")?.confirmation == .auto)
        check("reg delete_file=confirm", ToolRegistry.tool(named: "delete_file")?.confirmation == .confirm)
        check("reg move_file=confirm", ToolRegistry.tool(named: "move_file")?.confirmation == .confirm)
        check("reg read_file=auto", ToolRegistry.tool(named: "read_file")?.confirmation == .auto)
        check("reg write_file=confirm", ToolRegistry.tool(named: "write_file")?.confirmation == .confirm)   // preview before mutation
        check("reg draft_email=confirm", ToolRegistry.tool(named: "draft_email_reply")?.confirmation == .confirm)
        check("reg draft_imessage=confirm", ToolRegistry.tool(named: "draft_imessage")?.confirmation == .confirm)
        // Shortcuts tools (AGENTS.md Phase 0): trigger-by-name only, list is read-only.
        check("reg list_shortcuts=auto", ToolRegistry.tool(named: "list_shortcuts")?.confirmation == .auto)
        check("reg run_shortcut=confirm", ToolRegistry.tool(named: "run_shortcut")?.confirmation == .confirm)
        check("shortcut decode name", (try? ShortcutsTools.shared.decodeRun(#"{"name":"Morning Routine"}"#))?.name == "Morning Routine")
        check("shortcut decode missing → throws", (try? ShortcutsTools.shared.decodeRun(#"{"title":"x"}"#)) == nil)
        check("promptSpec names run_shortcut", ToolRegistry.promptSpec(for: ShortcutsTools.tools).contains("run_shortcut(name)"))
        // Conversation snapshots (persistence is TEXT-only; nothing saves until a real turn exists)
        let emptyConvo = Conversation(chatWithApp: "Test")
        check("snapshot empty → nil", emptyConvo.snapshot() == nil)
        let convo = Conversation(chatWithApp: "Test")
        convo.addUserMessage("What's on my calendar today?\nsecond line")
        convo.commitAssistantMessage("Three events.")
        convo.addToolChip(name: "read_calendar_events", inputJSON: "{}", content: "3 events", isError: false, displaySummary: "3 event(s)")
        let snap = convo.snapshot()
        check("snapshot exists", snap != nil)
        check("snapshot title = first user line", snap?.title == "What's on my calendar today?")
        check("snapshot keeps 3 rows", snap?.messages.count == 3)
        check("snapshot chip → tool row", snap?.messages.last?.toolName == "read_calendar_events")
        check("snapshot id stable", snap?.id == convo.persistentID)
        if let snap {
            let restored = Conversation.restore(from: snap)
            check("restore keeps id", restored.persistentID == convo.persistentID)
            check("restore keeps turns", restored.snapshot()?.messages.count == 3)
            check("restore visible count", restored.visibleMessages.count == convo.visibleMessages.count)
        }
        let longConvo = Conversation(chatWithApp: "")
        longConvo.addUserMessage(String(repeating: "x", count: 200))
        longConvo.commitAssistantMessage("ok")
        check("snapshot title capped 60", longConvo.snapshot()?.title.count == 60)
        // Memory — the remember/forget gates and the keyword scorer
        check("remember that → fact", parseRememberCommand("remember that Mary's email is mary@acme.com") == "Mary's email is mary@acme.com")
        check("remember my → fact", parseRememberCommand("remember my wifi is CasaDima") == "my wifi is CasaDima")
        check("remember to → nil (reminder!)", parseRememberCommand("remember to buy milk tomorrow") == nil)
        check("plain prompt → nil", parseRememberCommand("what's on my calendar") == nil)
        check("forget about → phrase", parseForgetCommand("forget about my wifi") == "my wifi")
        check("forget that → phrase", parseForgetCommand("forget that Mary thing") == "Mary thing")
        check("forget it → nil", parseForgetCommand("forget it") == nil)
        check("mem tokens keep names", MemoryStore.tokens("Mary's email is mary@acme.com").contains("mary"))
        check("mem tokens drop stopwords", !MemoryStore.tokens("remember that this is for you").contains("remember"))
        check("mem tokens drop short", !MemoryStore.tokens("go to it").contains("go"))
        check("mem preamble empty", MemoryStore.preamble(for: []).isEmpty)
        check("mem preamble bullets", MemoryStore.preamble(for: [MemoryFact(id: "1", content: "likes tea", createdAt: Date())]).contains("- likes tea"))
        // Automation edit — the time parser behind the Settings editor
        check("parseTime 18:30", AutomationSchedule.parseTime("18:30")?.hour == 18)
        check("parseTime 8:05 minute", AutomationSchedule.parseTime("8:05")?.minute == 5)
        check("parseTime pads back", AutomationSchedule(hour: 8, minute: 5, days: nil).timeText == "8:05")
        check("parseTime 24:00 → nil", AutomationSchedule.parseTime("24:00") == nil)
        check("parseTime 9:60 → nil", AutomationSchedule.parseTime("9:60") == nil)
        check("parseTime junk → nil", AutomationSchedule.parseTime("six pm") == nil)
        // Onboarding hardware bar (M1+/16 GB, PRODUCT.md: refuse, don't degrade)
        check("hw M1/16 ok", Onboarding.hardwareOK(memGB: 16, isAppleSilicon: true))
        check("hw M-series/8 refuse", !Onboarding.hardwareOK(memGB: 8, isAppleSilicon: true))
        check("hw intel/32 refuse", !Onboarding.hardwareOK(memGB: 32, isAppleSilicon: false))
        check("hw this Mac passes", Onboarding.hardwareOK(memGB: Onboarding.currentMemGB, isAppleSilicon: Onboarding.currentIsAppleSilicon))
        // Model storage — default base, override round-trip (restored after)
        let storedBase = UserDefaults.standard.string(forKey: "akari.models.base")
        UserDefaults.standard.removeObject(forKey: "akari.models.base")
        check("storage default = Documents/huggingface", ModelStorage.base.path.hasSuffix("Documents/huggingface"))
        UserDefaults.standard.set("/Volumes/Ext/huggingface", forKey: "akari.models.base")
        check("storage override honored", ModelStorage.base.path == "/Volumes/Ext/huggingface")
        if let storedBase { UserDefaults.standard.set(storedBase, forKey: "akari.models.base") }
        else { UserDefaults.standard.removeObject(forKey: "akari.models.base") }
        check("storage size readable", !ModelStorage.sizeDescription().isEmpty)   // 3.6 GB of models on this Mac
        // Function-call fallback: the 7B sometimes emits name(k="v") instead of JSON.
        check("fncall parses", parseToolCall("create_reminder(title=\"Call mom\", priority=\"high\")").map { $0.name == "create_reminder" && ($0.args["title"] as? String) == "Call mom" } ?? false)
        check("fncall prose→nil", parseToolCall("You can use open_url(url) to open a link.") == nil)
        check("fncall json intact", parseToolCall("{\"name\": \"list_files\", \"arguments\": {}}")?.name == "list_files")
        check("reminder priority word", (try? ReminderTools.shared.decodeCreateReminder(from: "{\"title\":\"x\",\"priority\":\"high\"}")).flatMap { $0.priority } == 1)
        // Tool-use chips (transcript transparency).
        let chipConv = Conversation(chatWithApp: "T")
        chipConv.addToolChip(name: "create_reminder", inputJSON: "{}", content: "ok", isError: false, displaySummary: "Reminder added")
        check("toolChip visible", chipConv.visibleMessages.contains { $0.toolUses.first?.name == "create_reminder" })
        check("toolChip result linked", chipConv.messages.compactMap { $0.toolUses.first?.id }.first.flatMap { chipConv.toolResult(forUseId: $0) } != nil)
        // Recipe engine (Phase 1) — pure logic: resolve + keyword prefilter.
        check("recipe resolve list", RecipeLibrary.all.first { $0.id == "quit-apps" }!.resolve("{${apps}}", with: ["apps": ["Mail", "Slack"]] as [String: Any]) == "{\"Mail\", \"Slack\"}")
        check("recipe resolve int", RecipeLibrary.all.first { $0.id == "set-volume" }!.resolve("vol ${level}", with: ["level": 30] as [String: Any]) == "vol 30")
        check("recipe prefilter music", RecipeLibrary.prefilter("pause my music").first?.id == "music-control")
        check("recipe prefilter volume", RecipeLibrary.prefilter("turn the volume down to 20").first?.id == "set-volume")
        check("recipe unwrap scalar-in-array", RecipeLibrary.all.first { $0.id == "set-volume" }!.resolve("v ${level}", with: ["level": [25]] as [String: Any]) == "v 25")
        check("recipe oneOf coerce bool", RecipeLibrary.all.first { $0.id == "dark-mode" }!.resolve("dm ${state}", with: ["state": 1] as [String: Any]) == "dm true")
        // File-loaded recipes: the .md frontmatter+body parser.
        let sampleMd = "---\nid: test-x\ntitle: Test recipe\nkeywords: foo, bar\nconfirm: Do ${n}\nparam: n | int | a number\n---\nset x to ${n}"
        let parsedRecipe = RecipeFile.parse(sampleMd)
        check("recipe .md parse id+param", parsedRecipe?.id == "test-x" && parsedRecipe?.params.first?.name == "n")
        check("recipe .md parse body", parsedRecipe?.body == "set x to ${n}")
        // Automation schedule logic.
        check("schedule isDue match", AutomationSchedule(hour: 9, minute: 30, days: nil).isDue(DateComponents(hour: 9, minute: 30)))
        check("schedule isDue miss", !AutomationSchedule(hour: 9, minute: 30, days: nil).isDue(DateComponents(hour: 9, minute: 31)))
        check("schedule describe pm", AutomationSchedule(hour: 18, minute: 0, days: nil).describe == "every day at 6:00 PM")
        // Agent-loop routing + result formatting
        check("asksToAct again", promptAsksToAct("look again at the screen"))
        check("asksToAct open", promptAsksToAct("open my downloads"))
        check("asksToAct calendar", promptAsksToAct("what's on my calendar this week"))
        check("asksToAct explain→false", !promptAsksToAct("explain what's on screen"))
        check("asksToAct describe→false", !promptAsksToAct("describe this window"))
        check("asksToAct desktop", promptAsksToAct("what's on my desktop"))   // the misroute we just fixed
        check("asksToAct applescript verb", promptAsksToAct("play some music"))
        check("asksToAct imperative", promptAsksToAct("lock my screen"))
        check("asksToAct filler→false", !promptAsksToAct("thanks"))
        check("toolResultText format", toolResultText("recapture_screen", "ok", isError: false).contains("[Tool result for recapture_screen]"))
        check("toolResultText error tag", toolResultText("x", "bad", isError: true).contains("(error)"))
        check("confirmTitle friendly", confirmTitle("create_calendar_event") == "Create calendar event?")
        check("confirmRows count", confirmRows(args: ["title": "X", "start_iso": "Y"]).count == 2)
        check("confirmRows drops empty", confirmRows(args: ["title": "X", "notes": ""]).count == 1)
        check("confirmRows applescript purpose-first", confirmRows(args: ["script": "tell app", "purpose": "do X"]).first?.label == "What it does")
        check("confirmRows truncates long", confirmRows(args: ["content": String(repeating: "x", count: 2000)]).first.map { $0.value.count < 1100 } ?? false)
        check("friendlyValue iso→local", !friendlyValue(key: "start_iso", raw: "2026-07-01T15:00:00+02:00").contains("T"))
        check("friendlyValue naked→local", !friendlyValue(key: "start_iso", raw: "2026-07-02T15:00").contains("T"))  // the 7B's zone-less form
        check("parseDate naked", CalendarTools.parseDate("2026-07-02T15:00") != nil)
        check("friendlyValue passthrough", friendlyValue(key: "title", raw: "Lunch") == "Lunch")
        check("sdef appName", AppleScriptDictionary.appName(in: "tell application \"Calculator\" to activate") == "Calculator")
        check("sdef appName none", AppleScriptDictionary.appName(in: "set x to 1") == nil)
        let sdefXML = "<class name=\"window\">\n<property name=\"index\" type=\"integer\"/>\n</class>\n<command name=\"close\"/>"
        check("sdef condense class", AppleScriptDictionary.condense(sdefXML, appName: "T").contains("class window: index (integer)"))
        check("sdef condense commands", AppleScriptDictionary.condense(sdefXML, appName: "T").contains("commands: close"))
        // Event triggers (Phase 6)
        check("trigHint when+pdf", hasEventTriggerHint("when a pdf lands in downloads, open it"))
        check("trigHint whenever+screenshot", hasEventTriggerHint("whenever I take a screenshot, move it"))
        check("trigHint no-when→false", !hasEventTriggerHint("open the pdf in downloads"))
        check("trigHint when-no-file→false", !hasEventTriggerHint("when I say go, set the volume to 20"))
        check("trigger describe ext", AutomationTrigger(kind: "fileAppears", folder: "~/Downloads", ext: "pdf").describe == "when a .pdf file appears in ~/Downloads")
        check("trigger describe any", AutomationTrigger(kind: "fileAppears", folder: "~/Desktop", ext: nil).describe == "when a file appears in ~/Desktop")
        check("watcher diff new", FolderWatcher.newEntries(known: ["a.pdf"], now: ["a.pdf", "b.pdf", ".DS_Store"]) == ["b.pdf"])
        check("watcher diff none", FolderWatcher.newEntries(known: ["a.pdf"], now: ["a.pdf"]).isEmpty)
        check("trigger ext match", TriggerEngine.matches(ext: "pdf", filename: "report.PDF"))
        check("trigger ext reject", !TriggerEngine.matches(ext: "pdf", filename: "photo.png"))
        check("trigger ext any", TriggerEngine.matches(ext: nil, filename: "anything.zip"))
        check("trigger expand ~", TriggerEngine.expand("~/Downloads").hasPrefix("/"))
        check("trigHint when+open-app", hasEventTriggerHint("when I open zoom, set the volume to 30"))
        check("trigHint when+wifi", hasEventTriggerHint("whenever I join my home wifi, open downloads"))
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
        // Permissions (TCC) helpers
        check("tellTargets multi+dedupe", PermissionsService.tellTargets(in:
            "tell application \"Music\" to play\ntell application \"Finder\" to activate\ntell application \"music\" to pause") == ["Music", "Finder"])
        check("tellTargets id form", PermissionsService.tellTargets(in: "tell application id \"com.apple.Music\" to play") == ["com.apple.Music"])
        check("tellTargets none", PermissionsService.tellTargets(in: "set volume output volume 20").isEmpty)
        check("mapAE granted", PermissionsService.mapAEStatus(noErr) == .granted)
        check("mapAE denied", PermissionsService.mapAEStatus(OSStatus(errAEEventNotPermitted)) == .denied)
        check("mapAE notRunning", PermissionsService.mapAEStatus(OSStatus(procNotFound)) == .unavailable("App not running"))
        check("settings url", PermissionsService.settingsURL(pane: "Privacy_Automation").absoluteString.hasSuffix("Privacy_Automation"))
        // Click path gating (click acts; point highlights — click checked first)
        check("asksToClick click", promptAsksToClick("click the send button"))
        check("asksToClick press", promptAsksToClick("press the OK button"))
        check("asksToClick tap", promptAsksToClick("tap the compose icon"))
        check("asksToClick where→false", !promptAsksToClick("where is the send button"))
        check("asksToClick explain→false", !promptAsksToClick("explain what's on screen"))
        check("asksToPoint click→false now", !promptAsksToPoint("click on the send button"))
        check("asksToPoint where still", promptAsksToPoint("where is the send button"))
        // Voice — transcript + spoken-reply cleanup
        check("stt clean brackets", SpeechService.clean("[BLANK_AUDIO] set the volume to 20 (silence)") == "set the volume to 20")
        check("stt clean tags", SpeechService.clean("<|startoftranscript|> click the send button") == "click the send button")
        check("stt clean plain", SpeechService.clean("  empty the trash  ") == "empty the trash")
        check("tts strip markdown", SpeechSynth.spokenForm("**Clicked** `Send` [link](x)") == "Clicked Send link")
        check("tts trims code", !SpeechSynth.spokenForm("hi ```swift\nlet x = 1\n``` bye").contains("let x"))
        check("tts caps length", SpeechSynth.spokenForm(String(repeating: "word. ", count: 500)).count <= 601)
        agentLog.info("selftest DONE: \(pass) pass, \(fail) fail")
    }

    /// DEBUG: drive the "working" comet for 8s WITHOUT a model turn, so its
    /// main-thread cost can be sampled in isolation — validates the Canvas rewrite
    /// of BorderComet (the fix for the inference-starving hang) without needing the
    /// 7B. Fire `__comet__`, then `sample $(pgrep -x Akari) 3` during the window.
    private func runCometProbe() async {
        agentLog.info("comet probe: ON for 8s (no model) — sample the process now")
        NotchController.shared.setWorking(true)
        try? await Task.sleep(for: .seconds(8))
        NotchController.shared.setWorking(false)
        agentLog.info("comet probe: OFF")
    }

    /// DEBUG: drive one metaball highlight (birth → morph → retract) with NO model,
    /// so the pointer animation's per-frame cost can be sampled — same TimelineView
    /// bug class as the comet; the metaball is the product centerpiece.
    private func runHighlightProbe() {
        let screen = PointingOverlay.currentScreen()
        let r = CGRect(x: screen.frame.midX - 60, y: screen.frame.midY - 24, width: 120, height: 48)
        agentLog.info("highlight probe: driving a sample highlight — sample the process now")
        MetaballPointer.shared.guide(steps: [GuideStep(rect: r, message: "Sample highlight")], on: screen)
    }

    /// DEBUG: dump the frontmost app's RAW AX tree (no filter) to the log — to see
    /// what Electron/Chromium apps actually expose under AXManualAccessibility.
    private func runAXTreeDump() {
        let front = NSWorkspace.shared.frontmostApplication
        let lines = AccessibilityProbe.rawTree(of: front?.bundleIdentifier)
        agentLog.info("AX raw tree — \(front?.localizedName ?? "?", privacy: .public) [\(front?.bundleIdentifier ?? "?", privacy: .public)] — \(lines.count) nodes:")
        for l in lines { agentLog.info("  \(l, privacy: .public)") }
    }
    #endif

    // MARK: - M3 de-risk: local tool calls (point_at)

    /// The point_at tool spec. We give the model a NUMBERED LIST of the real
    /// on-screen elements (from AX, each with an exact frame) and have it pick one
    /// by index — the local 7B is good at naming the right element but bad at
    /// estimating its coordinates, so AX supplies the geometry. Empty list (no AX,
    /// e.g. custom-drawn apps) → no pointing instruction at all.
    private func pointAtToolInstruction(elements: [AXElement]) -> String {
        guard !elements.isEmpty else { return "" }
        let list = elements.enumerated().map { i, e in
            let role = e.role.hasPrefix("AX") ? String(e.role.dropFirst(2)) : e.role
            return "[\(i)] \(role) \"\(e.label)\""
        }.joined(separator: "\n")
        return """
        # On-screen elements (each has an index)
        \(list)

        The user is asking you to point at something on screen. Reply with ONLY this JSON — no other text:
        {"name": "point_at", "arguments": {"index": <index>}}

        Use the index of the element that matches their request. Example — asked "where is the search field?" with `[3] TextField "Search"` in the list → {"name": "point_at", "arguments": {"index": 3}}.

        If NONE of the listed elements match what they asked for, use index -1 — do NOT force a wrong match:
        {"name": "point_at", "arguments": {"index": -1}}
        """
    }

    /// Does this prompt actually ask Akari to point at / locate something? Gates
    /// the (token-heavy) candidate list so it's only sent when pointing is wanted —
    /// not on a plain "explain this screen" turn. ("click"/"press"/"tap" now route
    /// to the CLICK path — checked before this gate.)
    private func promptAsksToPoint(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["where", "point at", "point to", "show me", "find the", "locate",
                "highlight", "which"].contains { t.contains($0) }
    }

    /// Does this prompt ask Akari to actually PRESS something on screen? Routes to
    /// the click path: same select-by-index as pointing, then highlight → confirm
    /// card → AXPress. Checked BEFORE promptAsksToPoint.
    private func promptAsksToClick(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["click", "press the", "press on", "tap ", "tap the", "push the button",
                "hit the button"].contains { t.contains($0) }
    }

    /// Parse the reply for a `<tool_call>{…}</tool_call>` block; if it's a point_at,
    /// run it: capture-pixel point → screen, AX hit-test there for the exact element
    /// ("vision points, AX pins"), and outline it (small box if AX finds nothing).
    /// Returns true iff it highlighted an element. The caller shows a fallback
    /// message when this is false (no call / bad index / model declined).
    @discardableResult
    private func dispatchPointAtIfPresent(_ text: String, conversation: Conversation) -> Bool {
        guard let call = parseToolCall(text), call.name == "point_at" else {
            // Diagnostics: show the reply tail so we can tell whether the model
            // skipped the call, malformed it, or pointed in prose instead.
            agentLog.info("runTurn: no point_at parsed. reply tail=\"\(String(text.suffix(200)), privacy: .public)\"")
            return false
        }
        // AX-select: the model picked an element index from the candidate list we
        // gave it; highlight that element's EXACT frame. No coordinate path — the
        // local 7B can't localize, and AX already supplies the geometry.
        guard let idx = Self.intArg(call.args["index"]) else {
            agentLog.info("runTurn: point_at without an index (args: \(call.args.keys.sorted().joined(separator: ","), privacy: .public))")
            return false
        }
        if idx < 0 {   // model's "none of these match" sentinel — decline gracefully, no highlight
            agentLog.info("runTurn: model declined (index -1) — no element matched the request")
            return false
        }
        guard conversation.axElements.indices.contains(idx) else {
            agentLog.info("runTurn: point_at index \(idx) out of range (0..<\(conversation.axElements.count))")
            return false
        }
        let el = conversation.axElements[idx]
        let frame = AccessibilityProbe.liveFrame(of: el) ?? el.frame   // re-read NOW so a reflow during inference can't stale it
        let screen = conversation.captureScreen ?? PointingOverlay.currentScreen()
        agentLog.info("runTurn: point_at index \(idx) → \(el.role, privacy: .public) \"\(el.label, privacy: .public)\" live(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))×\(Int(frame.height))) snapshot(\(Int(el.frame.minX)),\(Int(el.frame.minY)))")
        MetaballPointer.shared.guide(steps: [GuideStep(rect: frame, message: el.label)], on: screen)
        return true
    }

    /// CLICK dispatch: same select-by-index as pointing, but the selection is ACTED
    /// on — highlight the element (so the user sees exactly what will be pressed),
    /// suspend on a confirm card, then AXPress (synthetic-click fallback), audit, chip.
    /// Returns true iff it handled the turn (clicked, failed-with-message, or the
    /// user declined). False = nothing selected; the caller shows "I don't see that."
    @discardableResult
    private func dispatchClickIfPresent(_ text: String, conversation: Conversation, autoApprove: Bool = false) async -> Bool {
        guard let call = parseToolCall(text), call.name == "point_at",
              let idx = Self.intArg(call.args["index"]) else {
            agentLog.info("click: no selection parsed. reply tail=\"\(String(text.suffix(200)), privacy: .public)\"")
            return false
        }
        if idx < 0 {
            agentLog.info("click: model declined (index -1) — no element matched")
            return false
        }
        guard conversation.axElements.indices.contains(idx) else {
            agentLog.info("click: index \(idx) out of range (0..<\(conversation.axElements.count))")
            return false
        }
        let el = conversation.axElements[idx]
        let role = el.role.hasPrefix("AX") ? String(el.role.dropFirst(2)) : el.role
        let frame = AccessibilityProbe.liveFrame(of: el) ?? el.frame
        let screen = conversation.captureScreen ?? PointingOverlay.currentScreen()
        agentLog.info("click: index \(idx) → \(el.role, privacy: .public) \"\(el.label, privacy: .public)\" live(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))×\(Int(frame.height)))")
        // Show what will be clicked WHILE the card is up.
        MetaballPointer.shared.guide(steps: [GuideStep(rect: frame, message: el.label)], on: screen)

        let approved: Bool
        if autoApprove {
            approved = true   // DEBUG harness only (__clicktest__)
        } else {
            approved = await awaitConfirmation(in: conversation, title: "Click this?",
                                               rows: [("Element", "\(role) “\(el.label)”")],
                                               label: "click_element", destructive: false)
            if Task.isCancelled { return true }
        }
        guard approved else {
            conversation.commitAssistantMessage("Okay — I won't click it.")
            return true
        }
        let result = AccessibilityProbe.press(el)
        agentLog.info("click: press → \(result.label, privacy: .public)")
        await AuditLog.shared.record(tool: "click_element",
                                     argsJSON: "{\"element\": \"\(el.label)\", \"role\": \"\(role)\", \"method\": \"\(result.label)\"}",
                                     outcome: result.succeeded ? "ok" : "error",
                                     summary: "Click “\(el.label)”", confirmed: !autoApprove)
        if result.succeeded {
            conversation.addToolChip(name: "click_element", inputJSON: "{}",
                                     content: "Clicked “\(el.label)” (\(result.label))", isError: false,
                                     displaySummary: "Clicked “\(el.label)”")
            conversation.commitAssistantMessage("Clicked “\(el.label)”.")
        } else {
            conversation.commitAssistantMessage("I found “\(el.label)” but couldn't click it (\(result.label)).")
        }
        return true
    }

    /// Pull a tool-call JSON object out of the reply, however the model wrapped it
    /// — `<tool_call>` tags, a ```json fence, or bare JSON. The local 7B is
    /// inconsistent about the wrapper (Qwen 2.5 favors a ```json fence), so we
    /// ignore the wrapper entirely and scan for the JSON object itself.
    private func parseToolCall(_ text: String) -> (name: String, args: [String: Any])? {
        for json in jsonObjectCandidates(in: text) {
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["name"] as? String else { continue }
            return (name, (obj["arguments"] as? [String: Any]) ?? [:])
        }
        return parseFunctionCall(text)   // the 7B sometimes emits name(k="v", …) instead of JSON
    }

    /// Fallback for the Python-function-call syntax the local 7B sometimes emits
    /// instead of JSON — `create_reminder(title="Call mom", priority="high")`.
    /// Anchored on KNOWN tool names (earliest occurrence wins) so free prose can't
    /// false-match; the paren scan is string-aware (quoted commas/parens are safe).
    private func parseFunctionCall(_ text: String) -> (name: String, args: [String: Any])? {
        // Require the response to BE the call (start with a known name( after any
        // opening code fence) — so prose that merely mentions "open_url(...)" can't misfire.
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```"), let nl = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let known = ToolRegistry.names + ["point_at", "recapture_screen"]
        guard let name = known.first(where: { t.hasPrefix($0 + "(") }) else { return nil }
        let start = t.index(t.startIndex, offsetBy: name.count + 1)
        var depth = 1, inString = false, escaped = false, quote: Character = "\""
        var body = ""
        for c in t[start...] {
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == quote { inString = false }
                body.append(c); continue
            }
            if c == "\"" || c == "'" { inString = true; quote = c; body.append(c); continue }
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1; if depth == 0 { break } }
            body.append(c)
        }
        return (name, parseKeyValueArgs(body))
    }

    /// `key="value", key2=123, key3=true` → dict, respecting quoted commas and
    /// coercing bare numbers/bools. Quoted values stay strings (unescaped).
    private func parseKeyValueArgs(_ s: String) -> [String: Any] {
        var parts: [String] = [], cur = ""
        var inString = false, escaped = false, quote: Character = "\""
        for c in s {
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == quote { inString = false }
                cur.append(c); continue
            }
            if c == "\"" || c == "'" { inString = true; quote = c; cur.append(c); continue }
            if c == "," { parts.append(cur); cur = ""; continue }
            cur.append(c)
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur) }

        var args: [String: Any] = [:]
        for part in parts {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces)
            let val = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !val.isEmpty else { continue }
            if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")), val.count >= 2 {
                args[key] = String(val.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
            } else if val == "true" || val == "false" { args[key] = (val == "true") }
            else if let i = Int(val) { args[key] = i }
            else if let d = Double(val) { args[key] = d }
            else { args[key] = val }
        }
        return args
    }

    /// Every balanced `{…}` substring, longest first — so the outermost object
    /// (the one carrying name+arguments) is tried before any nested object. Good
    /// enough for tool calls; doesn't special-case braces inside string values.
    private func jsonObjectCandidates(in text: String) -> [String] {
        let chars = Array(text)
        var results: [String] = []
        var stack: [Int] = []
        var inString = false, escaped = false
        for (i, c) in chars.enumerated() {
            if inString {                       // ignore braces/quotes inside a JSON string value
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": stack.append(i)
            case "}": if let start = stack.popLast() { results.append(String(chars[start...i])) }
            default: break
            }
        }
        return results.sorted { $0.count > $1.count }
    }

    /// Coerce a tool-call argument to Int. The local 7B is inconsistent about JSON
    /// types — it sometimes emits a number as a string (`"index": "16"`), which a
    /// plain `as? NSNumber` would silently drop. Accept number, string, or a
    /// stray-whitespace string.
    static func intArg(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
