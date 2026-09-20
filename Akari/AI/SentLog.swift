import Foundation
import CoreGraphics
import ImageIO

/// One request that left the Mac — what it was for, whether a screenshot went
/// with it (a ≤240 px thumbnail), and what it cost. Memory only: never written
/// to disk, gone when Akari quits (PROVIDERS.md "what was sent").
struct SentRecord: Identifiable, @unchecked Sendable {
    let id = UUID()
    let date: Date
    let provider: String
    let model: String
    /// The user's words for this request (or the one-shot's purpose).
    let label: String
    let promptChars: Int
    let imageThumbnail: CGImage?
    let imageBytes: Int
    var usage: CloudEngine.Usage

    var cost: Double? {
        AICost.estimate(model: model, input: usage.input, output: usage.output, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite)
    }

    /// Build the skeleton from a request; usage is filled in when the turn ends.
    nonisolated static func skeleton(for request: AIRequest, provider: String, model: String) -> SentRecord {
        let lastUser = request.messages.last(where: { $0.role == .user })
        var jpeg: Data? = nil
        for part in lastUser?.parts ?? [] { if case .image(let data, _) = part { jpeg = data; break } }
        let text = lastUser?.text ?? ""
        let label = request.label ?? String(text.split(separator: "\n").last ?? "").trimmingCharacters(in: .whitespaces)
        return SentRecord(date: Date(), provider: provider, model: model,
                          label: label.isEmpty ? "(no text)" : String(label.prefix(120)),
                          promptChars: request.messages.reduce(0) { $0 + $1.text.count },
                          imageThumbnail: jpeg.flatMap { thumbnail(from: $0) },
                          imageBytes: jpeg?.count ?? 0,
                          usage: CloudEngine.Usage())
    }

    /// Tiny preview from the encoded image — ImageIO downsamples without decoding the full frame.
    nonisolated static func thumbnail(from data: Data, maxPixel: Int = 240) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
