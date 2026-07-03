import SwiftUI

/// The listening indicator: a gooey black drop that hangs from the notch's bottom edge
/// with white audio bars inside, reacting to the live mic level. It replaces the
/// "working" comet while recording — bars say "I'm hearing you," the comet says
/// "thinking." Everything is drawn in ONE `Canvas` (the blob's blur+alpha-threshold
/// metaball AND the bars), not a stack of animated views — the same single-layer
/// discipline the comet-hang taught us, so it can't starve the model's inference stream.
///
/// The drop reads the mic amplitude from `SpeechService.shared.level` each frame; bars
/// pop on speech and idle-shimmer when quiet so it never looks frozen.
struct VoiceOrbView: View {
    /// Overall canvas size; the drop is centered horizontally and hangs near the bottom.
    var body: some View {
        TimelineView(.animation) { timeline in
            // Read amplitude + time in the (main-actor) body, pass plain values into Canvas.
            let level = CGFloat(SpeechService.shared.level)
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in Self.draw(ctx, size: size, level: level, time: t) }
        }
        .allowsHitTesting(false)
    }

    // Geometry
    private static let dropR: CGFloat = 26      // drop radius
    private static let lipW: CGFloat = 46       // width of the bulge that merges with the pill
    private static let barCount = 7
    private static let barW: CGFloat = 4.2
    private static let barGap: CGFloat = 3.4

    private static func draw(_ ctx: GraphicsContext, size: CGSize, level: CGFloat, time: Double) {
        let cx = size.width / 2
        // The drop sits so its top meets the pill lip; the lip is drawn ABOVE y=0 area
        // (the view overlaps the pill), the drop below.
        let lipY: CGFloat = 6
        let dropCY = lipY + dropR + 10
        let dropCenter = CGPoint(x: cx, y: dropCY)

        // 1. Gooey black mass: lip + neck + drop, blurred then alpha-thresholded so the
        //    three merge into one connected shape with a pinched neck (the metaball look).
        ctx.drawLayer { layer in
            layer.addFilter(.alphaThreshold(min: 0.5, color: .black))
            layer.addFilter(.blur(radius: 7))
            // Lip — a wide short bulge at the top, overlapping the pill so it reads as
            // one mass with the notch above.
            let lip = CGRect(x: cx - lipW / 2, y: lipY - 22, width: lipW, height: 34)
            layer.fill(Path(roundedRect: lip, cornerRadius: 16), with: .color(.black))
            // Neck — a trapezoid from the lip down to the drop; blur pinches its waist.
            var neck = Path()
            neck.move(to: CGPoint(x: cx - 16, y: lipY + 4))
            neck.addLine(to: CGPoint(x: cx + 16, y: lipY + 4))
            neck.addLine(to: CGPoint(x: cx + dropR * 0.7, y: dropCY))
            neck.addLine(to: CGPoint(x: cx - dropR * 0.7, y: dropCY))
            neck.closeSubpath()
            layer.fill(neck, with: .color(.black))
            // Drop
            layer.fill(Path(ellipseIn: CGRect(x: cx - dropR, y: dropCY - dropR, width: dropR * 2, height: dropR * 2)),
                       with: .color(.black))
        }

        // 2. Audio bars inside the drop (drawn on top, unfiltered). Symmetric envelope
        //    (center bars taller), amplitude-scaled, with a per-bar idle shimmer.
        let span = CGFloat(barCount - 1) * (barW + barGap)
        let maxBar = dropR * 1.35
        let minBar: CGFloat = 6
        for i in 0..<barCount {
            let x = cx - span / 2 + CGFloat(i) * (barW + barGap)
            // Envelope: 1 at center → ~0.55 at edges.
            let d = abs(CGFloat(i) - CGFloat(barCount - 1) / 2) / (CGFloat(barCount - 1) / 2)
            let envelope = 1 - 0.45 * d
            // Idle shimmer so bars breathe when quiet; each bar a different phase.
            let shimmer = 0.5 + 0.5 * sin(time * 6 + Double(i) * 0.9)
            let energy = level * envelope + CGFloat(shimmer) * 0.18 * envelope
            let h = max(minBar, min(maxBar, minBar + energy * (maxBar - minBar)))
            let bar = CGRect(x: x - barW / 2, y: dropCenter.y - h / 2, width: barW, height: h)
            ctx.fill(Path(roundedRect: bar, cornerRadius: barW / 2), with: .color(.white))
        }
    }
}
