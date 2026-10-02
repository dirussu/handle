import SwiftUI
import AppKit

/// Where the model files live, with a relocator (external-drive story from
/// PRODUCT.md). Moves the one huggingface base both loaders point at.
struct StorageSection: View {
    @State private var path: String = ""
    @State private var size: String = ""
    @State private var error: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(path).font(.system(size: 11, design: .monospaced)).lineLimit(2)
                if !size.isEmpty {
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Move…", action: move).buttonStyle(.handleSolid)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ModelStorage.base])
                }.buttonStyle(.handleSolid)
                Spacer()
            }
        } header: {
            SettingsHeader(icon: "internaldrive", title: "Voice model storage")
        } footer: {
            Text("The on-device Whisper model that transcribes your voice lives here (downloaded on first talk). A move takes effect after you quit and reopen Handle.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        path = ModelStorage.base.path
        size = ModelStorage.sizeDescription()
    }

    private func move() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Move models here"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try ModelStorage.relocate(toFolder: dest)
            error = nil
        } catch let e {
            error = e.localizedDescription
        }
        refresh()
    }
}
