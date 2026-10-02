import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Screen consent: ask before a screenshot leaves, and the apps that are never
/// captured. Suggestions are offered, never pre-checked (by design).
struct SeeSection: View {
    @State private var ask: Bool = SeeSettings.askBeforeSend
    @State private var excluded: [String] = SeeSettings.excludedBundleIDs

    var body: some View {
        Section {
            Toggle("Ask before sending a screenshot", isOn: $ask)
                .onChange(of: ask) { _, v in SeeSettings.askBeforeSend = v }
            if excluded.isEmpty {
                Text("No excluded apps. When one of these is in front, Handle doesn't capture the screen at all — and says so.")
                    .font(.handleCaption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(excluded, id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(SeeSettings.displayName(for: id)).font(.body)
                            Text(id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Remove") { SeeSettings.include(id); excluded = SeeSettings.excludedBundleIDs }
                            .buttonStyle(.handleSolid)
                    }
                }
            }
            let suggestions = SeeSettings.installedSuggestions().filter { !SeeSettings.isExcluded($0.id, in: excluded) }
            HStack(spacing: 8) {
                Button("Add app…", action: pickApp).buttonStyle(.handleSolid)
                ForEach(suggestions, id: \.id) { s in
                    Button("Exclude \(s.name)") { SeeSettings.exclude(s.id); excluded = SeeSettings.excludedBundleIDs }
                        .buttonStyle(.handleSolid)
                }
                Spacer()
            }
        } header: {
            SettingsHeader(icon: "eye", title: "Screen")
        } footer: {
            Text("A screenshot is taken only when your question is about the screen, and sent only to the provider you chose. Excluded apps are never captured. Voice never leaves this Mac either way.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an app Handle should never capture."
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        SeeSettings.exclude(id)
        excluded = SeeSettings.excludedBundleIDs
    }
}
