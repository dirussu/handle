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
    private var surfaceWidth: CGFloat { vm.phase == .open ? vm.openWidth : vm.closedSize.width }
    /// Open content inset — clears the flared top corners' inset walls
    /// (straight edges sit at x = topRadius) plus breathing room.
    private var contentInset: CGFloat { 32 }

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
                    .transition(AkariMotion.emerge.animation(.smooth(duration: 0.35)))
            }
        }
        // Width animates; height is intrinsic (the conversation self-sizes),
        // so the panel is snug — no empty void — and grows as the answer
        // streams. The morph rides the spring below.
        .frame(width: surfaceWidth)
        .background(Color.black)
        // Report the surface's rendered height (= the panel's bottom edge in
        // top-left screen coords) so the pointer can spit out of it.
        .background { GeometryReader { g in Color.clear.preference(key: SurfaceHeightKey.self, value: g.size.height) } }
        .clipShape(shape)
        // Cover the 1px seam where the flared top meets the bezel.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black)
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
        // Boring Notch's shadow: a symmetric soft glow (no y offset) that
        // appears on hover or while open. radius 6, black @ 0.7.
        .shadow(
            color: (vm.phase == .open || isHovering) ? .black.opacity(0.7) : .clear,
            radius: 6
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
            topBar
            routedContent
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
                        .padding(.top, 40)
                        .padding(.trailing, contentInset)
                        .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                }
            }
        }
        .onChange(of: vm.phase) { _, phase in if phase != .open { showMenu = false } }
    }

    private var topBar: some View {
        HStack(spacing: AkariSpacing.s) {
            if vm.route != .chat {
                Button { withAnimation(AkariMotion.open) { vm.route = .chat } } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back")
                Text(routeTitle)
                    .font(.akariSection)
                    .foregroundStyle(.primary)
            }
            Spacer()
            if vm.route == .chat {
                ellipsisButton
            }
        }
        .frame(height: 28)
        .padding(.horizontal, contentInset)
        .padding(.top, 10)
    }

    private var routeTitle: String {
        switch vm.route {
        case .chat:     return ""
        case .settings: return "Settings"
        case .about:    return "About"
        }
    }

    /// The ⋯ button — toggles the custom dropdown. The single entry point to
    /// everything that used to live in the (now-removed) menu-bar icon.
    private var ellipsisButton: some View {
        Button {
            withAnimation(AkariMotion.interactive) { showMenu.toggle() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(showMenu ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("More")
    }

    /// Custom solid-black dropdown — the native SwiftUI Menu's system chrome
    /// read off-brand on the black panel, so this matches the panel language
    /// (black fill, white hairline, white-only rows that highlight on hover).
    private var menuDropdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRow(title: "Settings", systemImage: "gearshape") {
                showMenu = false
                withAnimation(AkariMotion.open) { vm.route = .settings }
            }
            MenuRow(title: "About Akari", systemImage: "info.circle") {
                showMenu = false
                withAnimation(AkariMotion.open) { vm.route = .about }
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
        case .settings:
            SettingsBody()
                .scrollContentBackground(.hidden)   // let the black panel show through the Form
                .frame(height: 380)                 // bound it so the Form scrolls inside the notch
                .padding(.horizontal, AkariSpacing.s)
        case .about:
            AboutBody(onDone: { withAnimation(AkariMotion.open) { vm.route = .chat } })
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
                onClose: vm.onClose
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
                    .transition(.asymmetric(
                        insertion: AkariMotion.popFromTop.animation(AkariMotion.pop),
                        removal: AkariMotion.popFromTop.animation(AkariMotion.pop.delay(Double(notifications.count) * stagger))
                    ))
                ForEach(Array(notifications.reversed().enumerated()), id: \.element.id) { item in
                    NotificationCard(note: item.element, width: width, onOpen: onOpen)
                        .transition(.asymmetric(
                            insertion: AkariMotion.popFromTop.animation(AkariMotion.pop.delay(Double(item.offset + 1) * stagger)),
                            removal: AkariMotion.popFromTop.animation(AkariMotion.pop.delay(Double(notifications.count - 1 - item.offset) * stagger))
                        ))
                }
            }
        }
    }

    /// Pop the stack out of / into the pill — the bouncy spring is the funk.
    private func toggle() {
        withAnimation(AkariMotion.pop) { expanded.toggle() }
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
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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

    private var collapseHandle: some View {
        Button { withAnimation(AkariMotion.pop) { expanded = false } } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 46, height: 22)
                .background(Color.black, in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
