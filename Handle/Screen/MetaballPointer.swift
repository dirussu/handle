import AppKit
import Combine
import SwiftUI
import os.log


/// One stop in a guided walkthrough: a screen-space rect to outline + its message.
/// (Screen points, top-left origin — already mapped from the capture's pixels by
/// the time it reaches the pointer.)
struct GuideStep {
    let rect: CGRect
    let message: String
}

/// Handle's pointer — a black circle that is BORN out of the notch with a gooey
/// metaball "spit-out": a bump forms on the panel's bottom edge, stretches down
/// into a circle, the neck thins and snaps, and the circle settles just below.
/// Built on the blur + alpha-threshold metaball trick.
///
/// Full-screen, click-through overlay. (Flying it to a target to actually point
/// at things is the next phase; this nails the birth.)
/// Bridges controller → view for externally-ended runs (listening): flipping
/// `ending` tells the view to play the reverse suck and dismiss.
@MainActor
final class PointerSession: ObservableObject {
    @Published var ending = false
}

@MainActor
final class MetaballPointer {
    static let shared = MetaballPointer()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var listenSession: PointerSession?
    private init() {}

    /// Drive a guided walkthrough: the pointer is born from the notch, its glowing
    /// outline morphs through each step's rect (showing the message), then it
    /// retracts back into the notch. `steps` are in screen points (top-left) on
    /// `screen` — already mapped from capture pixels by the caller.
    func guide(steps: [GuideStep], on screen: NSScreen) {
        present(steps: steps, on: screen)
    }

    /// LISTENING: the same birth, but instead of turning into the glowing ring the
    /// droplet stays black with the dictation bars inside. Ends via stopListening()
    /// → the same reverse suck as the walkthrough.
    func listen(on screen: NSScreen) {
        agentLog.info("pointer: listen()")
        let session = PointerSession()
        listenSession = session
        present(steps: [], on: screen, listening: true, session: session)
    }

    func stopListening() {
        agentLog.info("pointer: stopListening session=\(self.listenSession == nil ? "nil!" : "live", privacy: .public)")
        listenSession?.ending = true
        listenSession = nil
    }

    private func present(steps: [GuideStep], on screen: NSScreen,
                         listening: Bool = false, session: PointerSession? = nil) {
        clear()

        let panel = ClickThroughPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Sit JUST BELOW the notch window (mainMenu+3) so the pill/panel OCCLUDES
        // the hidden reservoir and the droplet's in-surface start — only the part
        // that clears the bottom edge shows, oozing out from under the surface.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        // Anchor at the surface's CURRENT bottom edge (the open panel's bottom
        // if open, the closed-notch bottom otherwise), bottom-center.
        let anchor = CGPoint(x: screen.frame.width / 2,
                             y: NotchController.shared.panelBottomY(on: screen))

        let view = MetaballPointerView(
            anchor: anchor,
            steps: steps,
            screenSize: screen.frame.size,
            onFinished: { [weak self] in self?.fadeOut() },  // retracted into the notch — dismiss
            listening: listening,
            session: session ?? PointerSession()
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel

        hideTask = Task { @MainActor [weak self] in
            // SAFETY fallback only — the walkthrough/listening run dismisses itself
            // (`onFinished`). This just guarantees the overlay never gets stuck.
            // Listening is user-paced (a long dictation), so give it far longer.
            try? await Task.sleep(for: .seconds(listening ? 130 : 22))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func clear() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.clear()
        })
    }
}

// MARK: - The metaball view
