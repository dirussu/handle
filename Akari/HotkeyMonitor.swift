import AppKit
import ApplicationServices

/// The ⌥ key is Akari's key. This monitor detects BOTH gestures on it:
/// - **double-tap** ⌥ (two quick presses, no other modifiers) → capture
/// - **hold** ⌥ alone (≥ holdThreshold, founder call 2026-07-10: "simpler
///   than a chord") → push-to-talk; release ends the capture.
///
/// Hold safety: normal ⌥ usage is chords (⌥-arrow, ⌥-letters) and ⌥-drag —
/// so a pending hold cancels the INSTANT any key, click, or scroll happens,
/// and a press that completed a double-tap never becomes a hold (that press
/// belongs to capture). Requires Accessibility for global monitors.
final class HotkeyMonitor {
    private let onDoubleTap: () -> Void
    private let onHoldBegan: () -> Void
    private let onHoldEnded: () -> Void
    private let interval: TimeInterval = 0.30
    private let holdThreshold: TimeInterval = 0.45

    private var flagsMonitor: Any?
    private var cancelMonitor: Any?
    private var lastOptionDownAt: Date?
    private var pendingHold: DispatchWorkItem?
    private var isHolding = false
    private var suppressHold = false   // this ⌥ press already fired the double-tap

    init(onDoubleTap: @escaping () -> Void,
         onHoldBegan: @escaping () -> Void,
         onHoldEnded: @escaping () -> Void) {
        self.onDoubleTap = onDoubleTap
        self.onHoldBegan = onHoldBegan
        self.onHoldEnded = onHoldEnded
    }

    func start() {
        ensureAccessibility()
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        // Any concurrent input means the ⌥ press is a chord/drag, not a hold.
        cancelMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] _ in
            self?.cancelPendingHold()
        }
        if flagsMonitor == nil {
            print("[Akari] Failed to install global monitor (Accessibility permission likely missing).")
        } else {
            print("[Akari] Hotkey monitor active. Double-tap ⌥ to capture, hold ⌥ to talk.")
        }
    }

    deinit {
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        if let m = cancelMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Detection

    private func handle(_ event: NSEvent) {
        // 58 = left option, 61 = right option
        guard event.keyCode == 58 || event.keyCode == 61 else { return }

        // Reject if any non-option modifier is held
        let nonOption = event.modifierFlags.intersection([.command, .shift, .control, .capsLock, .function])
        guard nonOption.isEmpty else {
            resetTimer()
            cancelPendingHold()
            return
        }

        let optionPressed = event.modifierFlags.contains(.option)
        guard optionPressed else {
            // ⌥ released: end an active hold, or discard a pending one.
            cancelPendingHold()
            suppressHold = false
            if isHolding {
                isHolding = false
                onHoldEnded()
            }
            return
        }

        // ⌥ pressed. Double-tap first — its second press must never become a hold.
        let now = Date()
        if let last = lastOptionDownAt, now.timeIntervalSince(last) < interval {
            lastOptionDownAt = nil
            suppressHold = true
            onDoubleTap()
            return
        }
        lastOptionDownAt = now

        // Arm the hold: fires only if ⌥ is still down alone when the timer lands.
        suppressHold = false
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.suppressHold else { return }
            self.pendingHold = nil
            self.isHolding = true
            self.onHoldBegan()
        }
        pendingHold?.cancel()
        pendingHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
    }

    private func cancelPendingHold() {
        pendingHold?.cancel()
        pendingHold = nil
    }

    private func resetTimer() {
        lastOptionDownAt = nil
    }

    // MARK: - Permissions

    private func ensureAccessibility() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("[Akari] Accessibility permission required. Prompting…")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }
}
