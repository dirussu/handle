import AppKit
import OSLog

// Capturing the screen or a window, and deciding when a message is about what is on screen.

extension AppDelegate {
    /// Force-enable accessibility on each app as it comes to the foreground, so
    /// Chromium/Electron apps have their a11y tree BUILT before we ever capture or
    /// hit-test them — no warm-up. Native apps ignore it. Also primes whatever's
    /// frontmost right now.
    func setupAccessibilityPriming() {
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

    @objc func triggerCaptureFullScreen() {
        handleCapture()
    }

    // Region capture (drag-to-select) REMOVED — See is
    // ambient full-screen; a second capture concept wasn't earning its keep.
    func handleCapture() {
        guard !isPresentingOverlay else { return }
        isPresentingOverlay = true

        // Cancel any in-flight conversation when a new capture starts.
        activeTask?.cancel()
        activeTask = nil

        let task = Task { @MainActor in
            defer { isPresentingOverlay = false }

            // Snapshot frontmost app BEFORE overlay shows (overlay temporarily activates Handle).
            let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "(unknown)"
            let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            print("[Handle] Frontmost app: \(frontmostApp) (\(frontmostBundleID ?? "?"))")

            // No privacy exclude-list: Handle is local and captures are
            // ephemeral (never written to disk, never sent off-device), so
            // there's nothing to protect against by refusing to look.

            // Pick the screen under the cursor.
            let cursor = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else {
                print("[Handle] No screen for cursor at \(cursor)")
                return
            }

            // 1. The capture rect: the full screen under the cursor.
            let captureRect = CGRect(origin: .zero, size: screen.frame.size)
            print("[Handle] Capture: \(Int(captureRect.width))×\(Int(captureRect.height)) pt")

            // 2. Capture pixels, then downsample for the API.
            let rawImage: CGImage
            do {
                rawImage = try await ScreenCapture.captureRegion(captureRect, on: screen)
                print("[Handle] Captured \(rawImage.width)×\(rawImage.height)px (raw)")
            } catch {
                print("[Handle] Capture failed: \(error)")
                return
            }
            let prepared = ImagePreparation.prepareForAPI(rawImage)
            let image = prepared.image
            let imagePixelSize = prepared.pixelSize
            print("[Handle] Prepared for API: \(Int(imagePixelSize.width))×\(Int(imagePixelSize.height))px")

            // 3a. Probe AX tree for ground-truth element coordinates (synchronous, fast).
            let axElements = AccessibilityProbe.elements(
                in: captureRect,
                of: frontmostBundleID,
                limit: 25
            )
            print("[Handle] AX elements found: \(axElements.count)")
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
    /// under the cursor), excluding Handle's own windows, and stage it as the
    /// context for this turn. Local + ephemeral: the pixels go to the on-device
    /// model and are discarded; nothing is written to disk or sent anywhere,
    /// which is why no privacy exclude-list is needed.
    func captureCurrentScreen(into conversation: Conversation) async -> (image: CGImage, pixelSize: CGSize)? {
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else {
            return nil
        }
        // Excluded app in front → no pixels at all (not "captured but not sent").
        let front = NSWorkspace.shared.frontmostApplication
        let frontID = front?.bundleIdentifier ?? conversation.originalBundleID
        let frontName = front?.localizedName ?? conversation.appName
        if SeeSettings.isExcluded(frontID) {
            agentLog.info("capture: skipped — \(frontName, privacy: .public) (\(frontID ?? "?", privacy: .public)) is excluded")
            conversation.captureWithheld = .withheldExcluded(app: frontName)
            return nil
        }
        conversation.capturedAppName = frontName
        conversation.capturedBundleID = frontID
        let rect = CGRect(origin: .zero, size: screen.frame.size)
        do {
            let raw = try await ScreenCapture.captureRegion(rect, on: screen)
            let prepared = ImagePreparation.prepareForAPI(raw)
            // Re-enumerate the target app's AX elements for THIS capture — the model
            // selects one by index to point at. Handle is frontmost on a follow-up,
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

    /// Ambient-sight router for a typed turn. Decides what (if anything) Handle
    /// looks at, and what machine context the model receives:
    ///  1. Prompt names an OPEN WINDOW ("the error in Xcode") → capture that
    ///     exact window, even buried behind others or on another display.
    ///  2. Prompt references the screen generically ("what's this?") → capture
    ///     the visible display under the cursor.
    ///  3. Prompt asks about the machine ("what apps do I have open?") → no
    ///     screenshot, but pass the window manifest so Handle can answer.
    ///  4. Self-contained ("write a haiku") → no capture, no manifest, text speed.
    ///
    /// The manifest is a cheap system query (no pixels), so we always build it
    /// to detect window references; only the pixel capture in (1)/(2) costs a
    /// vision turn. This is the heuristic stage; M3's tool-use will let the
    /// model request a specific window itself.
    func handleAmbientTurn(text: String, in conversation: Conversation) async {
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
        // A capture skipped for an excluded app: caption under the bubble + a
        // note to the model so the reply says so instead of guessing.
        if let withheld = conversation.takeCaptureWithheld(), case .withheldExcluded(let app) = withheld {
            conversation.markScreenshot(withheld)
            let note = SeeSettings.excludedNote(app: app)
            conversation.pendingContextPreamble += (conversation.pendingContextPreamble.isEmpty ? "" : "\n\n") + note
        }
    }

    /// Capture one specific (possibly occluded) window and stage it as this
    /// turn's context. Ephemeral, like the full-screen path.
    func captureWindow(_ window: WindowInfo, into conversation: Conversation) async -> (image: CGImage, pixelSize: CGSize)? {
        let bundleID = SeeSettings.bundleID(forRunningAppNamed: window.appName)
        if SeeSettings.isExcluded(bundleID) {
            agentLog.info("capture: window skipped — \(window.appName, privacy: .public) is excluded")
            conversation.captureWithheld = .withheldExcluded(app: window.appName)
            return nil
        }
        conversation.capturedAppName = window.appName
        conversation.capturedBundleID = bundleID
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
}
