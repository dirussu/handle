import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let triggerCapture  = Self("triggerCapture")    // full-screen (chord alt for double-tap ⌥)
    static let captureRegion   = Self("captureRegion")     // drag-to-select region
    static let demoMetaball    = Self("demoMetaball")      // TEMP — demo the pointer spit-out
    static let pushToTalk      = Self("pushToTalk")        // HOLD to talk (voice command)
}

/// Voice settings, UserDefaults-backed (read from non-UI code without SwiftUI).
enum VoiceSettings {
    private static let speakKey = "voice.speakReplies"
    static var speakReplies: Bool {
        get { UserDefaults.standard.bool(forKey: speakKey) }
        set { UserDefaults.standard.set(newValue, forKey: speakKey) }
    }
}

/// "Speak replies" toggle, bound to VoiceSettings (on-device TTS, off by default).
private struct VoiceReplyToggle: View {
    @State private var on = VoiceSettings.speakReplies
    var body: some View {
        Toggle("Speak replies aloud", isOn: $on)
            .onChange(of: on) { _, v in VoiceSettings.speakReplies = v }
    }
}

/// The settings content (the Form), with no window/panel chrome — so it can
/// render as a page inside the notch. The notch page wraps it with a header.
struct SettingsBody: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Default") {
                    Text("Double-tap ⌥")
                        .foregroundStyle(.secondary)
                }
                KeyboardShortcuts.Recorder("Capture screen (chord):", name: .triggerCapture)
                KeyboardShortcuts.Recorder("Capture region (drag):", name: .captureRegion)
                KeyboardShortcuts.Recorder("Hold to talk:", name: .pushToTalk)
                VoiceReplyToggle()
            } header: {
                Text("Hotkeys")
            } footer: {
                Text("Double-tap ⌥ captures the whole screen. The region chord opens a drag-to-select overlay. Hold the talk key and speak a command — it's transcribed on-device (nothing audible leaves your Mac) and run like a typed one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WorkspaceSection()
            AutomationsSection()
            MemorySection()
            PermissionsSection()
            ActivitySection()
            PowerUserSection()
        }
        .formStyle(.grouped)
    }
}

/// Manage saved automations — the visible, controllable side of the scheduler.
/// Each row: name, its schedule, an enable/disable switch, and delete.
private struct AutomationsSection: View {
    @State private var automations: [Automation] = AutomationStore.shared.automations

    var body: some View {
        Section {
            if automations.isEmpty {
                Text("No saved automations yet. Ask Akari for one — e.g. \"set my volume to 20 every day at 6pm\" or \"when I open Zoom, set the volume to 30\".")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(automations) { a in
                    HStack(spacing: 8) {
                        Image(systemName: a.trigger != nil ? "bolt" : "clock.arrow.circlepath")
                            .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.body)
                            Text(a.schedule?.describe ?? a.trigger?.describe ?? "manual only").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: enabledBinding(a)).labelsHidden().controlSize(.mini)
                        Button { delete(a) } label: {
                            Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("Automations")
        } footer: {
            Text("Automations run on their own — on a schedule or when a watched event happens (like a file appearing in a folder). Approved once when you saved them, recorded in Activity each time they fire. Toggle off to pause, or delete.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { automations = AutomationStore.shared.automations }
    }

    private func enabledBinding(_ a: Automation) -> Binding<Bool> {
        Binding(
            get: { AutomationStore.shared.automations.first { $0.id == a.id }?.enabled ?? false },
            set: { on in
                if var u = AutomationStore.shared.automations.first(where: { $0.id == a.id }) {
                    u.enabled = on
                    AutomationStore.shared.replace(u)
                    automations = AutomationStore.shared.automations
                    TriggerEngine.shared.refresh()   // start/stop watchers to match
                }
            }
        )
    }

    private func delete(_ a: Automation) {
        AutomationStore.shared.remove(id: a.id)
        automations = AutomationStore.shared.automations
        TriggerEngine.shared.refresh()
    }
}

/// Every TCC permission Akari depends on, with live status — plus per-app Automation
/// consent for the apps saved automations control. The staging half lives in the save
/// flows (PermissionsService.primeAutomationTargets); this is the visible half.
private struct PermissionsSection: View {
    struct Item: Identifiable {
        let id: String
        let icon: String
        let name: String
        let status: PermissionsService.Status
        let pane: String?               // Privacy & Security pane query, if any
        let request: (() -> Void)?      // in-app ask, when the OS still allows one
    }
    @State private var items: [Item] = []

    var body: some View {
        Section {
            ForEach(items) { p in
                HStack(spacing: 8) {
                    Image(systemName: p.icon)
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                    Text(p.name).font(.body)
                    Spacer()
                    Circle().fill(color(p.status)).frame(width: 7, height: 7)
                    Text(p.status.label).font(.caption).foregroundStyle(.secondary)
                    if p.status != .granted {
                        if case .notDetermined = p.status, let ask = p.request {
                            Button("Ask") { ask(); refreshSoon() }.buttonStyle(.akariSolid)
                        } else if let pane = p.pane {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(PermissionsService.settingsURL(pane: pane))
                            }.buttonStyle(.akariSolid)
                        } else if p.id == "not" {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(PermissionsService.notificationsSettingsURL)
                            }.buttonStyle(.akariSolid)
                        }
                    }
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Akari asks for each permission the first time a feature needs it — and when you save an automation, it asks to control the target apps right away, so a scheduled run never stalls on a hidden dialog. Everything stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private func color(_ s: PermissionsService.Status) -> Color {
        switch s {
        case .granted:      return .green
        case .denied:       return .red
        case .notDetermined: return .orange
        case .unavailable:  return .gray
        }
    }

    private func refreshSoon() {
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await refresh() }
    }

    @MainActor
    private func refresh() async {
        var out: [Item] = [
            Item(id: "ax", icon: "hand.point.up.left", name: "Accessibility",
                 status: PermissionsService.accessibility(), pane: "Privacy_Accessibility", request: nil),
            Item(id: "sr", icon: "rectangle.dashed.badge.record", name: "Screen Recording",
                 status: PermissionsService.screenRecording(), pane: "Privacy_ScreenCapture", request: nil),
            Item(id: "cal", icon: "calendar", name: "Calendars",
                 status: PermissionsService.calendars(), pane: "Privacy_Calendars", request: nil),
            Item(id: "rem", icon: "checklist", name: "Reminders",
                 status: PermissionsService.reminders(), pane: "Privacy_Reminders", request: nil),
            Item(id: "mic", icon: "mic", name: "Microphone (voice)",
                 status: PermissionsService.microphone(), pane: "Privacy_Microphone",
                 request: { PermissionsService.requestMicrophone() }),
            Item(id: "loc", icon: "location", name: "Location (Wi-Fi triggers)",
                 status: PermissionsService.location(), pane: "Privacy_LocationServices",
                 request: { PermissionsService.requestLocation() }),
            Item(id: "not", icon: "bell.badge", name: "Notifications",
                 status: await PermissionsService.notifications(), pane: nil,
                 request: { PermissionsService.requestNotifications() }),
        ]
        // Per-app Automation consent for the apps saved automations actually control.
        var targets: [String] = []
        for a in AutomationStore.shared.automations {
            guard let r = RecipeStore.shared.recipes.first(where: { $0.id == a.recipeId }) else { continue }
            for t in PermissionsService.tellTargets(in: r.body) where !targets.contains(t) { targets.append(t) }
        }
        for t in targets {
            out.append(Item(id: "auto-\(t)", icon: "gearshape.arrow.triangle.2.circlepath",
                            name: "Automation: \(t)",
                            status: PermissionsService.automationStatus(for: t),
                            pane: "Privacy_Automation", request: nil))
        }
        items = out
    }
}

/// Shows the recent tool activity from the local audit log — the visible half of
/// PRODUCT.md's "audit log" differentiator. Read-only; the data never leaves the Mac.
/// The memory inspector — every remembered fact, add/delete/wipe. Facts enter
/// memory only explicitly (chat "remember that…" or the field here), so this
/// list IS the whole memory: nothing hidden, nothing model-extracted.
private struct MemorySection: View {
    @State private var facts: [MemoryFact] = []
    @State private var draft = ""
    @State private var confirmWipe = false

    var body: some View {
        Section {
            if facts.isEmpty {
                Text("Nothing remembered yet. Say \u{201C}remember that \u{2026}\u{201D} in chat, or add a fact below.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(facts) { fact in
                    HStack(spacing: 8) {
                        Text(fact.content)
                            .font(.body)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            Task {
                                await MemoryStore.shared.delete(id: fact.id)
                                await reload()
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Forget this")
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Add a fact, e.g. Mary = mary@acme.com", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(.akariSolid)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !facts.isEmpty {
                Button(confirmWipe ? "Really forget everything? Click again" : "Forget All") {
                    if confirmWipe {
                        Task {
                            await MemoryStore.shared.wipe()
                            confirmWipe = false
                            await reload()
                        }
                    } else {
                        confirmWipe = true
                    }
                }
                .buttonStyle(.akariSolid)
                .tint(confirmWipe ? .red : nil)
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("Facts you tell Akari to remember. The relevant ones are added to the prompt each turn. Stored locally in memory.db — never leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await reload() }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            _ = await MemoryStore.shared.remember(text)
            draft = ""
            await reload()
        }
    }

    private func reload() async {
        facts = await MemoryStore.shared.all()
    }
}

private struct ActivitySection: View {
    @State private var entries: [AuditEntry] = []

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("No tool activity yet.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Button("Reveal log in Finder", action: revealLog)
                    .buttonStyle(.akariSolid)
                Spacer()
            }
        } header: {
            Text("Activity")
        } footer: {
            Text("Every tool Akari runs is recorded locally to audit.jsonl and never leaves your Mac. The 20 most recent are shown.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { entries = (await AuditLog.shared.recent(20)).reversed().compactMap(AuditEntry.init) }
    }

    private func revealLog() {
        Task { NSWorkspace.shared.activateFileViewerSelecting([await AuditLog.shared.fileURL]) }
    }
}

/// One parsed audit-log line for display.
private struct AuditEntry: Identifiable {
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

private struct PowerUserSection: View {
    @State private var shellEnabled: Bool = ShellTool.shared.isEnabled

    var body: some View {
        Section {
            Toggle("Enable shell tool", isOn: $shellEnabled)
                .onChange(of: shellEnabled) { _, newValue in
                    ShellTool.shared.setEnabled(newValue)
                }
        } header: {
            Text("Power user")
        } footer: {
            Text("With the shell tool on, Akari can run commands in /bin/zsh — npm, pip, brew, git, build scripts, etc. Every command shown to you for confirmation, scoped to allowed folders, with a 60s timeout. Off by default. Treat this like giving Akari a terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WorkspaceSection: View {
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
                    .buttonStyle(.akariSolid)
                Button("Reveal in Finder", action: revealInFinder)
                    .buttonStyle(.akariSolid)
                Spacer()
            }
        } header: {
            Text("Workspace")
        } footer: {
            Text("Akari has standing read/write consent for this folder. File operations inside it run without per-call confirmation; destructive ops (delete, move) always confirm. Outside this folder, file operations are refused.")
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
        panel.title = "Choose Akari Workspace Folder"
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
