import AppKit
import OSLog

// Hold-to-talk: record, transcribe on device, and hand the text to the agent loop.

extension AppDelegate {
    /// Key-down: start on-device recording (WhisperKit). First use prompts for Mic.
    func beginVoiceCapture() async {
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
    func endVoiceCaptureAndRun() async {
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
    func handleVoiceCommand(transcript: String) async {
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
    }
}
