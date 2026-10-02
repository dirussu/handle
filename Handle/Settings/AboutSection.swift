import SwiftUI
import AppKit

/// One open-the-repo link row. Hovering ANYWHERE on the row brightens the
/// arrow to white with the house feedback beat (the row is one target, so the
/// per-icon handleIconHover — which only reacts over the glyph itself — would
/// feel dead across the rest of the row).
struct AcknowledgementRow: View {
    let lib: AppInfo.Acknowledgement
    @State private var hovering = false
    var body: some View {
        Button {
            NSWorkspace.shared.open(lib.url)
        } label: {
            HStack(spacing: 8) {
                Text(lib.name).font(.body)
                Spacer()
                Text(lib.license)
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(HandleMotion.feedback, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// App version + copyright + open-source acknowledgements — folded in from the
/// removed standalone About page. The licenses live here because the bundled
/// MIT/Apache dependencies require their notices to ship with the app.
struct AboutSection: View {
    @State private var showLicenses = false

    var body: some View {
        Section {
            LabeledContent("Version") {
                Text(AppInfo.versionString).foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $showLicenses) {
                ForEach(AppInfo.acknowledgements) { lib in
                    AcknowledgementRow(lib: lib)
                }
            } label: {
                Text("Acknowledgements").font(.body)
            }
        } header: {
            SettingsHeader(icon: "info.circle", title: "About")
        } footer: {
            Text("Handle is built on open-source software — thank you to these projects. \(AppInfo.copyrightString).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
