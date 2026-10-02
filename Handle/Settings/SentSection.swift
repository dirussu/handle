import SwiftUI
import AppKit

/// Everything that left the Mac this session — memory only (
/// "show what you sent"): what the request was for, the screenshot thumbnail if
/// one went along, tokens and the cost estimate.
struct SentSection: View {
    @ObservedObject private var engine = CloudEngine.shared
    @State private var expanded: Set<UUID> = []

    var body: some View {
        Section {
            if engine.sent.isEmpty {
                SettingsEmptyState(
                    icon: "paperplane",
                    title: "Nothing sent yet",
                    hint: "Every request that leaves this Mac shows up here — memory only, cleared when Handle quits.")
            } else {
                ForEach(engine.sent.prefix(8)) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: r.imageThumbnail != nil ? "eye" : "text.bubble")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.label).font(.body).lineLimit(1)
                                Text(detail(r)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(r.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            if r.imageThumbnail != nil {
                                Button(expanded.contains(r.id) ? "Hide" : "Show") {
                                    if expanded.contains(r.id) { expanded.remove(r.id) } else { expanded.insert(r.id) }
                                }
                                .buttonStyle(.handleSolid)
                            }
                        }
                        if expanded.contains(r.id), let thumb = r.imageThumbnail {
                            Image(decorative: thumb, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .padding(.leading, 24)
                        }
                    }
                }
            }
        } header: {
            SettingsHeader(icon: "paperplane", title: "What was sent")
        } footer: {
            Text("Only the current conversation — and a screenshot when you ask about the screen — ever leaves. This list lives in memory and is gone when Handle quits.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detail(_ r: SentRecord) -> String {
        var parts = [r.model, "\(AICost.formatTokens(r.usage.input + r.usage.cacheRead + r.usage.cacheWrite)) in", "\(AICost.formatTokens(r.usage.output)) out"]
        if r.imageBytes > 0 { parts.append("\(r.imageBytes / 1024) KB image") }
        if let c = r.cost { parts.append("≈ \(AICost.format(c))") }
        return parts.joined(separator: " · ")
    }
}
