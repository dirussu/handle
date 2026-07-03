import Foundation
import AVFoundation
import Combine
import WhisperKit
import os.log

private let voiceLog = Logger(subsystem: "com.dimarussu.Akari", category: "Agent")

/// On-device speech-to-text via WhisperKit (CoreML Whisper) — the ear for push-to-talk
/// voice. Raw mic audio is transcribed by a CoreML model ON THIS MAC; nothing audible
/// ever leaves the device (contrast HeyClicky → AssemblyAI). The model downloads once
/// (~150 MB for "base"), then stays resident. WhisperKit's own AudioProcessor supplies
/// the tested mic→16 kHz-mono pipeline, so we don't hand-roll audio conversion.
@MainActor
final class SpeechService: ObservableObject {
    static let shared = SpeechService()
    private init() {}

    enum State: Equatable { case idle, loading, recording, transcribing, failed(String) }
    @Published private(set) var state: State = .idle

    /// Whisper model. Quantized turbo-large (~630 MB): near-best accuracy, and the
    /// "turbo" decoder keeps a push-to-talk clip's transcription well under a second on
    /// Apple Silicon. Chosen over "base" (which misheard "empty the trash" as "Antiva
    /// Trash" on synthetic speech) since voice was picked FOR accuracy. Swappable.
    private let modelName = "large-v3-v20240930_turbo_632MB"
    private var whisperKit: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?

    var isLoaded: Bool { whisperKit != nil }

    /// Lazy-load the model (downloads the CoreML weights on first use, like the VL model).
    func ensureModel() async throws -> WhisperKit {
        if let wk = whisperKit { return wk }
        if let t = loadTask { return try await t.value }
        let t = Task { () throws -> WhisperKit in
            state = .loading
            voiceLog.info("voice: loading WhisperKit \(self.modelName, privacy: .public)…")
            let wk = try await WhisperKit(WhisperKitConfig(model: self.modelName, verbose: false, logLevel: .error))
            voiceLog.info("voice: WhisperKit ready")
            return wk
        }
        loadTask = t
        do {
            let wk = try await t.value
            whisperKit = wk
            loadTask = nil
            if state == .loading { state = .idle }
            return wk
        } catch {
            loadTask = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Push-to-talk

    /// Begin capturing mic audio. First call triggers the macOS Microphone prompt.
    func startRecording() async {
        do {
            let wk = try await ensureModel()
            wk.audioProcessor.purgeAudioSamples(keepingLast: 0)
            try wk.audioProcessor.startRecordingLive(callback: nil)
            state = .recording
            voiceLog.info("voice: recording")
        } catch {
            state = .failed(error.localizedDescription)
            voiceLog.error("voice: start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stop capture and transcribe the buffered audio. Returns cleaned text (empty on
    /// silence, too-short clips, or failure).
    @discardableResult
    func stopRecordingAndTranscribe() async -> String {
        guard let wk = whisperKit, state == .recording else { return "" }
        wk.audioProcessor.stopRecording()
        let samples = Array(wk.audioProcessor.audioSamples)
        guard samples.count > 8000 else {   // < 0.5 s at 16 kHz = an accidental tap
            state = .idle
            voiceLog.info("voice: clip too short (\(samples.count) samples) — ignoring")
            return ""
        }
        state = .transcribing
        do {
            let results = try await wk.transcribe(audioArray: samples)
            state = .idle
            let text = Self.clean(results.map(\.text).joined(separator: " "))
            voiceLog.info("voice: transcript=\"\(text, privacy: .public)\"")
            return text
        } catch {
            state = .failed(error.localizedDescription)
            voiceLog.error("voice: transcribe failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// Transcribe an audio FILE — the headless test path (a `say`-generated clip).
    func transcribe(fileURL: URL) async -> String {
        do {
            let wk = try await ensureModel()
            let results = try await wk.transcribe(audioPath: fileURL.path)
            return Self.clean(results.map(\.text).joined(separator: " "))
        } catch {
            voiceLog.error("voice: file transcribe failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// Whisper brackets non-speech as "[BLANK_AUDIO]", "(silence)", "[Music]" etc. and
    /// pads with spaces — strip those so the transcript is a clean command string.
    static func clean(_ raw: String) -> String {
        var t = raw
        for pat in ["\\[[^\\]]*\\]", "\\([^\\)]*\\)", "<\\|[^>]*\\|>"] {
            t = t.replacingOccurrences(of: pat, with: "", options: .regularExpression)
        }
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
