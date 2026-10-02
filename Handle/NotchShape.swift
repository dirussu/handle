import SwiftUI

/// The notch silhouette — adapted from Boring Notch (originally
/// DynamicNotchKit). The top corners flare OUTWARD (inverse radius) so the
/// pill blends seamlessly into the hardware notch / screen bezel, and the
/// bottom corners round normally. Both radii animate so the shape morphs
/// smoothly between the closed pill and the open panel.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left: flare outward into the bezel.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))

        // Bottom-left: round normally.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))

        // Bottom-right: round normally.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))

        // Top-right: flare outward into the bezel.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}


/// The VISIBLE outline of the notch as an OPEN path — left side down, around
/// the bottom-left corner, across the bottom, around the bottom-right corner,
/// up the right side. The flared top edge is omitted (it merges into the
/// bezel). trim=0 is the upper-left, trim=1 the upper-right — so a comet
/// sweeping 0→1→0 reads as a clean side-to-side along the notch's underside.
struct NotchBottomOutline: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius))
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        return path
    }
}

/// Handle's "working" cue — a hot white head + fading gradient tail with a soft
/// both-sided glow, riding a shape's border. Generic over the shape AND the
/// motion:
///   • `loops: true`  → orbits a closed shape continuously (the input bubble).
///   • `loops: false` → sweeps an open path side-to-side, easing at each end,
///     the tail collapsing into the head at the turnarounds (the notch).
/// Identical visual style in both; only the motion differs.
struct BorderComet<S: Shape>: View {
    var shape: S
    var loops: Bool
    var period: Double = 7.6
    var tailLength: CGFloat = 0.18    // fraction of the path the tail spans
    var lineWidth: CGFloat = 1.2      // head thickness (tail scales from this)
    var glow: Double = 0.75           // glow intensity (the tight shadow's opacity)

    private let segments = 72   // fine enough that per-segment width/opacity steps
                                // vanish (52 scalloped on curves; the fix
                                // is mostly the BUTT caps, so 96 wasn't needed and
                                // its draw cost competed with inference)
    /// The comet rides the shape's BORDER, so half its stroke and all of its
    /// outer glow live OUTSIDE the given bounds — and a Canvas clips to its
    /// bounds, which swallowed the outer bloom around curves (seen in a
    /// screenshot, 2026-07-10: "hides behind something"). The canvas extends
    /// past the slot by this much; the path is drawn inset back to the
    /// original geometry, so the border lands exactly where it always did.
    private let overscan: CGFloat = 12

    var body: some View {
        TimelineView(.animation) { timeline in
            let u = (timeline.date.timeIntervalSinceReferenceDate / period)
                .truncatingRemainder(dividingBy: 1)
            let m = motion(at: u)   // (head, dir, tailScale)
            let step = (tailLength * m.tailScale) / CGFloat(segments)

            // Draw the whole comet in ONE Canvas (imperative path stroking) instead
            // of ~50–100 SwiftUI trim/stroke views per frame — those re-diffed every
            // frame at 120fps and saturated the main thread, starving the inference
            // stream (the "app doesn't respond" hang). Visual is identical.
            Canvas { ctx, size in
                let path = shape.path(in: CGRect(x: overscan, y: overscan,
                                                 width: size.width - overscan * 2,
                                                 height: size.height - overscan * 2))
                // Gradient tail — fine BUTT-capped ribbon segments with a small
                // overlap. Round caps at 52-segment pitch scalloped on curves
                // (seen in a screenshot): neighbouring caps splay at slightly
                // different widths. Butt caps + 96 segments + 2-step overlap
                // tile into one continuous tapered ribbon. Fade AND width taper
                // together — a real comet thins to nothing at the tip.
                for i in stride(from: segments - 1, through: 0, by: -1) {
                    let f = CGFloat(i)
                    let t = 1 - f / CGFloat(segments)          // 0 at the tip → 1 at the head
                    let fade = pow(Double(t), 2.6)
                    // Body brightness caps at 0.7, then a steep end-blend lifts the
                    // last ~15% to EXACTLY the head's 1.0 — the flat 0.7 ramp left a
                    // visible brightness seam where the head stroke ended (seen in a
                    // screenshot: "not smooth at the nose").
                    let alpha = min(1.0, fade * 0.7 + pow(Double(t), 10) * 0.35)
                    let width = lineWidth * (0.2 + 0.8 * t)    // hairline tip → FULL width at the head
                    strokeComet(ctx, path, m.head - m.dir * (f + 2) * step, m.head - m.dir * f * step,
                                color: .white.opacity(alpha), width: width, cap: .butt)
                }
                // Bright head at the SAME width the tail ramps into — round cap
                // for the clean nose; the glow shadows carry the head emphasis.
                strokeComet(ctx, path, m.head - 0.006, m.head + 0.006, color: .white, width: lineWidth)
            }
            .padding(-overscan)   // grow the canvas past the slot; the inset above restores the geometry
            // Soft glow via shadow — blooms symmetrically on both sides.
            .shadow(color: .white.opacity(glow), radius: 3)
            .shadow(color: .white.opacity(glow * 0.6), radius: 7)
        }
        .allowsHitTesting(false)
    }

    /// Head position, travel direction, and tail-length scale for the current
    /// phase `u` (0…1). Plain function (not in the ViewBuilder) so the
    /// orbit-vs-sweep branch doesn't confuse the result builder.
    private func motion(at u: Double) -> (head: CGFloat, dir: CGFloat, tailScale: CGFloat) {
        if loops {
            return (CGFloat(u), 1, 1)   // orbit: forward, full tail
        }
        // Sweep: triangle 0→1→0, smoothstepped (eases at the turnarounds);
        // tail collapses into the head as speed → 0 at each end.
        let tri = u < 0.5 ? u * 2 : 2 - u * 2
        let head = CGFloat(tri * tri * (3 - 2 * tri))
        let dir: CGFloat = u < 0.5 ? 1 : -1
        let tailScale = CGFloat(0.08 + 0.92 * (4 * tri * (1 - tri)))
        return (head, dir, tailScale)
    }

    /// Stroke the comet's [from,to] span into the Canvas (one range, or two when an
    /// orbit wraps the 0/1 seam).
    private func strokeComet(_ ctx: GraphicsContext, _ path: Path, _ from: CGFloat, _ to: CGFloat,
                             color: Color, width: CGFloat, cap: CGLineCap = .round) {
        for r in ranges(from, to) {
            ctx.stroke(path.trimmedPath(from: r.0, to: r.1),
                       with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: cap))
        }
    }

    /// Orbit wraps across the 0/1 seam; sweep clamps to the open path's [0,1].
    private func ranges(_ from: CGFloat, _ to: CGFloat) -> [(CGFloat, CGFloat)] {
        if loops {
            func mod1(_ x: CGFloat) -> CGFloat {
                let r = x.truncatingRemainder(dividingBy: 1)
                return r < 0 ? r + 1 : r
            }
            let a = mod1(from), b = mod1(to)
            return a <= b ? [(a, b)] : [(a, 1), (0, b)]
        } else {
            let lo = max(0, min(from, to)), hi = min(1, max(from, to))
            return hi > lo ? [(lo, hi)] : []
        }
    }
}
