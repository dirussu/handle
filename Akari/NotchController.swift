import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating panel that hosts the notch surface. Adapted
/// from Boring Notch's window config. Can become key (so the open panel's
/// text field receives input) but never main, and never activates the app.
/// Stays interactive in all states — like Boring Notch, the empty SwiftUI
/// space below the pill simply doesn't hit-test, so clicks fall through to
/// apps behind it without any `ignoresMouseEvents` juggling.
final class NotchWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // Force dark appearance regardless of system setting (Boring Notch
        // does the same) so the black surface + controls render consistently.
        appearance = NSAppearance(named: .darkAqua)
        // NOTE: Space transitions render all-Spaces windows LIVE in BOTH sliding
        // space trees — no window level opts out (dragging level tested, failed;
        // founder video evidence). The fix lives in NotchRootView instead: the
        // closed pill paints NOTHING on a hardware notch, so there is nothing to
        // slide. Level stays just above the menu bar.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A completed result, shown in the notch notification center until
/// acknowledged. `text` is the full result; `date` stamps when it finished.
struct AkariNotification: Identifiable {
    let id = UUID()
    let text: String
    let date: Date
}

/// Owns one notch surface PER display, plus the shared assistant state. The
/// same Akari conversation is mirrored on every screen; each display opens /
/// closes independently (hover/interaction lives in `NotchRootView`).
@MainActor
final class NotchController {
    static let shared = NotchController()

    private let openWidth: CGFloat = 600
    private let windowWidth: CGFloat = 740
    private let windowHeight: CGFloat = 760

    /// One notch (window + view model) per display.
    private final class DisplayNotch {
        let displayID: CGDirectDisplayID
        let window: NotchWindow
        let vm: NotchViewModel
        init(displayID: CGDirectDisplayID, window: NotchWindow, vm: NotchViewModel) {
            self.displayID = displayID
            self.window = window
            self.vm = vm
        }
    }
    private var notches: [DisplayNotch] = []

    // Shared "one Akari brain" state, broadcast to every display's view model.
    private var conversation: Conversation?
    private var onSubmit: (String) -> Void = { _ in }
    private var onAddPDF: () -> Void = {}
    private var working = false
    /// Wired once by the app at launch; survives every present()/rebuild().
    var onOpenSaved: (String) -> Void = { _ in }
    /// New chat — the app swaps in a fresh blank conversation and opens it.
    var onNewChat: () -> Void = {}
    /// Settings → Automations "Run now".
    var onRunAutomation: (Automation) -> Void = { _ in }
    /// Stop — cancel the running turn (send button becomes Stop while working).
    var onStop: () -> Void = {}

    // Pending completion notifications (the pill below the closed notch).
    private var notifications: [AkariNotification] = []
    private var notifyTask: Task<Void, Never>?

    private var keyMonitor: Any?
    private var screenObserver: Any?
    private var spaceObserver: Any?
    private var spaceFadeTask: Task<Void, Never>?
    private var mouseMonitorGlobal: Any?
    private var mouseMonitorLocal: Any?
    /// Fingerprint of the current display arrangement — rebuild only when THIS
    /// changes. macOS fires didChangeScreenParameters during Space switches too
    /// (menu-bar/fullscreen state flips); rebuilding then put a NEW stationary
    /// notch on screen while the OLD one was still sliding in the outgoing
    /// Space's transition image — the "notch doubles itself" bug.
    private var screenSignature: [String] = []

    private init() {}

    /// True when ANY display's panel is open.
    var isPanelOpen: Bool { notches.contains { $0.vm.phase == .open } }

    /// The screen whose panel is currently open, if any — so the pointer can
    /// spit out of the open panel's bottom edge regardless of where the cursor
    /// is. nil when all closed (caller falls back to the cursor's screen).
    func openPanelScreen() -> NSScreen? {
        guard let open = notches.first(where: { $0.vm.phase == .open }) else { return nil }
        return NSScreen.screens.first { $0.akariDisplayID == open.displayID }
    }

    // MARK: - Lifecycle

    func install() {
        guard notches.isEmpty else { return }
        rebuild()
        installMouseProximityMonitors()
        // Re-mirror onto whatever displays exist when the arrangement changes
        // (monitor plugged/unplugged, resolution change, etc.). Guarded by the
        // display fingerprint: Space switches also fire this notification, and
        // rebuilding then visibly DOUBLED the notch mid-swipe (old window in the
        // outgoing Space's slide image + the fresh stationary one).
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let sig = Self.displaySignature()
                guard sig != self.screenSignature else { return }   // spurious (Space switch) — keep the windows
                self.rebuild()
            }
        }
        // Space switch: the pill VANISHES for the slide and fades back in once
        // the switch settles (founder call — the hardware notch stays put, so
        // our pill blinks away rather than hovering over two sliding desktops).
        // There's no "swipe began" event; activeSpaceDidChange fires as the
        // switch kicks in, so hide instantly, then fade back after the
        // transition duration. Rapid multi-swipes just keep it hidden.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for n in self.notches {
                    n.window.alphaValue = 0
                    n.window.orderFrontRegardless()   // and never leave a stale ghost above the real notch
                }
                self.spaceFadeTask?.cancel()
                self.spaceFadeTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(650))
                    guard let self, !Task.isCancelled else { return }
                    self.fadeNotchesBackIn()
                }
            }
        }
    }

    /// Sync on purpose: in an async context the compiler resolves AppKit's
    /// ASYNC `runAnimationGroup` overload (won't build without await).
    private func fadeNotchesBackIn() {
        for n in notches {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                n.window.animator().alphaValue = 1
            }
        }
    }

    /// Global + local mouse tracking for the proximity paint: the closed pill
    /// paints black the moment the cursor nears the notch — INSTANTLY (no
    /// animation), so by the time it can hover, the pill looks exactly like the
    /// old always-painted one. Both monitors are needed: global fires while the
    /// cursor is over other apps; local while it's over our own window.
    private func installMouseProximityMonitors() {
        guard mouseMonitorGlobal == nil else { return }
        mouseMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.updateCursorProximity() }
        }
        mouseMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.updateCursorProximity() }
            return event
        }
        updateCursorProximity()
    }

    private func updateCursorProximity() {
        let loc = NSEvent.mouseLocation
        for n in notches {
            guard let screen = NSScreen.screens.first(where: { $0.akariDisplayID == n.displayID }) else { continue }
            let f = screen.frame
            let nearY = loc.y >= f.maxY - n.vm.closedSize.height - 44
            let nearX = abs(loc.x - f.midX) <= n.vm.closedSize.width / 2 + 160
            let near = nearY && nearX && loc.x >= f.minX && loc.x <= f.maxX
            if n.vm.cursorNearNotch != near { n.vm.cursorNearNotch = near }
        }
    }

    /// One line per display: id + frame + notch inset. Space switches don't
    /// change this; plugging/unplugging/rearranging/resolution changes do.
    private static func displaySignature() -> [String] {
        NSScreen.screens.compactMap { s in
            guard let id = s.akariDisplayID else { return nil }
            return "\(id):\(Int(s.frame.origin.x)),\(Int(s.frame.origin.y)) \(Int(s.frame.width))×\(Int(s.frame.height)) inset:\(Int(s.safeAreaInsets.top))"
        }
    }

    /// Tear down and recreate one notch per current display, re-applying the
    /// shared conversation / working state to each.
    private func rebuild() {
        screenSignature = Self.displaySignature()
        for n in notches { n.window.orderOut(nil); n.window.close() }
        notches.removeAll()

        for screen in NSScreen.screens {
            guard let id = screen.akariDisplayID else { continue }
            notches.append(makeNotch(for: screen, id: id))
        }
        for n in notches { applyShared(to: n) }
    }

    private func makeNotch(for screen: NSScreen, id: CGDirectDisplayID) -> DisplayNotch {
        let closedSize = Self.closedNotchSize(for: screen)
        let vm = NotchViewModel(closedSize: closedSize, openWidth: openWidth,
                                isHardwareNotch: screen.safeAreaInsets.top > 0)
        let origin = NSPoint(
            x: screen.frame.midX - windowWidth / 2,
            y: screen.frame.maxY - windowHeight
        )
        let window = NotchWindow(contentRect: NSRect(origin: origin, size: NSSize(width: windowWidth, height: windowHeight)))
        let notch = DisplayNotch(displayID: id, window: window, vm: vm)

        let host = NSHostingView(rootView: NotchRootView(
            vm: vm,
            onOpen: { [weak self, weak notch] in self?.open(notch) },
            onClose: { [weak self, weak notch] in self?.close(notch) }
        ))
        host.frame = NSRect(origin: .zero, size: window.frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.orderFrontRegardless()
        return notch
    }

    private func applyShared(to notch: DisplayNotch) {
        let vm = notch.vm
        vm.conversation = conversation
        vm.onSubmit = onSubmit
        vm.onAddPDF = onAddPDF
        vm.onClose = { [weak self, weak notch] in self?.close(notch) }
        vm.onOpenSaved = { [weak self] id in self?.onOpenSaved(id) }
        vm.onNewChat = { [weak self] in self?.onNewChat() }
        vm.onStop = { [weak self] in self?.onStop() }
        vm.isWorking = working
        vm.notifications = notifications
    }

    /// Synthesized pill height for displays WITHOUT a hardware notch. Kept
    /// short (a slim strip near the very top) so it doesn't dip below the menu
    /// bar and overlay window UI — unlike a real notch, there's no cutout to
    /// fill, so it should stay minimal.
    private static let synthesizedNotchHeight: CGFloat = 12

    /// Real (notch) or synthesized (non-notch) closed pill dimensions.
    private static func closedNotchSize(for screen: NSScreen) -> CGSize {
        let h = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : synthesizedNotchHeight
        var w: CGFloat = 200
        if let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            // + 4 (matching Boring Notch) so the pill overlaps the cutout edges
            // and blends into the hardware notch. (On external displays there's
            // no cutout, so this falls back to the synthesized 200pt pill.)
            w = screen.frame.width - left - right + 4
        }
        return CGSize(width: w, height: h)
    }

    // MARK: - Public API (called by the app)

    /// Mount a conversation + callbacks across all displays. Opens the panel
    /// on the display under the cursor unless `andOpen` is false.
    func present(
        conversation: Conversation,
        onSubmit: @escaping (String) -> Void,
        onAddPDF: @escaping () -> Void,
        andOpen: Bool = true
    ) {
        install()
        self.conversation = conversation
        self.onSubmit = onSubmit
        self.onAddPDF = onAddPDF
        for n in notches { applyShared(to: n) }
        if andOpen { open(notchUnderCursor()) }
    }

    /// First-run: land every display's panel on the onboarding page and open
    /// the one under the cursor.
    func showOnboarding() {
        install()
        for n in notches { n.vm.route = .onboarding }
        open(notchUnderCursor())
    }

    func setWorking(_ working: Bool) {
        install()
        self.working = working
        for n in notches { n.vm.isWorking = working }
    }

    /// A screenshot is being sent to the provider: show the eye for a moment.
    /// Brief and glanceable, not a modal (PROVIDERS.md phase 3).
    func flashSeeing(seconds: Double = 1.8) {
        install()
        for n in notches { n.vm.isSeeing = true }
        seeingTask?.cancel()
        seeingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            for n in notches { n.vm.isSeeing = false }
        }
    }
    private var seeingTask: Task<Void, Never>?


    /// The notch surface's current bottom edge on `screen`, in top-left screen
    /// coords (the window's top sits at the screen top). Anchors the pointer's
    /// spit-out at the panel's actual bottom; falls back to the notch height.
    func panelBottomY(on screen: NSScreen) -> CGFloat {
        let fallback = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 12
        guard let id = screen.akariDisplayID,
              let notch = notches.first(where: { $0.displayID == id }) else { return fallback }
        return notch.vm.surfaceHeight > 0 ? notch.vm.surfaceHeight : fallback
    }

    // MARK: - Completion notifications

    /// A task finished while the panel was closed: drop a result toast below
    /// the notch. After a few seconds the toast collapses to a count pill that
    /// persists until acknowledged (the panel opening, or a tap).
    func notifyResult(_ text: String) {
        install()
        notifications.append(AkariNotification(text: text, date: Date()))

        notifyTask?.cancel()
        notifyTask = Task { @MainActor in
            // Beat: let the working comet clear before the center drops in, so
            // it reads as "comet finishes → notification," not both at once.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            broadcastNotifications()
        }
    }

    /// Clear pending notifications (the panel opened, or a card was opened).
    func acknowledgeNotifications() {
        guard !notifications.isEmpty else { return }
        notifyTask?.cancel()
        notifications.removeAll()
        withAnimation(AkariMotion.close) {           // collapses back into the notch
            for n in notches { n.vm.notifications = [] }
        }
    }

    private func broadcastNotifications() {
        let snapshot = notifications
        withAnimation(AkariMotion.open) {            // emerges from the notch
            for n in notches { n.vm.notifications = snapshot }
        }
    }

    // MARK: - Per-display open / close

    private func open(_ notch: DisplayNotch?) {
        guard let notch else { return }
        acknowledgeNotifications()   // opening = you've seen them
        notch.vm.phase = .open
        notch.window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    private func close(_ notch: DisplayNotch?) {
        guard let notch else { return }
        notch.vm.pinned = false
        notch.vm.route = .chat            // reopen always lands on the chat page
        notch.vm.phase = .closed
        notch.window.resignKey()
        notch.window.orderFrontRegardless()
        if !isPanelOpen { removeKeyMonitor() }
    }

    private func notchUnderCursor() -> DisplayNotch? {
        let loc = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) }),
           let id = screen.akariDisplayID,
           let n = notches.first(where: { $0.displayID == id }) {
            return n
        }
        return notches.first
    }

    // MARK: - ESC to close (bonus over Boring's hover-out close)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {  // ESC
                Task { @MainActor in
                    guard let self else { return }
                    let open = self.notches.filter { $0.vm.phase == .open }
                    // ESC backs out of a Settings/About page first; only when
                    // already on the chat page does it close the panel.
                    let onPage = open.filter { $0.vm.route != .chat }
                    if !onPage.isEmpty {
                        withAnimation(AkariMotion.open) {
                            onPage.forEach { $0.vm.route = .chat }
                        }
                    } else {
                        open.forEach { self.close($0) }
                    }
                }
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
    }
}

private extension NSScreen {
    /// Stable per-screen identifier (the CoreGraphics display number).
    var akariDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
