import Foundation
import AVFoundation

/// On-device text-to-speech for spoken replies — the voice OUT half. Uses Apple's
/// `AVSpeechSynthesizer`: fully local, zero download, no cloud (contrast HeyClicky →
/// ElevenLabs). Gated by the `Speak replies` setting; only spoken when voice is used.
@MainActor
final class SpeechSynth {
    static let shared = SpeechSynth()
    private let synth = AVSpeechSynthesizer()
    private init() {}

    /// Speak `text`, cancelling anything mid-utterance. Long replies are trimmed to a
    /// sane spoken length — nobody wants a screen-reading essay read aloud.
    func speak(_ text: String) {
        let clean = Self.spokenForm(text)
        guard !clean.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: clean)
        // Prefer a high-quality/enhanced voice for the user's locale when installed.
        u.voice = Self.preferredVoice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    func stop() { if synth.isSpeaking { synth.stopSpeaking(at: .immediate) } }

    /// Strip markdown noise and cap length so replies read naturally aloud.
    static func spokenForm(_ text: String, maxChars: Int = 600) -> String {
        var t = text
        // Drop code blocks entirely (don't read code aloud); keep the TEXT of inline
        // code and links, strip only their markup.
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_#>|]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
             .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > maxChars {
            let cut = String(t.prefix(maxChars))
            // Prefer to end on a sentence boundary.
            if let dot = cut.range(of: ".", options: .backwards) { t = String(cut[..<dot.upperBound]) }
            else { t = cut + "…" }
        }
        return t
    }

    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let forLang = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang }
        // Enhanced/premium quality if the user has downloaded one; else the default.
        return forLang.first { $0.quality == .premium }
            ?? forLang.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: lang)
    }
}
