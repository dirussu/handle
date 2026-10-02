import SwiftUI
import AppKit
import Combine

enum NotchPhase {
    case closed   // bare pill (idle) or comet (working) or result peek
    case open     // panel dropped down: the assistant surface
}

/// Which page the open panel is showing. The notch is the app's *only*
/// surface — Settings and About are pages within it (reached via the ⋯
/// menu), not separate windows.
enum NotchRoute {
    case chat        // the assistant surface (default)
    case history     // saved conversations (reopen / delete)
    case settings
    case onboarding  // first-run walk-through (until Onboarding.isDone)
}

/// Observable state for the notch surface. The `NotchController` mutates it;
/// `NotchRootView` renders it. Kept deliberately thin — all window/mouse
/// logic lives in the controller.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published var phase: NotchPhase = .closed
    @Published var route: NotchRoute = .chat
    @Published var isWorking: Bool = false
    /// A screenshot just left the Mac — a brief eye glyph on the closed pill.
    @Published var isSeeing: Bool = false
    @Published var pinned: Bool = false
    /// Cursor is near the notch (controller-fed, global mouse tracking). The
    /// closed pill paints ONLY then — instantly, before the cursor arrives — so
    /// hover looks exactly like the old always-painted pill, while a Space swipe
    /// (cursor elsewhere) has nothing of Handle to slide.
    @Published var cursorNearNotch: Bool = false

    /// Measured height of the rendered notch surface (pill when closed, panel
    /// when open). The window's top sits at the screen top, so the surface's
    /// bottom edge in top-left screen coords equals this — used to anchor the
    /// pointer's spit-out at the panel's actual bottom.
    @Published var surfaceHeight: CGFloat = 0

    // Completion notifications, broadcast from the controller. Shown as the
    // notification center below the closed notch (a count pill that expands
    // into a stack of cards). Persists until acknowledged (the panel opening).
    @Published var notifications: [HandleNotification] = []

    /// The live conversation shown in the open panel (nil before first capture).
    @Published var conversation: Conversation?

    // Callbacks wired by the controller to the app's orchestration.
    var onSubmit: (String) -> Void = { _ in }
    var onAddPDF: () -> Void = {}
    var onClose: () -> Void = {}
    /// Reopen a saved conversation by its persistent id (Chats page rows).
    var onOpenSaved: (String) -> Void = { _ in }
    /// Start a fresh, blank text-first conversation (the New-chat action).
    var onNewChat: () -> Void = {}
    /// Stop the running turn (the send button becomes Stop while Handle works).
    var onStop: () -> Void = {}

    /// The hardware (or synthesized) notch dimensions for the closed pill.
    let closedSize: CGSize
    /// The open panel's nominal width; height grows to fit content.
    let openWidth: CGFloat
    /// True when this display has a physical camera-housing cutout. The closed
    /// pill paints NOTHING there (the cutout is already black); a synthesized
    /// pill on an external display must paint itself.
    let isHardwareNotch: Bool

    init(closedSize: CGSize, openWidth: CGFloat, isHardwareNotch: Bool = true) {
        self.closedSize = closedSize
        self.openWidth = openWidth
        self.isHardwareNotch = isHardwareNotch
    }
}
