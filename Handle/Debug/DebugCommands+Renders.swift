import SwiftUI
import AppKit
import OSLog

// Debug commands that render or probe the interface.

#if DEBUG

extension AppDelegate {
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
