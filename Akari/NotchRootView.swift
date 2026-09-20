import SwiftUI
import AppKit

/// Reports the notch surface's rendered height (→ the panel's bottom edge).
private struct SurfaceHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    // MAX, not last-wins. Sibling views below `notchSurface` (the notification
    // center, the trailing Spacer) contribute the default 0; a `value =
    // nextValue()` reduce lets the LAST of them clobber the measured height to 0.
    // That silently fell back to the CLOSED notch height, so the OPEN panel's
    // spit-out anchored up inside/behind the panel instead of at its bottom edge.
    // Max keeps the single real measurement.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The notch surface. Pinned to the very top-center of its (fixed, large,
/// transparent) window; only the pill/panel is drawn — the empty space below
/// doesn't hit-test, so clicks fall through to apps behind it. Hover / tap /
/// open / close interaction and animation match Boring Notch.
struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var showMenu = false   // the custom ⋯ dropdown
    /// Keeps the surface painted through the close spring: closing is usually
    /// caused by the cursor LEAVING (which also exits the proximity zone), and
    /// unpainting mid-collapse would swallow the close animation.
    @State private var closingGrace = false
    @State private var closingGraceTask: Task<Void, Never>?

    // The notch's springs — now the app's shared motion system (AkariMotion),
    // so the notification center and everything else animate identically.
    private let animationSpring = AkariMotion.interactive
    private let openAnimation = AkariMotion.open
    private let closeAnimation = AkariMotion.close
    private let openHoverDelay: Duration = .milliseconds(300)
    private let closeHoverDelay: Duration = .milliseconds(100)

    // Corner radii. Closed = matched to the hardware notch so the pill blends
    // invisibly. The top flare insets the straight side walls by `topRadius`
    // per side, so a flared closed top makes the pill body NARROWER than the
    // cutout — keep the closed top flare tiny (2) so the sides reach the notch
    // edges. Bottom (14) matches the notch's rounded bottom corners. Open is
    // rounder, for the softer look Akari uses everywhere.
    private var topRadius: CGFloat { vm.phase == .open ? 20 : 2 }
    // Closed bottom radius adapts to the pill height so a short synthesized
    // pill (non-notch displays) still has clean, proportional corners.
    private var bottomRadius: CGFloat {
        vm.phase == .open ? 34 : min(14, vm.closedSize.height * 0.55)
    }
    /// Pages (Settings / Chats) open WIDER than the chat panel — dense surfaces
    /// (forms, lists) earn the extra width; chat + onboarding stay compact. The
    /// width rides the same route animation as the content swap.
    private var surfaceWidth: CGFloat {
        guard vm.phase == .open else { return vm.closedSize.width }
        switch vm.route {
        case .chat, .onboarding: return vm.openWidth
        default:                 return 700   // window is 740 — leaves shadow room
        }
    }
    /// Open content inset — clears the flared top corners' inset walls
    /// (straight edges sit at x = topRadius) plus breathing room.
    private var contentInset: CGFloat { 32 }

    /// What the notch surface PAINTS. On a hardware notch the UNATTENDED closed
    /// pill paints NOTHING — the physical cutout is already black, so the fill
    /// added zero normally and became the visible sliding artifact during Space
    /// switches (all-Spaces windows render live in BOTH sliding space trees; no
    /// window level opts out — tested, founder video). `cursorNearNotch` paints
    /// it back INSTANTLY as the cursor approaches (controller-fed global mouse
    /// tracking, no animation), so by the time you can hover, the pill is
    /// already solid and hover adds only the glow — pixel-identical to the old
    /// always-painted behavior. A Space swipe happens with the cursor elsewhere,
    /// so there's nothing of Akari to slide. Also painted: the open panel, the
    /// working comet's bed, and the synthesized pill on cutout-less displays.
    private var surfacePaint: Color {
        if vm.phase == .open || vm.isWorking || vm.cursorNearNotch || isHovering
            || closingGrace || !vm.isHardwareNotch {
            return .black
        }
        return .clear
    }

    var body: some View {
        VStack(spacing: 0) {
            notchSurface

            // Notification center — a count pill that drops out from beneath
            // the closed notch and expands into a stack of result cards.
            if vm.phase == .closed && !vm.notifications.isEmpty {
                NotificationCenterView(
                    notifications: vm.notifications,
                    width: vm.closedSize.width,   // match the notch — never wider
                    onOpen: onOpen,
                    onDismissAll: { NotchController.shared.acknowledgeNotifications() }
                )
                .padding(.top, 12)
                .transition(AkariMotion.emerge)   // emerges from the notch, like the panel
            }

            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onPreferenceChange(SurfaceHeightKey.self) { vm.surfaceHeight = $0 }
        // Hold the paint through the close spring (~0.45s) + a small margin,
        // then release it — the pill quietly unpaints at rest.
        .onChange(of: vm.phase) { _, phase in
            closingGraceTask?.cancel()
            if phase == .closed {
                closingGrace = true
                closingGraceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                    closingGrace = false
                }
            } else {
                closingGrace = false
            }
        }
        // The pill's drop-in / collapse / dismiss are animated at the mutation
        // site (NotchController wraps those in `withAnimation`), so the notch's
        // own open/close springs stay untouched.
    }

    @ViewBuilder
    private var notchSurface: some View {
        let shape = NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
        VStack(spacing: 0) {
            // Always-present top strip — the part that merges with the
            // physical notch. STABLE across states, so opening is a smooth
            // growth, not a view swap (this is what keeps Boring Notch fluid).
            topStrip

            // The conversation body is ADDED below the strip when open, with
            // a gentle scale+fade — never replacing the strip.
            if vm.phase == .open {
                openBody
                    // The app's shared `emerge` transition (the notification
                    // cards use it too); keeps the notch's own settled timing.
                    .transition(AkariMotion.emerge.animation(AkariMotion.swap))
            }
        }
        // Width animates; height is intrinsic (the conversation self-sizes),
        // so the panel is snug — no empty void — and grows as the answer
        // streams. The morph rides the spring below.
        .frame(width: surfaceWidth)
        // The chat header buttons (New chat + ⋯) sit UP in the notch strip's
        // trailing corner — not a header row — so the transcript gets the full
        // height. (Content clears them via `chatContentTopInset`.)
        .overlay(alignment: .topTrailing) {
            if vm.phase == .open && vm.route == .chat {
                HStack(spacing: AkariSpacing.s) {
                    newChatButton
                    ellipsisButton
                }
                .padding(.trailing, contentInset)
                .padding(.top, 5)
            }
        }
        // Pages (Settings / Chats / Welcome) mirror it on the left: back + title
        // up in the strip's leading corner, not a header row below it.
        .overlay(alignment: .topLeading) {
            if vm.phase == .open && vm.route != .chat {
                pageHeader
                    .padding(.leading, contentInset)
                    .padding(.top, 5)
            }
        }
        .background(surfacePaint)
        // Report the surface's rendered height (= the panel's bottom edge in
        // top-left screen coords) so the pointer can spit out of it.
        .background { GeometryReader { g in Color.clear.preference(key: SurfaceHeightKey.self, value: g.size.height) } }
        .clipShape(shape)
        // Cover the 1px seam where the flared top meets the bezel.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(surfacePaint)
                .frame(height: 1)
                .padding(.horizontal, topRadius)
        }
        // No outline stroke on the open panel: it drew a hairline straight across
        // the bottom edge, cutting through the metaball pointer's neck where it
        // oozes out and breaking the "one continuous black mass" look. The shadow
        // below defines the panel instead — and the closed pill never had a stroke,
        // which is exactly why the closed spit-out already read clean.
        // Composite the whole notch as ONE layer so the shape + content
        // animate together (Boring Notch does this — key to the smoothness).
        .compositingGroup()
        // Symmetric soft glow (no y offset) on hover or while open. Bumped from
        // Boring Notch's radius 6 @ 0.7 on founder request — a bit stronger.
        .shadow(
            color: (vm.phase == .open || isHovering) ? .black.opacity(0.85) : .clear,
            radius: 9
        )
        // Working comet — placed AFTER the compositingGroup so its glow isn't
        // clipped to the pill bounds (inside the group it read as narrower and
        // its corner bloom looked cut). Closed pill only; side-to-side sweep.
        .overlay {
            if vm.phase == .closed && vm.isWorking {
                BorderComet(shape: NotchBottomOutline(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius),
                            loops: false, period: 5.2, tailLength: 0.30, lineWidth: 2.0, glow: 0.9)
            }
        }
        // Seeing glyph — a screenshot just left for the provider. Bottom-centre
        // of the closed pill, gone after a moment (NotchController.flashSeeing).
        .overlay(alignment: .bottom) {
            if vm.phase == .closed && vm.isSeeing {
                Image(systemName: "eye.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.bottom, 3)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.isSeeing)
        .contentShape(shape)
        .animation(vm.phase == .open ? openAnimation : closeAnimation, value: vm.phase)
        .onHover { handleHover($0) }
        .onTapGesture {
            if vm.phase == .closed { onOpen() }
        }
    }

    // MARK: Top strip (always present)
    //
    // The stable band that merges with the physical notch. Kept as its own
    // view so opening is a smooth growth (strip + body) rather than a swap.

    private var topStrip: some View {
        Color.clear
            .frame(height: vm.closedSize.height)
    }

    // MARK: Open body (added below the strip)
    //
    // The notch is the app's only surface, so Settings and About are *pages*
    // within it (reached via the ⋯ menu), not windows. A thin top bar carries
    // the ⋯ (chat) or a back chevron + title (settings/about).

    private var openBody: some View {
        VStack(spacing: 0) {
            // No header row on ANY route — the chat buttons (right) and the page
            // back+title (left) live up in the notch strip as overlays on the
            // surface. Content takes the full height; the inset clears the strip.
            routedContent
                .padding(.top, contentTopInset)
        }
        .padding(.bottom, 14)
        // The ⋯ dropdown floats below the button; a transparent catcher behind
        // it dismisses on any outside tap.
        .overlay {
            if showMenu && vm.route == .chat {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(AkariMotion.interactive) { showMenu = false } }
                    menuDropdown
                        .padding(.top, 4)
                        .padding(.trailing, contentInset)
                        .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                }
            }
        }
        .onChange(of: vm.phase) { _, phase in if phase != .open { showMenu = false } }
    }

    /// The header chrome (chat buttons right, page back+title left) overlays the
    /// notch strip's corners. A real hardware notch is tall enough to clear the
    /// content on its own; a short synthesized pill (external display) isn't, so
    /// inset the content down by the shortfall so it never slides under the chrome.
    private var contentTopInset: CGFloat {
        max(4, 38 - vm.closedSize.height)
    }

    // Page header (Settings / Chats / Welcome): back chevron + title, overlaid
    // up in the notch strip's leading corner — the mirror of the chat buttons.
    private var pageHeader: some View {
        HStack(spacing: AkariSpacing.s) {
            Button { withAnimation(AkariMotion.open) { vm.route = .chat } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .akariIconHover()
            .help("Back")
            Text(routeTitle)
                .font(.akariSection)
                .foregroundStyle(.primary)
        }
    }

    private var routeTitle: String {
        switch vm.route {
        case .chat:       return ""
        case .history:    return "Chats"
        case .settings:   return "Settings"
        case .onboarding: return "Welcome"
        }
    }

    /// New chat — swap in a clean, blank conversation (a fresh slate; the old
    /// one is saved to Chats). The one-tap sibling of the ⋯ → New chat item.
    private var newChatButton: some View {
        Button { vm.onNewChat() } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .akariIconHover()
        .help("New chat")
    }

    /// The ⋯ button — toggles the custom dropdown. The single entry point to
    /// everything that used to live in the (now-removed) menu-bar icon.
    private var ellipsisButton: some View {
        Button {
            withAnimation(AkariMotion.interactive) { showMenu.toggle() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .akariIconHover(idle: showMenu ? Color.white : Color(nsColor: .secondaryLabelColor))
        .help("More")
    }

    /// Custom solid-black dropdown — the native SwiftUI Menu's system chrome
    /// read off-brand on the black panel, so this matches the panel language
    /// (black fill, white hairline, white-only rows that highlight on hover).
    private var menuDropdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRow(title: "Chats", systemImage: "bubble.left.and.bubble.right") {
                showMenu = false
                withAnimation(AkariMotion.open) { vm.route = .history }
            }
            MenuRow(title: "Settings", systemImage: "gearshape") {
                showMenu = false
                withAnimation(AkariMotion.open) { vm.route = .settings }
            }
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            MenuRow(title: "Quit Akari", systemImage: "power") {
                showMenu = false
                NSApp.terminate(nil)
            }
        }
        .padding(6)
        .frame(width: 196)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
    }

    @ViewBuilder
    private var routedContent: some View {
        switch vm.route {
        case .chat:     chatContent
        case .history:
            HistoryBody(vm: vm)
                .padding(.horizontal, contentInset)
        case .settings:
            SettingsBody()
                .scrollContentBackground(.hidden)   // let the black panel show through the Form
                .contentMargins(.vertical, 14, for: .scrollContent)   // clear the fade zones at rest
                .frame(height: 560)                 // bound it so the Form scrolls inside the notch
                .scrollEdgeFade()                   // content dissolves at the header / bottom edge
                .padding(.horizontal, AkariSpacing.s)
        case .onboarding:
            OnboardingBody(onDone: { withAnimation(AkariMotion.open) { vm.route = .chat } })
                .padding(.horizontal, contentInset)
        }
    }

    @ViewBuilder
    private var chatContent: some View {
        if let convo = vm.conversation {
            ConversationContent(
                conversation: convo,
                onSubmit: vm.onSubmit,
                onAddPDF: vm.onAddPDF,
                onClose: vm.onClose,
                onStop: vm.onStop
            )
            // Horizontal inset must clear the notch shape's inset walls
            // (the flared top corners push the straight edges in by
            // `topRadius`), or leading/trailing content gets clipped.
            .padding(.horizontal, contentInset)
            .frame(maxWidth: .infinity)
        } else {
            // Idle prompt — a single centered hint in a snug bar.
            Text("Ask Akari, or press ⌥⌥ to capture")
                .font(.akariBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .padding(.horizontal, contentInset)
        }
    }

    // MARK: - Hover (mirrors Boring Notch's handleHover)

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()

        if hovering {
            withAnimation(animationSpring) { isHovering = true }

            guard vm.phase == .closed else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: openHoverDelay)
                guard !Task.isCancelled, isHovering, vm.phase == .closed else { return }
                onOpen()
            }
        } else {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: closeHoverDelay)
                guard !Task.isCancelled else { return }
                withAnimation(animationSpring) { isHovering = false }
                if vm.phase == .open && !shouldStayOpen {
                    onClose()
                }
            }
        }
    }

    /// Suppress hover-out close only for the same reasons that apply when the
    /// AI is idle: pinned, an unsent draft, or a pending confirmation. Akari
    /// working is NOT a reason to keep it open — moving the cursor away closes
    /// it like normal; the answer keeps streaming in the background and the
    /// closed pill shows the working comet, then a result peek when done.
    private var shouldStayOpen: Bool {
        if vm.route != .chat { return true }   // a page (Settings/About) is open
        if vm.pinned { return true }
        guard let convo = vm.conversation else { return false }
        if convo.pendingConfirmation != nil { return true }
        if !convo.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }
}

// MARK: - Dropdown row

/// One row of the custom ⋯ dropdown — white-only, highlights on hover.
private struct MenuRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AkariSpacing.s) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.akariBody)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.white.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(AkariMotion.feedback, value: hovering)   // was instant — brand feedback beat
        .onHover { hovering = $0 }
    }
}

// MARK: - Notification center

/// The notification center below the closed notch. Collapsed it's a notch-width
/// "Notifications N" pill; tapping it expands into a collapse handle + a stack
/// of result cards (newest first). Everything stays ≤ the notch width.
/// Solid-black, white-only.
private struct NotificationCenterView: View {
    let notifications: [AkariNotification]
    let width: CGFloat        // matches the notch — never wider
    let onOpen: () -> Void
    let onDismissAll: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var expanded = false
    @State private var pillHover = false

    private let stagger: Double = 0.06   // per-card cascade delay

    var body: some View {
        VStack(spacing: AkariSpacing.m) {
            countPill
            if expanded {
                // The handle + each card pop out of the pill ONE AFTER ANOTHER:
                // top-down on expand, bottom-up retracting into the pill on
                // collapse. Each is the same pop, just delayed by its position.
                collapseHandle
                    .transition(reduce ? .opacity : .asymmetric(
                        insertion: AkariMotion.popFromTop.animation(AkariMotion.pop),
                        removal: AkariMotion.popFromTop.animation(AkariMotion.pop.delay(Double(notifications.count) * stagger))
                    ))
                ForEach(Array(notifications.reversed().enumerated()), id: \.element.id) { item in
                    NotificationCard(note: item.element, width: width, onOpen: onOpen)
                        .transition(reduce ? .opacity : .asymmetric(
                            insertion: AkariMotion.popFromTop.animation(AkariMotion.pop.delay(Double(item.offset + 1) * stagger)),
                            removal: AkariMotion.popFromTop.animation(AkariMotion.pop.delay(Double(notifications.count - 1 - item.offset) * stagger))
                        ))
                }
            }
        }
    }

    /// Pop the stack out of / into the pill — the bouncy spring is the funk.
    private func toggle() {
        withAnimation(reduce ? .easeOut(duration: 0.2) : AkariMotion.pop) { expanded.toggle() }
    }

    private var countPill: some View {
        HStack(spacing: AkariSpacing.s) {
            Text("Notifications")
                .font(.akariBody)
                .foregroundStyle(.white.opacity(0.92))
            Spacer(minLength: 0)
            // On hover the count + dot swap for a ✕ that clears everything.
            ZStack {
                if pillHover {
                    Button(action: onDismissAll) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .akariIconHover(idle: .white.opacity(0.9))
                    .help("Clear all notifications")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    HStack(spacing: AkariSpacing.s) {
                        Text("\(notifications.count)")
                            .font(.akariBody.weight(.semibold))
                            .foregroundStyle(.white)
                        Circle()
                            .fill(.white)               // white, not the mockup's orange (DESIGN.md)
                            .frame(width: 5, height: 5)
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, AkariSpacing.m)
        .frame(width: width, height: 50)
        .background(Color.black, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        .contentShape(Capsule())
        .onTapGesture { toggle() }      // tapping the pill (not the ✕) toggles expand
        .scaleEffect(pillHover ? 1.03 : 1.0)
        .shadow(color: .black.opacity(pillHover ? 0.6 : 0.5), radius: pillHover ? 18 : 14, y: 7)
        .onHover { pillHover = $0 }
        .animation(AkariMotion.interactive, value: pillHover)
    }

    private var collapseHandle: some View { CollapseHandle(reduce: reduce) { expanded = false } }
}

/// The capsule that folds the notification stack. Hover = the chevron turns
/// white, nothing else (founder, 2026-07-10: the fill/stroke lift read as
/// "glass" — too much). Idle sits at 0.55 so the white step is visible.
private struct CollapseHandle: View {
    let reduce: Bool
    let collapse: () -> Void
    @State private var hovering = false

    var body: some View {
        Button { withAnimation(reduce ? .easeOut(duration: 0.2) : AkariMotion.pop) { collapse() } } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(hovering ? .white : .white.opacity(0.55))
                .frame(width: 46, height: 22)
                .background(Color.black, in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(AkariMotion.feedback, value: hovering)
    }
}

/// One result card — "Akari" + time header with an ↗ that opens it in the
/// notch, and the full result as the body. Notch-width, solid black.
private struct NotificationCard: View {
    let note: AkariNotification
    let width: CGFloat
    let onOpen: () -> Void
    @State private var hover = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: AkariSpacing.s) {
                Text("Akari")
                    .font(.akariBody.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 0)
                Text(Self.timeFormatter.string(from: note.date))
                    .font(.akariMicro)
                    .foregroundStyle(.white.opacity(0.4))
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .akariIconHover(idle: .white.opacity(0.6))
            }
            Text(note.text.isEmpty ? "Done" : note.text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AkariSpacing.m)
        .frame(width: width, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)   // static, no hover change
        }
        .scaleEffect(hover ? 1.02 : 1.0)
        .shadow(color: .black.opacity(hover ? 0.5 : 0.4), radius: hover ? 14 : 10, y: 5)
        .onHover { hover = $0 }
        .animation(AkariMotion.interactive, value: hover)
    }
}
