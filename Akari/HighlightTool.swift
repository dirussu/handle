import AppKit
import SwiftUI

/// The `highlight` tool — Akari's pointer draws a glowing outline around a
/// rectangular region of the screen capture and shows a message beside it (a
/// one-stop guided walkthrough). Mirrors `point_at`, but a RECT instead of a
/// point. The model gives the box in capture-image pixels; `run` maps it to
/// screen points and drives `MetaballPointer`.
///
/// NOTE: not yet reachable by the model — the tool-use loop (sending tools +
/// executing returned calls) is M3. When that lands, dispatch is one line:
///   `case "highlight": HighlightTools.run(try HighlightTools.decode(json), conversation: convo)`
@MainActor
enum HighlightTools {
    static var tools: [Tool] { [highlightTool] }

    static let highlightTool = Tool(
        name: "highlight",
        description: """
        Draw a glowing outline around a rectangular region of the screen capture and show a short message beside it — use this to SHOW the user a specific element ("here's the Send button", "this is your sidebar") rather than describing it in words.

        The rectangle is given in integer PIXELS in the screen capture's coordinate space: x, y (its top-left corner) plus width, height. The image's exact pixel dimensions are stated in a text block immediately before the image, like "Screen capture (image dimensions: 1280x800 pixels)". (0, 0) is the top-left of that image. Make the box hug the element tightly — a loose box looks wrong.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "x": ["type": "integer", "description": "Left edge of the box, in capture pixels."],
                "y": ["type": "integer", "description": "Top edge of the box, in capture pixels."],
                "width": ["type": "integer", "description": "Box width, in capture pixels."],
                "height": ["type": "integer", "description": "Box height, in capture pixels."],
                "label": ["type": "string", "description": "Short message shown beside the box (e.g. 'Send button'). One sentence max."],
            ],
            "required": ["x", "y", "width", "height", "label"]
        ],
        confirmation: .auto
    )

    struct HighlightInput: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let label: String
    }

    static func decode(_ json: String) throws -> HighlightInput {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "HighlightTools", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Tool input wasn't valid UTF-8."])
        }
        return try JSONDecoder().decode(HighlightInput.self, from: data)
    }

    /// Execute a `highlight` call: map the capture-pixel box to screen points and
    /// drive the pointer walkthrough. Returns a short result string for the model.
    @discardableResult
    static func run(_ input: HighlightInput, conversation: Conversation) -> String {
        guard let imageSize = conversation.currentImagePixelSize,
              conversation.captureRect != .zero else {
            return "Can't highlight — there's no active screen capture to map coordinates into."
        }
        let screen = conversation.captureScreen ?? PointingOverlay.currentScreen()
        let pixelRect = CGRect(x: input.x, y: input.y, width: input.width, height: input.height)
        let rect = PointingTools.screenRect(fromImagePixels: pixelRect,
                                            captureRect: conversation.captureRect,
                                            imagePixelSize: imageSize)
        MetaballPointer.shared.guide(steps: [GuideStep(rect: rect, message: input.label)], on: screen)
        return "Highlighted \"\(input.label)\" on screen."
    }
}
