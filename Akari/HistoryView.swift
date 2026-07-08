import SwiftUI

/// The History page inside the notch panel — saved conversations, newest first,
/// grouped by WHEN they happened (Today / Yesterday / …) so a long list stays
/// scannable instead of one flat scroll. Tapping a row reopens it as a
/// continuable text conversation (via `vm.onOpenSaved`); the trash icon deletes
/// one; Clear All needs a second click to confirm (destructive, no single-click wipe).
struct HistoryBody: View {
    @ObservedObject var vm: NotchViewModel
    @State private var rows: [ConversationSummary] = []
    @State private var loaded = false
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: AkariSpacing.s) {
            if rows.isEmpty && loaded {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AkariSpacing.l) {
                        ForEach(groups, id: \.label) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.label)
                                    .font(.akariMicro)
                                    .textCase(.uppercase)
                                    .tracking(1.2)
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 2)
                                ForEach(group.rows) { row in
                                    HistoryRow(summary: row) {
                                        vm.onOpenSaved(row.id)
                                        withAnimation(AkariMotion.open) { vm.route = .chat }
                                    } onDelete: {
                                        Task {
                                            await ConversationStore.shared.delete(id: row.id)
                                            await reload()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Clear the top fade zone at rest — the first group header
                    // ("Today") must start below it or it sits permanently dimmed;
                    // the fade should only touch content that is scrolling out.
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                }
                .frame(height: 500)
                .scrollIndicators(.never)   // uniform: no bars anywhere; the edge fade signals more
                .scrollEdgeFade()

                clearAllBar
            }
        }
        .task { await reload() }
    }

    // MARK: - Empty state — an inviting hero, not a bare line of text.

    private var emptyState: some View {
        VStack(spacing: AkariSpacing.m) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.22))
            Text("No conversations yet")
                .font(.akariTitle)
                .foregroundStyle(.white.opacity(0.9))
            Text("Your chats with Akari land here — reopen or delete any of them.")
                .font(.akariBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AkariSpacing.l)
        }
        .frame(maxWidth: .infinity, minHeight: 500)   // same big panel as the list; hero centers in it
    }

    // MARK: - Clear all — quiet until armed, then red.

    private var clearAllBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
                .padding(.vertical, 4)
            HStack {
                Spacer()
                Button {
                    if confirmClear {
                        Task {
                            await ConversationStore.shared.deleteAll()
                            confirmClear = false
                            await reload()
                        }
                    } else {
                        confirmClear = true
                    }
                } label: {
                    Text(confirmClear ? "Really clear all? Click again" : "Clear All")
                        .font(.akariCaption)
                        .foregroundStyle(confirmClear ? .red : .white.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(AkariMotion.feedback, value: confirmClear)
            }
        }
    }

    // MARK: - Time grouping

    private struct DateGroup { let label: String; let rows: [ConversationSummary] }

    /// Bucket the (already newest-first) rows into Today / Yesterday / Previous 7
    /// Days / Earlier, dropping any empty bucket. Calendar-day based, so "1 day"
    /// means yesterday regardless of the clock time.
    private var groups: [DateGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let labels = ["Today", "Yesterday", "Previous 7 Days", "Earlier"]
        var buckets: [[ConversationSummary]] = [[], [], [], []]
        for r in rows {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: r.updatedAt), to: today).day ?? 0
            let i = days <= 0 ? 0 : (days == 1 ? 1 : (days < 7 ? 2 : 3))
            buckets[i].append(r)
        }
        return labels.enumerated().compactMap { i, label in
            buckets[i].isEmpty ? nil : DateGroup(label: label, rows: buckets[i])
        }
    }

    private func reload() async {
        rows = await ConversationStore.shared.list()
        loaded = true
    }
}

private struct HistoryRow: View {
    let summary: ConversationSummary
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: AkariSpacing.s) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.title)
                        .font(.akariBody)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .akariIconHover()
                    .help("Delete")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.white.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(AkariMotion.feedback, value: hovering)   // was instant — brand feedback beat
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !summary.appName.isEmpty { parts.append(summary.appName) }
        parts.append(Self.rel.localizedString(for: summary.updatedAt, relativeTo: Date()))
        parts.append("\(summary.messageCount) turn\(summary.messageCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}
