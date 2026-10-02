import SwiftUI
import AppKit

/// DEBUG harness only (`__uishot__`): the two customization sections on their own.
struct SettingsCustomizePreview: View {
    var body: some View {
        Form { CustomizeSection(); ToolTrustSection() }.formStyle(.grouped)
    }
}

/// CUSTOMIZE — the user's standing instructions and their own tools (CUSTOMIZING.md).
struct CustomizeSection: View {
    @State private var instructions: String = UserInstructions.text
    @State private var defs: [UserToolDef] = []
    @State private var errors: [UserTools.LoadError] = []
    @State private var note: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions").font(.subheadline.weight(.medium))
                TextEditor(text: $instructions)
                    .font(.system(size: 12))
                    .frame(minHeight: 72, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .onChange(of: instructions) { _, v in UserInstructions.save(v) }
                Text("Sent with every request, like a note pinned to your message — how to address you, what to prefer, what never to do. \(instructions.count)/\(UserInstructions.maxChars)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Your tools").font(.subheadline.weight(.medium))
                if defs.isEmpty && errors.isEmpty {
                    Text("None yet. A tool is one JSON file: a name, a description, its parameters, and the shell command, AppleScript or Shortcut that runs when the model calls it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(defs, id: \.name) { d in
                    HStack(spacing: 8) {
                        Image(systemName: d.runner == "shell" ? "terminal" : (d.runner == "shortcut" ? "square.2.layers.3d" : "applescript"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).font(.system(size: 12, design: .monospaced))
                            Text(d.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text((d.confirm ?? true) ? "asks first" : "runs without asking").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(errors) { e in
                    Text("\(e.file): \(e.reason)").font(.caption).foregroundStyle(.red)
                }
                HStack(spacing: 10) {
                    Button("Open tools folder") { openFolder() }.buttonStyle(.handleSolid)
                    Button("Add example tools") { addExamples() }
                        .buttonStyle(.borderless).handleIconHover(idle: Color(nsColor: .secondaryLabelColor))
                    Button("Reload") { reload() }
                        .buttonStyle(.borderless).handleIconHover(idle: Color(nsColor: .secondaryLabelColor))
                    Spacer()
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            SettingsHeader(icon: "slider.horizontal.3", title: "Customize")
        } footer: {
            Text("Tools live in ~/Library/Application Support/Handle/tools, one JSON file each, and are picked up the moment a file is saved. The format is in CUSTOMIZING.md.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { reload() }
    }

    private func reload() {
        UserTools.invalidate()
        defs = UserTools.definitions
        errors = UserTools.errors
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: UserTools.folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(UserTools.folderURL)
    }

    private func addExamples() {
        do {
            let written = try UserTools.writeExamples()
            note = written.isEmpty ? "The example files are already there." : "Added \(written.map(\.lastPathComponent).joined(separator: ", "))."
        } catch {
            note = "Couldn't write the examples: \(error.localizedDescription)"
        }
        reload()
    }
}

/// TOOLS — per-tool trust: on/off, and "don't ask" for the ones that normally show a card.
struct ToolTrustSection: View {
    @State private var expanded = false
    @State private var disabled: Set<String> = TrustSettings.disabledTools
    @State private var dontAsk: Set<String> = TrustSettings.dontAsk

    private var rows: [Tool] { ToolRegistry.builtinTools + AgentTools.tools + UserTools.tools }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(rows, id: \.name) { t in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).font(.system(size: 12, design: .monospaced))
                            Text(t.description.split(separator: "\n").first.map(String.init) ?? t.description)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if t.confirmation == .confirm && !TrustSettings.alwaysAsk.contains(t.name) {
                            Toggle("Don't ask", isOn: dontAskBinding(t.name)).controlSize(.mini).font(.caption)
                                .help("Runs without a card while you're at the notch. Unattended runs still follow the automation's consent.")
                        }
                        Toggle("", isOn: enabledBinding(t.name)).labelsHidden().controlSize(.mini)
                            .help("Off: the model can't see this tool.")
                    }
                }
            } label: {
                Text("\(rows.count) tools · \(disabled.count) off · \(dontAsk.count) without a card")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            SettingsHeader(icon: "checklist", title: "Tools")
        } footer: {
            Text("Off: the model can't see the tool. Don't ask: it runs without a card while you're at the notch; automations and background tasks still follow their own consent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func enabledBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { !disabled.contains(name) },
                set: { on in TrustSettings.setDisabled(name, !on); disabled = TrustSettings.disabledTools })
    }
    private func dontAskBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { dontAsk.contains(name) },
                set: { on in TrustSettings.setDontAsk(name, on); dontAsk = TrustSettings.dontAsk })
    }
}
