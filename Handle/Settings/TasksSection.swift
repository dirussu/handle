import SwiftUI
import AppKit

/// Background agent runs + the kill switch.
struct TasksSection: View {
    @ObservedObject private var ledger = TaskLedger.shared
    @State private var expanded: Set<String> = []

    var body: some View {
        Section {
            if ledger.entries.isEmpty {
                SettingsEmptyState(icon: "clock.badge.checkmark", title: "No background tasks yet",
                                   hint: "Ask for something long and Handle can run it in the background; results land under the notch and here.")
            } else {
                ForEach(ledger.entries) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: icon(e.status)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.goal).font(.body).lineLimit(1)
                                Text(detail(e)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if e.result != nil {
                                Button(expanded.contains(e.id) ? "Hide" : "Show") {
                                    if expanded.contains(e.id) { expanded.remove(e.id) } else { expanded.insert(e.id) }
                                }.buttonStyle(.handleSolid)
                            }
                        }
                        if expanded.contains(e.id), let r = e.result {
                            Text(r).font(.handleCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
                        }
                    }
                }
            }
            HStack {
                Button("Stop everything") {
                    NotchController.shared.onStop()
                    TaskLedger.shared.cancelAll()
                }
                .buttonStyle(.handleSolidDestructive)
                Spacer()
            }
        } header: {
            SettingsHeader(icon: "clock.badge.checkmark", title: "Background tasks")
        } footer: {
            Text("\"Stop everything\" cancels the current reply and every background task at its next step. Automations keep their own on/off switches above.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func icon(_ s: TaskLedger.Status) -> String {
        switch s { case .running: return "circle.dotted"; case .done: return "checkmark.circle"; case .failed: return "exclamationmark.circle"; case .cancelled: return "xmark.circle" }
    }
    private func detail(_ e: TaskLedger.Entry) -> String {
        var parts = [e.status.rawValue, e.started.formatted(date: .omitted, time: .shortened)]
        if let c = e.costUSD, c > 0 { parts.append("≈ \(AICost.format(c))") }
        return parts.joined(separator: " · ")
    }
}
