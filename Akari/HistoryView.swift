import SwiftUI

/// The History page inside the notch panel — saved conversations, newest first.
/// Tapping a row reopens it as a continuable text conversation (via
/// `vm.onOpenSaved`); the trash icon deletes one; Clear All needs a second
/// click to confirm (destructive, so no single-click wipe).
struct HistoryBody: View {
    @ObservedObject var vm: NotchViewModel
    @State private var rows: [ConversationSummary] = []
    @State private var loaded = false
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if rows.isEmpty && loaded {
                Text("No saved conversations yet")
                    .font(.akariBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
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
                .frame(maxHeight: 320)

                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)
                    .padding(.vertical, 4)
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
                        .font(.akariBody)
                        .foregroundStyle(confirmClear ? .red : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .task { await reload() }
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
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.white.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
