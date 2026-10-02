import SwiftUI
import AppKit

struct ActivitySection: View {
    @State private var entries: [AuditEntry] = []

    var body: some View {
        Section {
            if entries.isEmpty {
                SettingsEmptyState(
                    icon: "list.bullet.rectangle",
                    title: "No activity yet",
                    hint: "Every tool Handle runs shows up here.")
            } else {
                ForEach(entries) { e in
                    HStack(spacing: 8) {
                        Image(systemName: e.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(e.color)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.tool).font(.body)
                            if !e.summary.isEmpty {
                                Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(e.time).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Open full log", action: openLog)
                    .buttonStyle(.handleSolid)
                Spacer()
            }
        } header: {
            SettingsHeader(icon: "list.bullet.rectangle", title: "Activity")
        } footer: {
            Text("The last 5 actions — the full history is audit.jsonl, recorded locally.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { entries = (await AuditLog.shared.recent(5)).reversed().compactMap(AuditEntry.init) }
    }

    private func openLog() {
        Task {
            let url = await AuditLog.shared.fileURL
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
            } else {
                NSSound.beep()
            }
        }
    }
}

/// One parsed audit-log line for display.
struct AuditEntry: Identifiable {
    let id = UUID()
    let tool: String
    let outcome: String
    let summary: String
    let time: String

    init?(_ jsonl: String) {
        guard let d = jsonl.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let name = o["tool"] as? String else { return nil }
        tool = name.replacingOccurrences(of: "_", with: " ")
        outcome = (o["outcome"] as? String) ?? "ok"
        summary = (o["summary"] as? String) ?? ""
        if let ts = o["ts"] as? String, let date = ISO8601DateFormatter().date(from: ts) {
            let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
            time = f.string(from: date)
        } else {
            time = ""
        }
    }

    var icon: String {
        switch outcome {
        case "error":    return "xmark.circle.fill"
        case "declined": return "minus.circle.fill"
        default:         return "checkmark.circle.fill"
        }
    }
    var color: Color {
        switch outcome {
        case "error":    return .red
        case "declined": return .gray
        default:         return .green
        }
    }
}
