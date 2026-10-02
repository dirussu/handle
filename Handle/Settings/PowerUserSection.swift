import SwiftUI
import AppKit

struct PowerUserSection: View {
    @State private var shellEnabled: Bool = ShellTool.shared.isEnabled

    var body: some View {
        Section {
            Toggle("Enable shell tool", isOn: $shellEnabled)
                .onChange(of: shellEnabled) { _, newValue in
                    ShellTool.shared.setEnabled(newValue)
                }
        } header: {
            SettingsHeader(icon: "terminal", title: "Power user")
        } footer: {
            Text("Every command is shown for confirmation, runs only in allowed folders, and times out after 60 seconds. Treat it like handing Handle a terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
