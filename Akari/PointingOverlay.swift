import AppKit
import SwiftUI

/// Full-screen, click-through overlay panel that animates a glowing cursor
/// to a target point and shows an optional label. Auto-fades after a few seconds.
@MainActor
final class PointingOverlay {
    static let shared = PointingOverlay()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private init() {}

    /// Point at a coordinate. `point` is in *display top-left points* on `screen`
    /// (matches the coordinate space of a captured region).
    func point(at point: CGPoint, on screen: NSScreen, label: String?) {
        // Tear down any existing pointer first.
        clear()

        let panel = ClickThroughPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // SwiftUI inside NSHostingView uses TOP-LEFT origin (SwiftUI's standard
        // convention). Our display points are also top-left, so the target maps
        // through directly without a flip.
        let target = point

        // NSEvent.mouseLocation is in screen-global *bottom-left* coords. Convert
        // to top-left within this screen so the cursor starts at the user's actual
        // mouse position in the SwiftUI coordinate space.
        let mouseGlobal = NSEvent.mouseLocation
        let mouseLocalX = mouseGlobal.x - screen.frame.origin.x
        let mouseLocalY = mouseGlobal.y - screen.frame.origin.y
        let startInView = CGPoint(
            x: mouseLocalX,
            y: screen.frame.height - mouseLocalY
        )

        let view = PointerView(start: startInView, target: target, label: label ?? "")
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.contentView = host

        panel.alphaValue = 1.0
        panel.orderFrontRegardless()
        self.panel = panel

        // Auto-fade after 3.6s (giving the animation time to land + breathe).
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.6))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    /// Find the screen with the cursor currently on it (used as a default target).
    static func currentScreen() -> NSScreen {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main!
    }

    private func clear() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.clear()
        })
    }
}

/// Borderless panel that stays out of the user's way.
final class ClickThroughPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Tool schema + handler

@MainActor
enum PointingTools {
    static var tools: [Tool] { [pointAtTool] }

    static let pointAtTool = Tool(
        name: "point_at",
        description: """
        Show a glowing cursor + optional label at a coordinate in the screen capture. Use this whenever the user asks "where is X?", "how do I click Y?", or "show me Z" — point at the pixel rather than describing it.

        Coordinates are integer PIXELS in the screen capture's coordinate space. The image's exact pixel dimensions are stated in a text block immediately preceding the image, like "Screen capture (image dimensions: 1280x800 pixels)". (0, 0) is the top-left corner of that image; (image_width, image_height) is the bottom-right. x and y must be integers within those bounds.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "x": [
                    "type": "integer",
                    "description": "X pixel coordinate in the screen capture (0 = left edge of the image)."
                ],
                "y": [
                    "type": "integer",
                    "description": "Y pixel coordinate in the screen capture (0 = top edge of the image)."
                ],
                "label": [
                    "type": "string",
                    "description": "Short text shown near the pointer (e.g. 'Send button'). Max ~30 chars."
                ],
            ],
            "required": ["x", "y"]
        ],
        confirmation: .auto
    )

    struct PointAtInput: Decodable {
        let x: Double
        let y: Double
        let label: String?
    }

    static func decode(_ json: String) throws -> PointAtInput {
        guard let data = json.data(using: .utf8) else {
            throw NSError(
                domain: "PointingTools",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Tool input wasn't valid UTF-8."]
            )
        }
        return try JSONDecoder().decode(PointAtInput.self, from: data)
    }

    // MARK: - Capture-pixel → screen-point mapping
    //
    // The model picks coordinates in the screen-capture IMAGE's pixel space; the
    // overlay lives in display points (top-left origin). The active capture's
    // `captureRect` (where, in points, the capture came from) and its
    // `imagePixelSize` (the image's exact pixel dims) give a simple affine map.

    /// A single image-pixel point → display point.
    static func screenPoint(fromImagePixel p: CGPoint, captureRect: CGRect, imagePixelSize: CGSize) -> CGPoint {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return captureRect.origin }
        return CGPoint(x: captureRect.minX + p.x / imagePixelSize.width * captureRect.width,
                       y: captureRect.minY + p.y / imagePixelSize.height * captureRect.height)
    }

    /// An image-pixel rect → display-point rect (same map, generalized).
    static func screenRect(fromImagePixels r: CGRect, captureRect: CGRect, imagePixelSize: CGSize) -> CGRect {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return .zero }
        let sx = captureRect.width / imagePixelSize.width
        let sy = captureRect.height / imagePixelSize.height
        return CGRect(x: captureRect.minX + r.minX * sx,
                      y: captureRect.minY + r.minY * sy,
                      width: r.width * sx, height: r.height * sy)
    }
}

// MARK: - SwiftUI pointer

private struct PointerView: View {
    let start: CGPoint
    let target: CGPoint
    let label: String

    @State private var animatedPoint: CGPoint = .zero
    @State private var pulseScale: CGFloat = 0.4
    @State private var pulseOpacity: Double = 0
    @State private var labelOpacity: Double = 0
    @State private var dotScale: CGFloat = 0.0

    var body: some View {
        ZStack {
            // Outer pulse ring — expanding fade.
            Circle()
                .stroke(.white, lineWidth: 2)
                .frame(width: 36, height: 36)
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)
                .position(animatedPoint)

            // Mid pulse ring (slightly delayed).
            Circle()
                .stroke(.white.opacity(0.7), lineWidth: 1.5)
                .frame(width: 36, height: 36)
                .scaleEffect(pulseScale * 0.7)
                .opacity(pulseOpacity * 0.6)
                .position(animatedPoint)

            // Inner solid white dot. A dark shadow keeps it visible on light
            // backgrounds; a soft white halo reads on dark ones — grayscale
            // only, visible over any screen content (white-only per DESIGN).
            Circle()
                .fill(.white)
                .frame(width: 14, height: 14)
                .shadow(color: .black.opacity(0.45), radius: 6)
                .shadow(color: .white.opacity(0.55), radius: 16)
                .scaleEffect(dotScale)
                .position(animatedPoint)

            // Label — solid black pill (matches the notch surface), legible
            // over any background.
            if !label.isEmpty {
                Text(label)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black, in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1) }
                    .opacity(labelOpacity)
                    .position(x: animatedPoint.x, y: max(animatedPoint.y - 28, 18))
            }
        }
        .ignoresSafeArea()
        .onAppear { runAnimation() }
    }

    private func runAnimation() {
        // Initial state.
        animatedPoint = start
        dotScale = 0.0
        pulseScale = 0.4
        pulseOpacity = 0
        labelOpacity = 0

        // 1. Dot appears + flies to the target along an ease-out curve.
        withAnimation(.spring(duration: 0.7, bounce: 0.25)) {
            dotScale = 1.0
            animatedPoint = target
        }

        // 2. After the cursor lands, label fades in.
        withAnimation(.easeIn(duration: 0.18).delay(0.55)) {
            labelOpacity = 1.0
        }

        // 3. After arrival, two pulse rings expand outward.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.55))
            for _ in 0..<2 {
                pulseScale = 0.4
                pulseOpacity = 0.85
                withAnimation(.easeOut(duration: 1.1)) {
                    pulseScale = 2.6
                    pulseOpacity = 0
                }
                try? await Task.sleep(for: .seconds(0.55))
            }
        }
    }
}
