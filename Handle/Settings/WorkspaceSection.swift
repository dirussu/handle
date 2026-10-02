import SwiftUI
import AppKit

struct WorkspaceSection: View {
    @State private var displayPath: String = WorkspaceManager.shared.displayPath(WorkspaceManager.shared.workspaceURL)

    var body: some View {
        Section {
            LabeledContent("Folder") {
                Text(displayPath)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Button("Change…", action: chooseFolder)
                    .buttonStyle(.handleSolid)
                Button("Reveal in Finder", action: revealInFinder)
                    .buttonStyle(.handleSolid)
                Spacer()
            }
        } header: {
            SettingsHeader(icon: "folder", title: "Workspace")
        } footer: {
            Text("Standing read/write consent: file operations in this folder run without per-call confirmation (destructive ones still confirm). Outside it, they're refused.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose Handle Workspace Folder"
        panel.prompt = "Use as Workspace"
        panel.directoryURL = WorkspaceManager.shared.workspaceURL
        if panel.runModal() == .OK, let url = panel.url {
            WorkspaceManager.shared.setWorkspace(url)
            displayPath = WorkspaceManager.shared.displayPath(url)
        }
    }

    private func revealInFinder() {
        do {
            let url = try WorkspaceManager.shared.ensureWorkspaceExists()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }
}
