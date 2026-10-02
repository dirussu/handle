import Vision
import CoreGraphics

enum OCR {
    /// Runs Apple's accurate OCR on the image and returns the recognized text,
    /// joined with newlines (top-to-bottom by detection order).
    static func recognize(in image: CGImage) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
        }.value

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
