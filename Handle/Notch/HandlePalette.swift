import SwiftUI

// MARK: - Focus rings: none, app-wide
//
// SwiftUI's TextField bridges to NSTextField, whose macOS focus ring draws a
// thick gray halo that reads as damage on Handle's black surface (seen in a
// screenshot) — and `.focusEffectDisabled()` doesn't reach the
// bridged AppKit ring. One override kills it everywhere; focus itself (cursor,
// keyboard navigation) is untouched.
extension NSTextField {
    open override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }
}

// MARK: - Type system
//
// Strict three-role ramp: title / body / caption. Everything else is a
// variant on weight or tracking, NOT size. Random sizes (13.5pt, 17pt-here-
// 16pt-there) are the #1 visual-jitter smell in productivity apps.

extension Font {
    /// First-run hero display — the one oversized moment (onboarding welcome /
    /// "you're set"). Deliberately larger than handleTitle for a real size jump.
    static let handleDisplay = Font.system(size: 27, weight: .bold, design: .rounded)

    /// Hero per-screen header. Used at most once per surface.
    static let handleTitle = Font.system(size: 20, weight: .semibold, design: .rounded)

    /// Section heading inside a screen.
    static let handleSection = Font.system(size: 14, weight: .semibold)

    /// Default body / message text.
    static let handleBody = Font.system(size: 13, weight: .regular)

    /// Metadata, labels, controls.
    static let handleCaption = Font.system(size: 11, weight: .medium)

    /// Tiny uppercase tracked caption (e.g. app-name pill).
    static let handleMicro = Font.system(size: 10, weight: .semibold)
}

// MARK: - Spacing tokens
//
// Strict 4pt base grid. ANY layout value outside this set is a bug.

enum HandleSpacing {
    static let xs: CGFloat = 4
    static let s:  CGFloat = 8
    static let m:  CGFloat = 12
    static let l:  CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

// MARK: - Adaptive chrome tokens
//
// Use these for chrome that needs visible contrast against the glass in BOTH
// light and dark modes. Small-button backgrounds, dividers, etc. They use
// `Color.primary` (which is black in light / white in dark) at low opacity,
// so they always lift slightly against the surrounding material.
//
// For wash/lift surfaces *on top of* glass, prefer `Color.white.opacity(N)`
// — that brightens the surface in both modes (more visibly in dark, subtly
// in light), which is the correct "elevated card" read.

extension Color {
    /// Dim adaptive fill — for control chips like the close button background.
    static let handleChip = Color.primary.opacity(0.10)
}

// MARK: - Solid-black panel chrome (DESIGN.md)
//
// DESIGN.md reversed Handle's surface from translucent liquid-glass to a SOLID
// BLACK surface with white-only accents: "hierarchy from opacity and spacing,
// never color or weight." The notch renders this way directly (Color.black +
// white hairline + shadow); these helpers bring the same treatment to every
// other surface. This is the only surface language now — the liquid-glass
// chrome and warm lamp-glow colors it replaced have been removed.

extension View {
    /// Handle's solid surface: opaque black, a 1px white hairline edge, and a
    /// soft drop shadow — the app's one surface treatment.
    func handleSolidPanel(cornerRadius: CGFloat = 28) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color.black)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
            .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 10)
    }

    /// A soft fade at the top and/or bottom edge of a scroll area, so content
    /// dissolves into the panel as it meets the header / the notch's bottom edge
    /// instead of hard-clipping. `top`/`bottom` are the fade heights in points
    /// (0 disables that edge). Apply to the framed scroll view (mask sizes to it).
    ///
    /// The fade is smoothstep-EASED, not linear: a short linear ramp reads as a
    /// hard smudge (opacity crashes 1→0 in a straight line); easing spends most
    /// of the distance nearly-opaque and melts out at the very edge, so there is
    /// no perceptible line where the fade begins.
    func scrollEdgeFade(top: CGFloat = 24, bottom: CGFloat = 24) -> some View {
        mask {
            GeometryReader { geo in
                let h = max(geo.size.height, 1)
                LinearGradient(
                    stops: handleEdgeFadeStops(tf: min(top / h, 0.5), bf: min(bottom / h, 0.5),
                                              top: top, bottom: bottom),
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
    }
}

/// Gradient stops for `scrollEdgeFade` — hoisted out of the ViewBuilder (which
/// can't hold imperative statements).
private func handleEdgeFadeStops(tf: CGFloat, bf: CGFloat, top: CGFloat, bottom: CGFloat) -> [Gradient.Stop] {
    // smoothstep t²(3−2t), sampled: (position-in-fade, opacity)
    let curve: [(CGFloat, Double)] = [(0, 0), (0.25, 0.16), (0.5, 0.5), (0.75, 0.84), (1, 1)]
    var stops: [Gradient.Stop] = []
    if top > 0 {
        stops += curve.map { .init(color: .black.opacity($0.1), location: $0.0 * tf) }
    } else {
        stops.append(.init(color: .black, location: 0))
    }
    if bottom > 0 {
        stops += curve.reversed().map { .init(color: .black.opacity($0.1), location: 1 - $0.0 * bf) }
    } else {
        stops.append(.init(color: .black, location: 1))
    }
    return stops
}

// MARK: - Solid-black buttons (white-only)
//
// The solid-language button: white-only, no glass. White fill = the primary
// action (black text); white-at-opacity = secondary. Mirrors the send button.

struct HandleSolidButtonStyle: ButtonStyle {
    enum Variant { case neutral, prominent, destructive }
    let variant: Variant

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, variant: variant)
    }

    /// ButtonStyle can't hold @State, so the body lives in a nested view that
    /// tracks hover: a light background lift + a whisper of scale (hover is seen
    /// constantly — fast and subtle), on top of the existing press feedback.
    private struct HoverBody: View {
        let configuration: Configuration
        let variant: Variant
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.handleBody.weight(variant == .neutral ? .medium : .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, HandleSpacing.l)
                .padding(.vertical, 7)
                .background(background, in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.02 : 1.0))
                .opacity(configuration.isPressed ? 0.85 : 1.0)
                .animation(HandleMotion.feedback, value: configuration.isPressed)
                .animation(HandleMotion.feedback, value: hovering)
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch variant {
            case .neutral:     return .white.opacity(hovering ? 1.0 : 0.9)
            case .prominent:   return .black              // on a white fill
            case .destructive: return .white
            }
        }

        private var background: AnyShapeStyle {
            switch variant {
            case .neutral:     return AnyShapeStyle(Color.white.opacity(hovering ? 0.15 : 0.10))
            case .prominent:   return AnyShapeStyle(Color.white)            // white = the action
            case .destructive: return AnyShapeStyle(Color.red)             // red = the one semantic exception (danger)
            }
        }
    }
}

// MARK: - Icon-button hover
//
// Bare icon buttons (⋯, new chat, paperclip, trash, …) get ONE shared hover:
// the glyph simply brightens to full white — no wash, no container, no scale
// (a deliberate choice; DESIGN.md "hierarchy from opacity"). The modifier OWNS the
// tint, so the label must not set its own foregroundStyle (it would override).

private struct HandleIconHover: ViewModifier {
    let idle: Color
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .foregroundStyle(hovering ? .white : idle)
            .animation(HandleMotion.feedback, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Handle's shared icon-button hover: brighten to white. `idle` is the
    /// resting tint (default: secondary).
    func handleIconHover(idle: Color = Color(nsColor: .secondaryLabelColor)) -> some View {
        modifier(HandleIconHover(idle: idle))
    }
}

extension ButtonStyle where Self == HandleSolidButtonStyle {
    static var handleSolid:            HandleSolidButtonStyle { .init(variant: .neutral) }
    static var handleSolidProminent:   HandleSolidButtonStyle { .init(variant: .prominent) }
    static var handleSolidDestructive: HandleSolidButtonStyle { .init(variant: .destructive) }
}

// MARK: - Motion — one shared animation system
//
// Every surface animates with the SAME curves as the notch panel, so the whole
// app feels like one mechanism, not a pile of screens. The notch is the
// reference; these are its springs, lifted out so everything else can borrow
// them. Surfaces that spawn from a source (the notch → the panel, the pill →
// its cards) use `.emerge` — grow from the top edge + fade — so they read as
// coming OUT of that source and collapsing back INTO it.

enum HandleMotion {
    // ---- The duration ramp (like the type ramp: three roles, no magic numbers) ----

    /// Micro feedback — hover tints, press scale, focus rings. Constant and
    /// fast; the user should feel it, never watch it.
    static let feedback = Animation.smooth(duration: 0.15)
    /// In-place content swap — a control morphing (send↔stop), a status flip,
    /// the transcript growing, panel content emerging.
    static let swap = Animation.smooth(duration: 0.28)
    /// Whole-surface change — an onboarding step advancing, a card dissolving
    /// into the next. The one deliberate, watchable beat.
    static let settle = Animation.smooth(duration: 0.45)
    /// Staggered entrance — elements blur-rising in as a screen assembles
    /// (delay by index; onboarding heroes). Slightly springy, alive.
    static let enter = Animation.spring(duration: 0.55, bounce: 0.12)

    // Ambient exceptions (documented, not tokens): the hero glow breathe
    // (easeInOut 2.8s forever) and the Thinking… label breathe (0.95s forever)
    // are mood, not motion — they deliberately live outside the ramp, as does
    // the metaball pointer's hand-tuned physics choreography.

    // ---- The notch mechanism's springs ----

    /// A surface expanding into view — the notch's open spring (slight overshoot).
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    /// A surface collapsing — the notch's close spring (settled, no overshoot).
    static let close = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    /// Interactive feedback — hover, press, drag-follow. Snappy and light.
    static let interactive = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    /// Transition for a surface that emerges from / collapses into its source
    /// (notch → panel): grow from the top edge + fade.
    static let emerge = AnyTransition.scale(scale: 0.85, anchor: .top).combined(with: .opacity)

    /// A bouncier spring for surfaces that POP out of / into their source — the
    /// notification cards bursting from the pill. The overshoot is the "funk."
    static let pop = Animation.spring(response: 0.36, dampingFraction: 0.56, blendDuration: 0)

    /// The "pop from the source" transition: the card starts small and tucked
    /// UP at the pill, then bursts out (scale from the top + slide down + fade)
    /// — and retracts back into the pill on the way out.
    static let popFromTop = AnyTransition.scale(scale: 0.4, anchor: .top)
        .combined(with: .offset(x: 0, y: -18))
        .combined(with: .opacity)
}
