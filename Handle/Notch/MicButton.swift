import AppKit
import SwiftUI
import MarkdownUI

/// The input bar's mic: tap to record, tap again to stop → the transcript is
/// submitted like a typed message (same loop, same Stop, same persistence).
/// While recording, the icon is replaced by the SAME 5-bar dictation waveform
/// the pointer blob uses (identical envelope + shimmer math, button-scaled) —
/// one voice language everywhere. Spinner while Whisper loads / transcribes.
struct MicButton: View {
    let onTranscript: (String) -> Void
    let disabled: Bool
    @ObservedObject private var speech = SpeechService.shared

    var body: some View {
        Button(action: toggle) {
            ZStack {
                switch speech.state {
                case .recording:
                    TimelineView(.animation) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        Canvas { ctx, size in
                            let barCount = 5
                            let barW: CGFloat = 2.2, barGap: CGFloat = 2.2
                            let span = CGFloat(barCount - 1) * (barW + barGap)
                            let maxBar: CGFloat = 15, minBar: CGFloat = 2.5
                            let level = CGFloat(SpeechService.shared.level)
                            for i in 0..<barCount {
                                let x = size.width / 2 - span / 2 + CGFloat(i) * (barW + barGap)
                                let d = abs(CGFloat(i) - CGFloat(barCount - 1) / 2) / (CGFloat(barCount - 1) / 2)
                                let envelope = 1 - 0.45 * d
                                let shimmer = 0.5 + 0.5 * sin(t * 6 + Double(i) * 0.9)
                                let energy = level * envelope + CGFloat(shimmer) * 0.18 * envelope
                                let h = max(minBar, min(maxBar, minBar + energy * (maxBar - minBar)))
                                let bar = CGRect(x: x - barW / 2, y: size.height / 2 - h / 2, width: barW, height: h)
                                ctx.fill(Path(roundedRect: bar, cornerRadius: barW / 2), with: .color(.white))
                            }
                        }
                    }
                case .loading, .transcribing:
                    ProgressView().controlSize(.small)
                default:
                    Image(systemName: "mic")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .frame(width: 30, height: 30)
            .background(Circle().fill(speech.state == .recording ? Color.white.opacity(0.14) : Color.clear))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .handleIconHover()
        .help(speech.state == .recording ? "Stop and send" : "Dictate")
        .disabled(disabled || speech.state == .loading || speech.state == .transcribing)
        .animation(HandleMotion.swap, value: speech.state == .recording)
    }

    private func toggle() {
        Task { @MainActor in
            switch speech.state {
            case .idle, .failed:
                await speech.startRecording()      // first tap may lazy-load Whisper (spinner)
            case .recording:
                let t = await speech.stopRecordingAndTranscribe()
                if t.isEmpty { NSSound.beep() } else { onTranscript(t) }
            default:
                break
            }
        }
    }
}

// MARK: - Thinking indicator
