import AppKit
import SwiftUI
import MarkdownUI

/// The "Handle is working" line shown before the first token streams in.
/// A calm opacity breathe rather than a stock spinner — minimal, white-only,
/// and unobtrusive next to the comet already orbiting the input bar.
struct ThinkingLabel: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var breathing = false

    var body: some View {
        Text(text)
            .font(.handleBody)
            .foregroundStyle(.white)
            .opacity(reduce ? 0.7 : (breathing ? 0.85 : 0.35))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                guard !reduce else { return }   // no forever-breathing under reduce-motion
                withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

// MARK: - User message bubble (white-accent chip)

extension View {
    /// The user's message chip: a soft grey bubble (white @ 10%) with primary
    /// (white) text — subtle and user-attributed without shouting. Handle's
    /// replies stay as plain text, so the bubble alone marks "your message."
    func userBubble() -> some View {
        self
            .padding(.horizontal, HandleSpacing.m)
            .padding(.vertical, HandleSpacing.s)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Tool use card
