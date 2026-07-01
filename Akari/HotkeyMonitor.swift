import AppKit
import ApplicationServices

/// Detects a fast double-tap of the ⌥ (Option) key with no other modifiers held.
/// Requires Accessibility permission for global flagsChanged events.
final class HotkeyMonitor {
    private let onDoubleTap: () -> Void
    private let interval: TimeInterval = 0.30

    private var globalMonitor: Any?
    private var lastOptionDownAt: Date?

    init(onDoubleTap: @escaping () -> Void) {
        self.onDoubleTap = onDoubleTap
    }

    func start() {
        ensureAccessibility()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        if globalMonitor == nil {
            print("[Akari] Failed to install global monitor (Accessibility permission likely missing).")
        } else {
            print("[Akari] Hotkey monitor active. Double-tap ⌥.")
        }
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Detection

    private func handle(_ event: NSEvent) {
        // 58 = left option, 61 = right option
        guard event.keyCode == 58 || event.keyCode == 61 else { return }

        // Reject if any non-option modifier is held
        let nonOption = event.modifierFlags.intersection([.command, .shift, .control, .capsLock, .function])
        guard nonOption.isEmpty else { resetTimer(); return }

        // We only fire on transition-to-pressed (option flag now ON)
        let optionPressed = event.modifierFlags.contains(.option)
        guard optionPressed else { return }

        let now = Date()
        if let last = lastOptionDownAt, now.timeIntervalSince(last) < interval {
            lastOptionDownAt = nil
            onDoubleTap()
        } else {
            lastOptionDownAt = now
        }
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
