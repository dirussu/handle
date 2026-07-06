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

    // Pending completion notifications (the pill below the closed notch).
    private var notifications: [AkariNotification] = []
    private var notifyTask: Task<Void, Never>?

    private var keyMonitor: Any?
    private var screenObserver: Any?

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
        // Re-mirror onto whatever displays exist when the arrangement changes
        // (monitor plugged/unplugged, resolution change, etc.).
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    /// Tear down and recreate one notch per current display, re-applying the
    /// shared conversation / working state to each.
    private func rebuild() {
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
        let vm = NotchViewModel(closedSize: closedSize, openWidth: openWidth)
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
