import AppKit
import Combine
import SwiftUI
import os.log

/// A highlight target — the unified primitive. A circle, a pill, a card are all
/// just a rounded rectangle with a center, size, and corner radius. "Morphing"
/// between shapes is animating these three; a guided walkthrough is a sequence.
private struct Target: Equatable {
    var center: CGPoint
    var size: CGSize
    var cornerRadius: CGFloat
    var message: String
}

/// Measures the message bubble's size so it can be auto-placed — and kept fully
/// on-screen — relative to the highlighted shape.
private struct BubbleSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n.width > 0 { value = n }
    }
}

struct MetaballPointerView: View {
    let anchor: CGPoint       // notch/panel bottom-center (the spit origin)
    let steps: [GuideStep]    // the walkthrough stops — screen-space rects + messages
    let screenSize: CGSize       // the full overlay size — keeps the bubble on-screen
    let onFinished: () -> Void   // called when the tour finishes (retracted into the notch)
    // LISTENING mode: the same birth, but the droplet STAYS the solid black metaball
    // (no ring crossfade, no walkthrough) with dictation bars inside, until the
    // session's `ending` flips → reverse suck. The bars read the live mic level.
    var listening: Bool = false
    @ObservedObject var session: PointerSession = PointerSession()

    @State private var start: Date?
    // Walkthrough (state-driven; takes over once the birth settles). The glow
    // outline morphs through `steps`, a message bubble popping in at each stop.
    @State private var walkthrough = false
    @State private var target = Target(center: .zero, size: .zero, cornerRadius: 0, message: "")
    @State private var bubbleShown = false
    @State private var bubbleText = ""          // changed INSTANTLY while hidden — never animated, so the
                                                // text never reflows separately from its background
    @State private var bubbleSize: CGSize = CGSize(width: 200, height: 44)
    // Ending: the glow fades out (state-driven) while the reverse metaball "suck"
    // plays (time-driven from suckStart) — the whole birth run backwards.
    @State private var glowOpacity: Double = 1
    @State private var sucking = false
    @State private var suckStart: Date?

    // Gooeyness. Blur must stay well under the blob radius (~0.7×) or the
    // threshold erases the small droplet.
    private let blur: CGFloat = 8         // gooey smoothing ONLY. Keep ≤ ~0.5× fullR so the circle
                                          // stays ROUND. The long neck is drawn explicitly (below),
                                          // not conjured from blur reach — so blur can stay low.
    private let fullR: CGFloat = 16       // pointer radius once formed — small, clean
    // The source the neck pulls from — hidden inside the notch's center.
    private let sourceWidth: CGFloat = 50
    private let sourceHeight: CGFloat = 52 // tall enough to fully hide the droplet at the start
    private let sourceLift: CGFloat = 15  // hold the source ENTIRELY inside the notch (blur never
                                          // reaches the bottom edge → the notch stays untouched at rest)
    private let startInset: CGFloat = 42  // droplet starts this far UP inside the source (hidden)
    private let restDist: CGFloat = 46    // pulls FAR down before snapping — the "escape" reaches
    // The NECK is drawn explicitly so the notch keeps gripping the droplet across
    // the WHOLE descent (the "trying to escape" pull), then the thread snaps at
    // the last moment. It tapers from a fat grip at the lip to a thread at the drop.
    private let neckSnap: CGFloat = 40    // gap (lip→droplet-top) at which the thread breaks — holds
                                          // almost the whole pull, snapping just before the droplet
                                          // springs past rest (so the neck never flickers back).
    private let neckTopW: (CGFloat, CGFloat) = (34, 5)   // width at the notch lip: fat grip → wisp
    private let neckBotW: (CGFloat, CGFloat) = (24, 2)   // width at the droplet:  fat grip → fine thread
    private let neckPinch: CGFloat = 0.55 // concave waist (0 = straight sides, 1 = pinched to a point)
    // Grip → release with INERTIA. A decelerating creep grips and holds (neck
    // fat, tension building), then an underdamped spring carries the freed droplet
    // PAST rest and rings it down — the kinetic reaction that makes the snap feel
    // physical instead of stopping dead. The spring leaves the hold at zero
    // velocity, so there's no mechanical jolt; the overshoot is the released tension.
    private let gripDur: Double = 0.80          // creep + hold time before the thread lets go
    private let gripTo: Double = 0.78           // how far it has crept (of the full travel) at release
    private let springZeta: Double = 0.42       // damping: lower = bigger overshoot / more bounces
    private let springOmega: Double = 14.0      // stiffness: higher = quicker, snappier reaction
    // Once it settles, the solid black droplet crossfades into a TRANSPARENT circle
    // with a uniformly glowing white border (the comet's glow, but spread evenly
    // around the ring — no rotation) — the pointer's "live" resting state.
    private let ringWidth: CGFloat = 2.5
    private let ringFade: Double = 0.45         // black fill drains as the ring simply fades in (no pop)
    private var ringStart: Double { gripDur + 0.9 }  // begins once the spring has settled
    private let walkthroughStart: Double = 0.7  // seconds after the ring settles before the tour begins
    // The bubble's entrance: a slow, no-bounce spring so it drifts up + fades in
    // smoothly (high-end), rather than snapping.
    private let bubbleIn = Animation.spring(response: 0.55, dampingFraction: 0.9)
    // One house corner radius for every highlight outline — clamped per shape so
    // squares round to circles and thin bars round fully. (Consistent, not
    // per-element: the chosen approach.)
    private func houseRadius(_ s: CGSize) -> CGFloat { min(fullR, min(s.width, s.height) / 2) }
    var body: some View {
        ZStack {
            // Birth — the time-sampled metaball droplet + shockwave + pop-in ring.
            // The ring hands off to the walkthrough once it has settled.
            TimelineView(.animation) { timeline in
                let t = start.map { timeline.date.timeIntervalSince($0) } ?? 0
                let s = sample(t)
                let ring = clamp((t - ringStart) / ringFade)
                // Walkthrough: black drains as the ring fades in. Listening: the drop
                // STAYS black (the bars live inside it) until the suck takes over.
                let metaball = listening ? (sucking ? 0 : 1) : 1 - clamp((t - ringStart) / 0.22)
                let micLevel = CGFloat(SpeechService.shared.level)
                ZStack {
                    if metaball > 0.001 {
                        metaballCanvas(pos: s.pos, r: s.r).opacity(metaball)
                    }
                    // The birth ring — a SIMPLE crossfade (black drains, ring fades
                    // in; no pop, no bounce). Shown only until the walkthrough takes
                    // over from the exact same circle. Never in listening mode.
                    if !listening && !walkthrough && ring > 0.001 {
                        glowShape(size: CGSize(width: fullR * 2, height: fullR * 2), cornerRadius: fullR)
                            .position(x: anchor.x, y: anchor.y + restDist)
                            .opacity(ring)
                    }

                    // Dictation bars — inside the settled black drop, riding its
                    // position (so they follow the last spring wobble). Fade in where
                    // the ring would have; on release they MELT OUT over ~0.2s (the
                    // ring's fade, same beat) while the drop holds, before the rise.
                    if listening {
                        let meltOut = sucking
                            ? (suckStart.map { 1 - clamp(timeline.date.timeIntervalSince($0) / 0.2) } ?? 1)
                            : 1
                        let barAlpha = clamp((t - (gripDur + 0.45)) / 0.3) * meltOut
                        if barAlpha > 0.001 {
                            // During the suck's hold the drop sits at rest — pin the bars there.
                            let pos = sucking ? CGPoint(x: anchor.x, y: anchor.y + restDist) : s.pos
                            barsCanvas(pos: pos, level: micLevel, time: t, alpha: barAlpha)
                        }
                    }

                    // Ending — the reverse metaball: the droplet rises back up and
                    // is sucked into the notch. The neck re-forms on its own as it
                    // nears the source (same machinery as the birth, run upward).
                    // (Listening: the drop is already black at rest — no crossfade,
                    // full opacity from the first frame so there's no flicker.)
                    if sucking, let ss = suckStart {
                        let ts = timeline.date.timeIntervalSince(ss)
                        if ts >= 0 {
                            let sk = suckSample(ts)
                            metaballCanvas(pos: sk.pos, r: fullR).opacity(listening ? 1 : sk.opacity)
                        }
                    }
                }
            }

            // Walkthrough — the same glow outline, now morphing through scripted
            // targets with a message bubble at each stop. State-driven (springs).
            if walkthrough {
                let place = bubblePlacement(for: target)
                ZStack {
                    glowShape(size: target.size, cornerRadius: target.cornerRadius)
                        .position(target.center)
                        .opacity(glowOpacity)   // fades out as the reverse suck takes over

                    if !bubbleText.isEmpty {
                        messageBubble(bubbleText)
                            .compositingGroup()   // flatten text + background → they move/fade as ONE layer
                            .background(GeometryReader { g in
                                Color.clear.preference(key: BubbleSizeKey.self, value: g.size)
                            })
                            .position(place.center)
                            .offset(y: bubbleShown ? 0 : (place.below ? 16 : -16))   // drifts in from the far side
                            .opacity(bubbleShown ? 1 : 0)
                    }
                }
                .onPreferenceChange(BubbleSizeKey.self) { bubbleSize = $0 }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            start = Date()
            agentLog.info("pointer: view onAppear listening=\(listening, privacy: .public)")
            if !listening { runWalkthrough() }   // listening ends via session.ending, not a script
        }
        .onChange(of: session.ending) { _, ending in
            agentLog.info("pointer: onChange ending=\(ending, privacy: .public) sucking=\(sucking, privacy: .public)")
            if ending { beginSuck() }
        }
    }

    /// The deliberate ending, shared shape with the walkthrough's: reverse suck up
    /// into the notch, then dismiss. Used by listening mode (externally triggered).
    private func beginSuck() {
        guard !sucking else { agentLog.info("pointer: beginSuck IGNORED (already sucking)"); return }
        agentLog.info("pointer: beginSuck")
        suckStart = Date()
        sucking = true
        withAnimation(.easeOut(duration: 0.2)) { glowOpacity = 0 }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.05))   // rise + absorb
            agentLog.info("pointer: suck done -> dismiss")
            onFinished()
        }
    }

    /// The dictation bars — 5 compact white bars centered in the drop, amplitude-
    /// driven (symmetric envelope, idle shimmer so they breathe when quiet). ONE
    /// Canvas, no filters — cheap per frame, can't starve inference (comet lesson).
    private func barsCanvas(pos: CGPoint, level: CGFloat, time: Double, alpha: Double) -> some View {
        Canvas { ctx, _ in
            let barCount = 5
            let barW: CGFloat = 2.2, barGap: CGFloat = 2.2
            let span = CGFloat(barCount - 1) * (barW + barGap)
            let maxBar = fullR * 0.95, minBar: CGFloat = 2.5
            for i in 0..<barCount {
                let x = pos.x - span / 2 + CGFloat(i) * (barW + barGap)
                let d = abs(CGFloat(i) - CGFloat(barCount - 1) / 2) / (CGFloat(barCount - 1) / 2)
                let envelope = 1 - 0.45 * d
                let shimmer = 0.5 + 0.5 * sin(time * 6 + Double(i) * 0.9)
                let energy = level * envelope + CGFloat(shimmer) * 0.18 * envelope
                let h = max(minBar, min(maxBar, minBar + energy * (maxBar - minBar)))
                let bar = CGRect(x: x - barW / 2, y: pos.y - h / 2, width: barW, height: h)
                ctx.fill(Path(roundedRect: bar, cornerRadius: barW / 2),
                         with: .color(.white.opacity(alpha)))
            }
        }
    }

    /// The liquid metaball — source bar + stretching neck + droplet, fused by the
    /// blur + alpha-threshold trick. Drawn through the spit-out + settle, then
    /// removed from the tree once it has drained into the ring.
    private func metaballCanvas(pos: CGPoint, r: CGFloat) -> some View {
        Canvas { ctx, _ in
            ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
            ctx.addFilter(.blur(radius: blur))
            ctx.drawLayer { c in
                let source = CGRect(x: anchor.x - sourceWidth / 2, y: anchor.y - sourceLift - sourceHeight,
                                    width: sourceWidth, height: sourceHeight)
                c.fill(Path(roundedRect: source, cornerRadius: 18), with: .color(.black))

                // The stretching neck: appears once the droplet clears the notch
                // lip, grips across the whole descent, then pinches off at the last
                // moment (pow > 1 keeps it fat, then necks down fast).
                let lip = anchor.y - sourceLift
                let dropTop = pos.y - r
                let gap = dropTop - lip
                if gap > 0 && gap < neckSnap {
                    let pinch = pow(clamp(Double(gap / neckSnap)), 1.6)
                    c.fill(neckPath(cx: anchor.x, top: lip - 3, bottom: dropTop + 6,
                                    wTop: lerp(neckTopW.0, neckTopW.1, pinch),
                                    wBot: lerp(neckBotW.0, neckBotW.1, pinch)),
                           with: .color(.black))
                }

                if r > 0.5 {
                    c.fill(Path(ellipseIn: CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)),
                           with: .color(.black))
                }
            }
        }
    }

    /// The glow outline — the unified shape, generalized from the ring to ANY
    /// rounded rectangle (a circle is just `cornerRadius = side/2`). Soft + tight
    /// white strokes, blurred, but masked so the glow blooms only OUTWARD — the
    /// inner area stays transparent so it never veils what it's highlighting.
    private func glowShape(size: CGSize, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        return ZStack {
            ZStack {
                shape.stroke(Color.white, lineWidth: ringWidth + 2)
                    .frame(width: size.width, height: size.height).blur(radius: 8)
                shape.stroke(Color.white, lineWidth: ringWidth)
                    .frame(width: size.width, height: size.height).blur(radius: 3)
            }
            .mask(outwardOnly(size: size, cornerRadius: cornerRadius))

            shape.stroke(Color.white, lineWidth: ringWidth)
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Keeps everything EXCEPT a clean inner shape — so the glow blooms only
    /// outward and never veils the highlighted area. The hole is the outline's
    /// inner edge (the shape inset by half the stroke).
    private func outwardOnly(size: CGSize, cornerRadius: CGFloat) -> some View {
        Rectangle()
            .frame(width: size.width + 90, height: size.height + 90)   // keep the whole outward bloom
            .overlay {
                RoundedRectangle(cornerRadius: max(0, cornerRadius - ringWidth / 2), style: .circular)
                    .frame(width: size.width - ringWidth, height: size.height - ringWidth)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
    }

    /// The black message bubble that sits just below the highlighted shape.
    private func messageBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
    }

    /// The bubble hangs off a CORNER of the highlighted shape (extending outward),
    /// not centered below it. Prefers the bottom-right corner, then falls back
    /// through the other three so it always stays fully on-screen. `below` (does it
    /// sit beneath the shape) drives which way it drifts in.
    private func bubblePlacement(for shape: Target) -> (center: CGPoint, below: Bool) {
        let margin: CGFloat = 16, gap: CGFloat = 4   // small — the bubble tucks up against the corner
        let bw = bubbleSize.width, bh = bubbleSize.height
        let left = shape.center.x - shape.size.width / 2
        let right = shape.center.x + shape.size.width / 2
        let top = shape.center.y - shape.size.height / 2
        let bottom = shape.center.y + shape.size.height / 2
        // Bubble top-left origin for each corner, in preference order.
        let corners: [(x: CGFloat, y: CGFloat, below: Bool)] = [
            (right + gap, bottom + gap, true),         // bottom-right: extend right + down
            (left - gap - bw, bottom + gap, true),     // bottom-left:  extend left + down
            (right + gap, top - gap - bh, false),      // top-right:    extend right + up
            (left - gap - bw, top - gap - bh, false),  // top-left:     extend left + up
        ]
        let safe = CGRect(x: margin, y: margin,
                          width: screenSize.width - 2 * margin, height: screenSize.height - 2 * margin)
        for c in corners where safe.contains(CGRect(x: c.x, y: c.y, width: bw, height: bh)) {
            return (CGPoint(x: c.x + bw / 2, y: c.y + bh / 2), c.below)
        }
        // Fallback: clamp the preferred bottom-right corner fully on-screen.
        let cx = min(max(right + gap, margin), screenSize.width - margin - bw) + bw / 2
        let cy = min(max(bottom + gap, margin), screenSize.height - margin - bh) + bh / 2
        return (CGPoint(x: cx, y: cy), true)
    }

    // MARK: Guided walkthrough

    /// The stops as `Target`s — each highlight rect's center + size + the house
    /// corner radius. The model (or the demo) supplies the rects via `steps`.
    private var targets: [Target] {
        steps.map { s in
            Target(center: CGPoint(x: s.rect.midX, y: s.rect.midY),
                   size: s.rect.size,
                   cornerRadius: houseRadius(s.rect.size),
                   message: s.message)
        }
    }

    private func runWalkthrough() {
        Task { @MainActor in
            // Born into the ring; hand off to the birth circle (no bubble yet),
            // from the exact same circle so the swap is invisible.
            try? await Task.sleep(for: .seconds(ringStart + walkthroughStart))
            target = restCircle
            walkthrough = true
            try? await Task.sleep(for: .seconds(0.4))

            // Morph through each highlight: morph (text swaps while hidden) →
            // bubble in → dwell → bubble out.
            for step in targets {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { target = step }
                bubbleText = step.message        // swap INSTANTLY while hidden — no animated reflow
                try? await Task.sleep(for: .seconds(0.55))            // let the morph + layout settle
                withAnimation(bubbleIn) { bubbleShown = true }
                try? await Task.sleep(for: .seconds(2.4))             // dwell
                withAnimation(.easeInOut(duration: 0.32)) { bubbleShown = false }
                bubbleText = ""
                try? await Task.sleep(for: .seconds(0.34))
            }

            // Deliberate ending — the birth in REVERSE. Home to the birth circle,
            // turn back into the black droplet, get sucked up into the notch.
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { target = restCircle }
            try? await Task.sleep(for: .seconds(0.7))
            suckStart = Date()
            sucking = true
            withAnimation(.easeOut(duration: 0.2)) { glowOpacity = 0 }
            try? await Task.sleep(for: .seconds(1.05))   // crossfade + rise + absorb
            onFinished()
        }
    }

    /// The birth circle, just below the notch — where the pointer is born and
    /// where it returns to be sucked back in.
    private var restCircle: Target {
        Target(center: CGPoint(x: anchor.x, y: anchor.y + restDist),
               size: CGSize(width: fullR * 2, height: fullR * 2), cornerRadius: fullR, message: "")
    }

    /// The reverse suck — the droplet rises from rest back UP into the source,
    /// accelerating (sucked in). It crossfades in from the glow first, then climbs;
    /// `metaballCanvas` re-forms the neck + absorbs it as it nears the notch.
    private func suckSample(_ ts: Double) -> (pos: CGPoint, opacity: Double) {
        let crossfade = 0.25, riseDur = 0.7
        let rise = clamp((ts - crossfade) / riseDur)
        let p = rise * rise                       // easeIn — accelerates UP as it's pulled in
        let restY = anchor.y + restDist
        let intoY = anchor.y - startInset         // up inside the source (absorbed, behind the notch)
        let y = restY + (intoY - restY) * CGFloat(p)
        return (CGPoint(x: anchor.x, y: y), clamp(ts / 0.15))   // black fades in as the glow fades out
    }

    /// Birth only — sampled from elapsed seconds. The source bar is constant, so
    /// the connection "removes itself" purely through the neck thinning.
    ///   • grip + hold (0–gripDur): the droplet creeps out, the fat neck holding on.
    ///   • release (gripDur+): the thread snaps; the freed droplet springs past
    ///     rest and rings down (inertia), then the label fades in.
    private func sample(_ t: Double) -> (pos: CGPoint, r: CGFloat) {
        // The droplet is ALWAYS full size; it starts hidden inside the source bar
        // and travels out through the bottom edge — always part of the metaball
        // mass, never inflating or popping into existence.
        let startY = anchor.y - startInset
        let endY = anchor.y + restDist
        let p = travelEase(t)
        return (CGPoint(x: anchor.x, y: startY + (endY - startY) * CGFloat(p)), fullR)
    }

    private func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(max(x, lo), hi) }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    /// A tapering, concave-waisted strand from the notch lip (`top`, width `wTop`)
    /// down into the droplet (`bottom`, width `wBot`). The sides bow toward the
    /// center axis (`neckPinch`) so the stretched neck reads as liquid, not a wedge.
    private func neckPath(cx: CGFloat, top: CGFloat, bottom: CGFloat, wTop: CGFloat, wBot: CGFloat) -> Path {
        let tl = CGPoint(x: cx - wTop / 2, y: top),  tr = CGPoint(x: cx + wTop / 2, y: top)
        let bl = CGPoint(x: cx - wBot / 2, y: bottom), br = CGPoint(x: cx + wBot / 2, y: bottom)
        let midY = (top + bottom) / 2
        let lMid = (tl.x + bl.x) / 2, rMid = (tr.x + br.x) / 2
        let lCtrl = lMid + (cx - lMid) * neckPinch   // pull each side in at the waist
        let rCtrl = rMid + (cx - rMid) * neckPinch
        var p = Path()
        p.move(to: tl)
        p.addQuadCurve(to: bl, control: CGPoint(x: lCtrl, y: midY))
        p.addLine(to: br)
        p.addQuadCurve(to: tr, control: CGPoint(x: rCtrl, y: midY))
        p.closeSubpath()
        return p
    }

    /// Tension → release. The build decelerates to a near-stall (the neck
    /// stretches thin), then the release snaps out fast and overshoots back.
    /// Grip → release with inertia. The creep decelerates into a hold (tension,
    /// neck fat), then an underdamped spring carries the freed droplet past rest,
    /// bounces, and rings down to settle.
    private func travelEase(_ t: Double) -> Double {
        if t < gripDur {
            let b = t / gripDur
            return gripTo * (1 - (1 - b) * (1 - b))             // easeOut creep → hold (tension)
        } else {
            return gripTo + (1 - gripTo) * springStep(t - gripDur, zeta: springZeta, omega: springOmega)
        }
    }

    /// Underdamped spring step (0→1 with overshoot). springStep'(0) = 0, so it
    /// leaves rest smoothly (no jolt); then it overshoots and rings down. Used for
    /// the droplet's kinetic settle AND the ring's pop-in bounce.
    private func springStep(_ s: Double, zeta: Double, omega: Double) -> Double {
        let wd = omega * (1 - zeta * zeta).squareRoot()
        let e = exp(-zeta * omega * s)
        return 1 - e * (cos(wd * s) + (zeta * omega / wd) * sin(wd * s))
    }
}
