import SwiftUI
import AppKit

/// The notification center below the closed notch. Collapsed it's a notch-width
/// "Notifications N" pill; tapping it expands into a collapse handle + a stack
/// of result cards (newest first). Everything stays ≤ the notch width.
/// Solid-black, white-only.
struct NotificationCenterView: View {
    let notifications: [HandleNotification]
    let width: CGFloat        // matches the notch — never wider
    let onOpen: () -> Void
    let onDismissAll: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var expanded = false
    @State private var pillHover = false

    private let stagger: Double = 0.06   // per-card cascade delay

    var body: some View {
        VStack(spacing: HandleSpacing.m) {
            countPill
            if expanded {
                // The handle + each card pop out of the pill ONE AFTER ANOTHER:
                // top-down on expand, bottom-up retracting into the pill on
                // collapse. Each is the same pop, just delayed by its position.
                collapseHandle
                    .transition(reduce ? .opacity : .asymmetric(
                        insertion: HandleMotion.popFromTop.animation(HandleMotion.pop),
                        removal: HandleMotion.popFromTop.animation(HandleMotion.pop.delay(Double(notifications.count) * stagger))
                    ))
                ForEach(Array(notifications.reversed().enumerated()), id: \.element.id) { item in
                    NotificationCard(note: item.element, width: width, onOpen: onOpen)
                        .transition(reduce ? .opacity : .asymmetric(
                            insertion: HandleMotion.popFromTop.animation(HandleMotion.pop.delay(Double(item.offset + 1) * stagger)),
                            removal: HandleMotion.popFromTop.animation(HandleMotion.pop.delay(Double(notifications.count - 1 - item.offset) * stagger))
                        ))
                }
            }
        }
    }

    /// Pop the stack out of / into the pill — the bouncy spring is the funk.
    private func toggle() {
        withAnimation(reduce ? .easeOut(duration: 0.2) : HandleMotion.pop) { expanded.toggle() }
    }

    private var countPill: some View {
        HStack(spacing: HandleSpacing.s) {
            Text("Notifications")
                .font(.handleBody)
                .foregroundStyle(.white.opacity(0.92))
            Spacer(minLength: 0)
            // On hover the count + dot swap for a ✕ that clears everything.
            ZStack {
                if pillHover {
                    Button(action: onDismissAll) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handleIconHover(idle: .white.opacity(0.9))
                    .help("Clear all notifications")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    HStack(spacing: HandleSpacing.s) {
                        Text("\(notifications.count)")
                            .font(.handleBody.weight(.semibold))
                            .foregroundStyle(.white)
                        Circle()
                            .fill(.white)               // white, not the mockup's orange (DESIGN.md)
                            .frame(width: 5, height: 5)
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, HandleSpacing.m)
        .frame(width: width, height: 50)
        .background(Color.black, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        .contentShape(Capsule())
        .onTapGesture { toggle() }      // tapping the pill (not the ✕) toggles expand
        .scaleEffect(pillHover ? 1.03 : 1.0)
        .shadow(color: .black.opacity(pillHover ? 0.6 : 0.5), radius: pillHover ? 18 : 14, y: 7)
        .onHover { pillHover = $0 }
        .animation(HandleMotion.interactive, value: pillHover)
    }

    private var collapseHandle: some View { CollapseHandle(reduce: reduce) { expanded = false } }
}

/// One result card — "Handle" + time header with an ↗ that opens it in the
/// notch, and the full result as the body. Notch-width, solid black.
private struct NotificationCard: View {
    let note: HandleNotification
    let width: CGFloat
    let onOpen: () -> Void
    @State private var hover = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: HandleSpacing.s) {
                Text("Handle")
                    .font(.handleBody.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 0)
                Text(Self.timeFormatter.string(from: note.date))
                    .font(.handleMicro)
                    .foregroundStyle(.white.opacity(0.4))
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handleIconHover(idle: .white.opacity(0.6))
            }
            Text(note.text.isEmpty ? "Done" : note.text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HandleSpacing.m)
        .frame(width: width, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)   // static, no hover change
        }
        .scaleEffect(hover ? 1.02 : 1.0)
        .shadow(color: .black.opacity(hover ? 0.5 : 0.4), radius: hover ? 14 : 10, y: 5)
        .onHover { hover = $0 }
        .animation(HandleMotion.interactive, value: hover)
    }
}
