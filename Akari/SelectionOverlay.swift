import AppKit

/// Full-screen drag-to-select overlay. Returns the selected rect in display
/// top-left coordinates (in points), or nil if cancelled.
@MainActor
final class SelectionOverlay {
    private var panel: SelectionPanel?
    private var view: SelectionView?
    private var continuation: CheckedContinuation<CGRect?, Never>?
    // (priorActivationPolicy removed — we no longer toggle the policy;
    // see comment in `present(on:)`.)

    /// Present overlay on `screen`, await user's selection.
    /// Returns the rect in top-left display coords (suitable for SCStreamConfiguration.sourceRect),
    /// or nil if cancelled.
    func present(on screen: NSScreen) async -> CGRect? {
        // Activate the app (bring to front) WITHOUT changing the activation
        // policy. Toggling .accessory ↔ .regular every time the user
        // captures was the cause of the duplicate-menubar-icon symptoms
        // (and a known instability point on recent macOS releases). The
        // overlay panel already runs at CGShieldingWindowLevel and uses a
        // SelectionPanel subclass that overrides `canBecomeKey` — that's
        // sufficient to own the mouse and keyboard from an .accessory app.
        NSApp.activate(ignoringOtherApps: true)

        let panel = SelectionPanel(
            contentRect: screen.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above screen-saver / system shields — highest practical level on macOS.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onComplete = { [weak self] rectInView in
            let topLeft = CGRect(
                x: rectInView.minX,
                y: screen.frame.height - rectInView.maxY,
                width: rectInView.width,
                height: rectInView.height
            )
            self?.finish(with: topLeft)
        }
        view.onCancel = { [weak self] in
            self?.finish(with: nil)
        }

        panel.contentView = view
        panel.makeFirstResponder(view)
        panel.makeKeyAndOrderFront(nil)

        NSCursor.crosshair.push()

        self.panel = panel
        self.view = view

        return await withCheckedContinuation { (cont: CheckedContinuation<CGRect?, Never>) in
            self.continuation = cont
        }
    }

    private func finish(with rect: CGRect?) {
        NSCursor.pop()
        panel?.orderOut(nil)
        panel = nil
        view = nil

        // No activation-policy restore needed — we never changed it.

        let cont = continuation
        continuation = nil
        cont?.resume(returning: rect)
    }
}

/// NSPanel subclass that can become key without activating the app.
final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// View that handles mouse drag + ESC cancel and draws the dimmed overlay
/// with a "spotlight" cutout for the current selection.
final class SelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentRect: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = Self.rect(from: start, to: current)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil }
        guard let rect = currentRect, rect.width >= 8, rect.height >= 8 else {
            // Treat tiny drags / single clicks as cancel
            onCancel?()
            return
        }
        onComplete?(rect)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // ESC
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Keep the screen at full clarity. Clear any leftover pixels in the dirty rect.
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        guard let rect = currentRect, rect.width > 0, rect.height > 0 else { return }

        // Selection border (Akari yellow)
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.20, alpha: 1.0).setStroke()
        border.stroke()

        // Size label — frosted dark pill below (or above) the selection
        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = label.size(withAttributes: attrs)
        let padX: CGFloat = 8
        let padY: CGFloat = 4
        let bgWidth = labelSize.width + padX * 2
        let bgHeight = labelSize.height + padY * 2
        let labelBgRect: NSRect
        if rect.minY - bgHeight - 6 > 0 {
            labelBgRect = NSRect(x: rect.minX, y: rect.minY - bgHeight - 6, width: bgWidth, height: bgHeight)
        } else {
            labelBgRect = NSRect(x: rect.minX, y: rect.maxY + 6, width: bgWidth, height: bgHeight)
        }
        let radius = bgHeight / 2
        let pill = NSBezierPath(roundedRect: labelBgRect, xRadius: radius, yRadius: radius)
        NSColor(white: 0.05, alpha: 0.78).setFill()
        pill.fill()
        let pillStroke = NSBezierPath(roundedRect: labelBgRect, xRadius: radius, yRadius: radius)
        pillStroke.lineWidth = 0.5
        NSColor.white.withAlphaComponent(0.15).setStroke()
        pillStroke.stroke()
        label.draw(at: NSPoint(x: labelBgRect.minX + padX, y: labelBgRect.minY + padY), withAttributes: attrs)
    }

    // MARK: - Helpers

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}
