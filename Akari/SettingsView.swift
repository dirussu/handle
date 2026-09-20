import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let triggerCapture  = Self("triggerCapture")    // full-screen (chord alt for double-tap ⌥)
    static let demoMetaball    = Self("demoMetaball")      // TEMP — demo the pointer spit-out
    static let pushToTalk      = Self("pushToTalk")        // RETIRED (hold-⌥ replaced it) — kept so reset() can clear old bindings
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

/// A settings section header — a small icon tile + title, replacing the weak
/// default grouped-form header so the page is scannable at a glance. White-only
/// (DESIGN.md): the hierarchy comes from the tile + type, never colour.
private struct SettingsHeader: View {
    let icon: String
    let title: String
    var body: some View {
        HStack(spacing: AkariSpacing.s) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, alignment: .center)
            Text(title)
                .font(.akariSection)
                .foregroundStyle(.white)
                .textCase(nil)
        }
        .padding(.bottom, 2)
    }
}

/// A small centered empty-state — dimmed icon + title + hint — matching the
/// Chats page hero, scaled for a Form section. Replaces the bare gray "No X yet"
/// lines so an empty section reads as designed, not unfinished.
private struct SettingsEmptyState: View {
    let icon: String
    let title: String
    let hint: String
    var body: some View {
        VStack(spacing: AkariSpacing.s) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white.opacity(0.22))
            Text(title)
                .font(.akariSection)
                .foregroundStyle(.white.opacity(0.9))
            Text(hint)
                .font(.akariCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AkariSpacing.l)
    }
}

/// The settings content (the Form), with no window/panel chrome — so it can
/// render as a page inside the notch. The notch page wraps it with a header.
/// Section order is a deliberate narrative: how you drive it → what it does on
/// its own → what it knows / can touch → privacy + data → advanced.
struct SettingsBody: View {
    var body: some View {
        Form {
            AISection()
            SentSection()
            SeeSection()

            Section {
                LabeledContent("Capture") {
                    Text("Double-tap ⌥")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Talk") {
                    Text("Hold ⌥")
                        .foregroundStyle(.secondary)
                }
                KeyboardShortcuts.Recorder("Capture screen (chord):", name: .triggerCapture)
                VoiceReplyToggle()
            } header: {
                SettingsHeader(icon: "keyboard", title: "Hotkeys")
            } footer: {
                Text("Speech is transcribed on-device — nothing audible leaves your Mac. Holding ⌥ cancels the instant you press another key, so ⌥-shortcuts keep working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AutomationsSection()
            ActivitySection()
            MemorySection()
            WorkspaceSection()
            PermissionsSection()
            StorageSection()
            PowerUserSection()
            IntegrationsSection()   // advanced territory (founder call) — lives with Power User
            AboutSection()
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)   // kill the thick AppKit scroller — uniform with the rest
    }
}

/// Which AI answers — provider (no default; the user picks), key (Keychain),
/// model, a live Test, and the session's token cost. The honest privacy line
/// lives in the footer (PROVIDERS.md: local software, your model).
private struct AISection: View {
    @State private var kind: AIProviderKind? = AIConfig.provider
    @State private var model: String = AIConfig.model ?? AIConfig.provider?.defaultModel ?? ""
    @ObservedObject private var engine = CloudEngine.shared
    // OpenAI-compatible endpoint (phase 4)
    @State private var baseURL: String = AIConfig.openAIBaseURLString
    @State private var serverTools: Bool = AIConfig.openAISupportsTools
    @State private var serverVision: Bool = AIConfig.openAISupportsVision
    @State private var fetched: [String] = []
    @State private var fetchStatus: String? = nil

    var body: some View {
        Section {
            Picker("Provider", selection: $kind) {
                Text("Not connected").tag(AIProviderKind?.none)
                ForEach(AIProviderKind.allCases) { k in
                    Text(k.isAvailable ? k.displayName : "\(k.displayName) — next update").tag(AIProviderKind?.some(k))
                }
            }
            .onChange(of: kind) { _, k in
                AIConfig.setProvider(k)
                model = AIConfig.model ?? k?.defaultModel ?? ""
            }
            if let kind {
                if !kind.isAvailable {
                    Text("\(kind.displayName) support arrives in the next update — pick Claude (Anthropic) for now.")
                        .font(.akariCaption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    AIKeyField(kind: kind, keyOptional: kind == .openai && AIConfig.openAIBaseURL != nil)
                    if kind == .openai {
                        // Model is a free id here (the real list comes from the server).
                        HStack(spacing: 8) {
                            TextField("Model id", text: $model)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { AIConfig.setModel(model) }
                            Button("Fetch models…") { fetchModels() }
                                .buttonStyle(.akariSolid)
                        }
                        .onChange(of: model) { _, m in AIConfig.setModel(m) }
                        if !fetched.isEmpty {
                            Picker("Available", selection: $model) {
                                if !fetched.contains(model) { Text(model.isEmpty ? "—" : model).tag(model) }
                                ForEach(fetched, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        if let fetchStatus {
                            Text(fetchStatus).font(.akariCaption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        DisclosureGroup("Custom server (LM Studio, Ollama, OpenRouter…)") {
                            HStack(spacing: 8) {
                                TextField("Base URL — blank = api.openai.com", text: $baseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { saveBaseURL() }
                                Button("Save") { saveBaseURL() }.buttonStyle(.akariSolid)
                            }
                            Text("LM Studio: http://localhost:1234/v1 · Ollama: http://localhost:11434/v1 · OpenRouter: https://openrouter.ai/api/v1. A local server means nothing leaves this Mac — and no key is needed.")
                                .font(.akariCaption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if AIConfig.openAIBaseURL != nil {
                                Toggle("The model supports tool calls", isOn: $serverTools)
                                    .onChange(of: serverTools) { _, v in AIConfig.openAISupportsTools = v }
                                Toggle("The model can see images", isOn: $serverVision)
                                    .onChange(of: serverVision) { _, v in AIConfig.openAISupportsVision = v }
                                Text("Turn these off for a text-only or tool-less model: Akari then folds tool instructions into the prompt, and answers without screenshots.")
                                    .font(.akariCaption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else if !kind.knownModels.isEmpty {
                        Picker("Model", selection: $model) {
                            ForEach(kind.knownModels, id: \.self) { Text($0).tag($0) }
                            if !model.isEmpty, !kind.knownModels.contains(model) { Text("Custom: \(model)").tag(model) }
                        }
                        .onChange(of: model) { _, m in AIConfig.setModel(m) }
                    }
                    if let url = kind.keyURL, !(kind == .openai && AIConfig.openAIBaseURL != nil) {
                        HStack {
                            Button("Get a \(kind.shortName) API key…") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.akariSolid)
                            Spacer()
                        }
                    }
                }
            }
            if engine.sessionUsage != .init() {
                LabeledContent("This session") {
                    Text(usageText).foregroundStyle(.secondary)
                }
            }
        } header: {
            SettingsHeader(icon: "sparkles", title: "AI")
        } footer: {
            Text("Akari is local software. Only the current conversation — and a screenshot when you ask about the screen — goes to the provider you chose, with your own key. Memory, chat history, voice, and screen reading stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var usageText: String {
        let u = engine.sessionUsage
        var parts = ["\(AICost.formatTokens(u.input + u.cacheRead + u.cacheWrite)) in", "\(AICost.formatTokens(u.output)) out"]
        if u.cacheRead > 0 { parts.append("\(AICost.formatTokens(u.cacheRead)) cached") }
        var text = parts.joined(separator: " · ")
        if AIConfig.isLocalEndpoint {
            text += " · $0 · local"
        } else if let d = AICost.estimate(model: engine.lastModel, input: u.input, output: u.output, cacheRead: u.cacheRead, cacheWrite: u.cacheWrite) {
            text += " ≈ \(AICost.format(d))"
        }
        return text
    }

    private func saveBaseURL() {
        AIConfig.setOpenAIBaseURL(baseURL)
        baseURL = AIConfig.openAIBaseURLString
        fetched = []; fetchStatus = nil
    }

    private func fetchModels() {
        let base = AIConfig.openAIBaseURL ?? OpenAIProvider.defaultBaseURL
        let key = SecretStore.providers.get("openai") ?? ""
        fetchStatus = "Fetching from \(base.host ?? base.absoluteString)…"
        Task {
            do {
                var ids = try await OpenAIProvider.fetchModels(baseURL: base, apiKey: key)
                if base == OpenAIProvider.defaultBaseURL {   // OpenAI lists hundreds; keep the chat-capable families
                    ids = ids.filter { $0.hasPrefix("gpt-") || $0.hasPrefix("o") || $0.hasPrefix("chatgpt") }
                }
                await MainActor.run { fetched = ids; fetchStatus = "\(ids.count) models" }
            } catch {
                await MainActor.run { fetched = []; fetchStatus = error.localizedDescription }
            }
        }
    }
}

/// Everything that left the Mac this session — memory only (PRD principle 3,
/// "show what you sent"): what the request was for, the screenshot thumbnail if
/// one went along, tokens and the cost estimate.
private struct SentSection: View {
    @ObservedObject private var engine = CloudEngine.shared
    @State private var expanded: Set<UUID> = []

    var body: some View {
        Section {
            if engine.sent.isEmpty {
                SettingsEmptyState(
                    icon: "paperplane",
                    title: "Nothing sent yet",
                    hint: "Every request that leaves this Mac shows up here — memory only, cleared when Akari quits.")
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
                                .buttonStyle(.akariSolid)
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
            Text("Only the current conversation — and a screenshot when you ask about the screen — ever leaves. This list lives in memory and is gone when Akari quits.")
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

/// Screen consent: ask before a screenshot leaves, and the apps that are never
/// captured. Suggestions are offered, never pre-checked (founder).
private struct SeeSection: View {
    @State private var ask: Bool = SeeSettings.askBeforeSend
    @State private var excluded: [String] = SeeSettings.excludedBundleIDs

    var body: some View {
        Section {
            Toggle("Ask before sending a screenshot", isOn: $ask)
                .onChange(of: ask) { _, v in SeeSettings.askBeforeSend = v }
            if excluded.isEmpty {
                Text("No excluded apps. When one of these is in front, Akari doesn't capture the screen at all — and says so.")
                    .font(.akariCaption).foregroundStyle(.secondary)
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
                            .buttonStyle(.akariSolid)
                    }
                }
            }
            let suggestions = SeeSettings.installedSuggestions().filter { !SeeSettings.isExcluded($0.id, in: excluded) }
            HStack(spacing: 8) {
                Button("Add app…", action: pickApp).buttonStyle(.akariSolid)
                ForEach(suggestions, id: \.id) { s in
                    Button("Exclude \(s.name)") { SeeSettings.exclude(s.id); excluded = SeeSettings.excludedBundleIDs }
                        .buttonStyle(.akariSolid)
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
        panel.message = "Choose an app Akari should never capture."
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        SeeSettings.exclude(id)
        excluded = SeeSettings.excludedBundleIDs
    }
}

/// Manage saved automations — the visible, controllable side of the scheduler.
/// Each row: name, its schedule, an enable/disable switch, and delete.
private struct AutomationsSection: View {
    @State private var automations: [Automation] = AutomationStore.shared.automations
    @State private var editingID: String?

    var body: some View {
        Section {
            if automations.isEmpty {
                SettingsEmptyState(
                    icon: "clock.arrow.circlepath",
                    title: "No automations yet",
                    hint: "Tell Akari what and when — e.g. \u{201C}every day at 6pm, set my volume to 20\u{201D}.")
            } else {
                ForEach(automations) { a in
                    HStack(spacing: 8) {
                        Image(systemName: a.routineGoal != nil ? "sparkles" : (a.trigger != nil ? "bolt" : "clock.arrow.circlepath"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.body)
                            Text(a.schedule?.describe ?? a.trigger?.describe ?? "manual only").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: enabledBinding(a)).labelsHidden().controlSize(.mini)
                        Button {
                            editingID = editingID == a.id ? nil : a.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .akariIconHover(idle: editingID == a.id ? Color.white : Color(nsColor: .secondaryLabelColor))
                        .help("Edit")
                        Button { delete(a) } label: {
                            Image(systemName: "trash").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .akariIconHover()
                    }
                    if editingID == a.id {
                        AutomationEditor(original: a) { updated in
                            AutomationStore.shared.replace(updated)
                            automations = AutomationStore.shared.automations
                            TriggerEngine.shared.refresh()
                            editingID = nil
                        } onCancel: {
                            editingID = nil
                        }
                    }
                }
            }
            HStack {
                // Creation IS a chat request (founder call) — the button just
                // opens a fresh chat; the pipeline (parse → recipe/routine →
                // consent card) takes it from there.
                Button("New automation…") { NotchController.shared.onNewChat() }
                    .buttonStyle(.akariSolid)
                Spacer()
            }
        } header: {
            SettingsHeader(icon: "clock.arrow.circlepath", title: "Automations")
        } footer: {
            Text("Approved once when saved; every run lands in Activity.")
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
                        }
                    }
                }
            }
        } header: {
            SettingsHeader(icon: "lock.shield", title: "Permissions")
        } footer: {
            Text("Asked for only when a feature first needs it. Saving an automation stages its permissions right away, so a scheduled run never stalls on a hidden dialog.")
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
            // (No Notifications row — system notifications removed; the notch pill
            // is Akari's only completion surface and needs no permission.)
        ]
        // Location exists ONLY because macOS gates Wi-Fi SSID reads behind it
        // (named-network triggers). A permanent "Location" row in a privacy-
        // first app reads wrong (founder, 2026-07-10) — show it only once a
        // named-Wi-Fi automation exists, or after the user already decided
        // (granted/denied must never become invisible).
        let locationStatus = PermissionsService.location()
        let hasNamedWifiTrigger = AutomationStore.shared.automations
            .contains { $0.trigger?.kind == "wifiConnects" && $0.trigger?.ssid != nil }
        if hasNamedWifiTrigger || locationStatus == .granted || locationStatus == .denied {
            out.append(Item(id: "loc", icon: "location", name: "Location (Wi-Fi triggers)",
                            status: locationStatus, pane: "Privacy_LocationServices",
                            request: { PermissionsService.requestLocation() }))
        }
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
/// In-place editor for one saved automation — name, the schedule time/days or
/// the trigger's fields (within its kind; changing kind = re-ask Akari), and
/// the filled recipe params as JSON. Save validates everything; an edit keeps
/// the standing consent (same recipe, user-reviewed changes) and re-primes
/// Automation permission for any newly-targeted running app.
private struct AutomationEditor: View {
    let original: Automation
    let onSave: (Automation) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var timeText: String
    @State private var days: Set<Int>
    @State private var folder: String
    @State private var ext: String
    @State private var app: String
    @State private var ssid: String
    @State private var paramsText: String
    @State private var error: String?

    init(original: Automation, onSave: @escaping (Automation) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: original.name)
        _timeText = State(initialValue: original.schedule?.timeText ?? "")
        _days = State(initialValue: Set(original.schedule?.days ?? Array(1...7)))
        _folder = State(initialValue: original.trigger?.folder ?? "")
        _ext = State(initialValue: original.trigger?.ext ?? "")
        _app = State(initialValue: original.trigger?.app ?? "")
        _ssid = State(initialValue: original.trigger?.ssid ?? "")
        let pretty = (original.paramsJSON.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .flatMap { String(data: $0, encoding: .utf8) }
        _paramsText = State(initialValue: pretty ?? original.paramsJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            if original.schedule != nil {
                HStack(spacing: 8) {
                    Text("At").font(.caption).foregroundStyle(.secondary)
                    TextField("18:30", text: $timeText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    dayPicker
                }
            }
            if let trigger = original.trigger {
                switch trigger.kind {
                case "fileAppears":
                    TextField("Watched folder, e.g. ~/Downloads", text: $folder)
                        .textFieldStyle(.roundedBorder)
                    TextField("Extension filter, e.g. pdf (empty = any file)", text: $ext)
                        .textFieldStyle(.roundedBorder)
                case "appLaunches":
                    TextField("App name or bundle id, e.g. zoom.us", text: $app)
                        .textFieldStyle(.roundedBorder)
                case "wifiConnects":
                    TextField("Network name (empty = any Wi-Fi)", text: $ssid)
                        .textFieldStyle(.roundedBorder)
                default:
                    EmptyView()
                }
            }

            TextField("Recipe params (JSON)", text: $paramsText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1...4)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Save", action: save).buttonStyle(.akariSolid)
                Button("Cancel", action: onCancel).buttonStyle(.borderless)
                    .akariIconHover(idle: Color(nsColor: .secondaryLabelColor))
                Spacer()
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 4)
    }

    private var dayPicker: some View { WeekdayPicker(days: $days) }

    private func save() {
        var updated = original
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { error = "Name can't be empty."; return }
        updated.name = trimmedName

        if original.schedule != nil {
            guard let (h, m) = AutomationSchedule.parseTime(timeText) else {
                error = "Time must be HH:MM (24-hour), e.g. 18:30."; return
            }
            guard !days.isEmpty else { error = "Pick at least one day."; return }
            updated.schedule = AutomationSchedule(hour: h, minute: m,
                                                  days: days.count == 7 ? nil : days.sorted())
        }
        if var trigger = original.trigger {
            switch trigger.kind {
            case "fileAppears":
                let f = folder.trimmingCharacters(in: .whitespaces)
                guard !f.isEmpty else { error = "The watched folder can't be empty."; return }
                trigger.folder = f
                let e = ext.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: .init(charactersIn: "."))
                trigger.ext = e.isEmpty ? nil : e.lowercased()
            case "appLaunches":
                let a = app.trimmingCharacters(in: .whitespaces)
                guard !a.isEmpty else { error = "The app name can't be empty."; return }
                trigger.app = a
            case "wifiConnects":
                let s = ssid.trimmingCharacters(in: .whitespaces)
                trigger.ssid = s.isEmpty ? nil : s
            default: break
            }
            updated.trigger = trigger
        }

        guard let d = paramsText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d), obj is [String: Any],
              let compact = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: compact, encoding: .utf8) else {
            error = "Params must be a valid JSON object."; return
        }
        updated.paramsJSON = json

        // Changed params can re-target a different app — prime its Automation
        // consent NOW, while the user is present (the standing-consent rule).
        if let recipe = RecipeStore.shared.recipes.first(where: { $0.id == updated.recipeId }),
           let params = try? JSONSerialization.jsonObject(with: compact) as? [String: Any] {
            _ = PermissionsService.primeAutomationTargets(inScript: recipe.resolve(recipe.body, with: params))
        }

        error = nil
        onSave(updated)
    }
}

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
                SettingsEmptyState(
                    icon: "brain",
                    title: "Nothing remembered yet",
                    hint: "Say \u{201C}remember that \u{2026}\u{201D} in chat, or add a fact below.")
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
                        }
                        .buttonStyle(.plain)
                        .akariIconHover()
                        .help("Forget this")
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Add a fact", text: $draft, prompt: Text("Add a fact, e.g. Mary = mary@acme.com"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()   // placeholder INSIDE the field, not a wrapping left label
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
            SettingsHeader(icon: "brain", title: "Memory")
        } footer: {
            Text("Stored locally in memory.db — relevant facts join each turn's prompt, nothing leaves your Mac.")
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
                SettingsEmptyState(
                    icon: "list.bullet.rectangle",
                    title: "No activity yet",
                    hint: "Every tool Akari runs shows up here.")
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
                    .buttonStyle(.akariSolid)
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

/// Where the model files live, with a relocator (external-drive story from
/// PRODUCT.md). Moves the one huggingface base both loaders point at.
private struct StorageSection: View {
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
                Button("Move…", action: move).buttonStyle(.akariSolid)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ModelStorage.base])
                }.buttonStyle(.akariSolid)
                Spacer()
            }
        } header: {
            SettingsHeader(icon: "internaldrive", title: "Voice model storage")
        } footer: {
            Text("The on-device Whisper model that transcribes your voice lives here (downloaded on first talk). A move takes effect after you quit and reopen Akari.")
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

private struct PowerUserSection: View {
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
            Text("Every command is shown for confirmation, runs only in allowed folders, and times out after 60 seconds. Treat it like handing Akari a terminal.")
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

/// One open-the-repo link row. Hovering ANYWHERE on the row brightens the
/// arrow to white with the house feedback beat (the row is one target, so the
/// per-icon akariIconHover — which only reacts over the glyph itself — would
/// feel dead across the rest of the row).
private struct AcknowledgementRow: View {
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
        .animation(AkariMotion.feedback, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// S M T W T F S toggle chips (1=Sun … 7=Sat, matching AutomationSchedule).
/// Shared by the automation editor and the Settings creator form.
private struct WeekdayPicker: View {
    @Binding var days: Set<Int>
    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...7, id: \.self) { d in
                let label = ["", "S", "M", "T", "W", "T", "F", "S"][d]
                Button {
                    if days.contains(d) { days.remove(d) } else { days.insert(d) }
                } label: {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background(days.contains(d) ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.15),
                                    in: Circle())
                        .foregroundStyle(days.contains(d) ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// MCP connectors (v2 #1 increment ④): the visible, controllable side of
/// mcp.json. Rows show each configured server with live status; Check connects
/// and lists its tools in place, Stop disconnects. Tokens store to the
/// Keychain here (referenced from mcp.json as `keychain:NAME`). The config
/// FILE stays the editing surface in v1 — entries paste straight from any
/// server's README (claude-desktop format).
private struct IntegrationsSection: View {
    @State private var configs: [MCPServerConfig] = MCPConfig.load()
    @State private var status: [String: String] = [:]
    @State private var checking: Set<String> = []
    @State private var showAddForm = false
    @State private var addText = ""
    @State private var addError: String?
    @State private var showTokenForm = false
    @State private var tokenName = ""
    @State private var tokenSecret = ""
    @State private var tokenNames: [String] = MCPKeychain.allNames()

    var body: some View {
        Section {
            if configs.isEmpty {
                SettingsEmptyState(
                    icon: "puzzlepiece.extension",
                    title: "No connectors yet",
                    hint: "Add MCP servers to mcp.json — entries copy straight from any server's README.")
            } else {
                ForEach(configs, id: \.name) { c in
                    HStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name).font(.body)
                            Text(status[c.name] ?? restingStatus(c.name))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer()
                        if checking.contains(c.name) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { check(c.name) } label: {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12))
                            }
                            .buttonStyle(.borderless)
                            .akariIconHover(idle: Color(nsColor: .secondaryLabelColor))
                            .help("Connect and list its tools")
                            if MCPService.shared.isConnected(name: c.name) {
                                Button { stop(c.name) } label: {
                                    Image(systemName: "stop.circle").font(.system(size: 12))
                                }
                                .buttonStyle(.borderless)
                                .akariIconHover(idle: Color(nsColor: .secondaryLabelColor))
                                .help("Disconnect")
                            }
                            Button { remove(c.name) } label: {
                                Image(systemName: "trash").font(.system(size: 12))
                            }
                            .buttonStyle(.borderless)
                            .akariIconHover()
                            .help("Remove this connector")
                        }
                    }
                }
            }
            if showAddForm {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Paste the server's JSON from its README", text: $addText, axis: .vertical)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(3...8)
                    if let addError {
                        Text(addError).font(.caption).foregroundStyle(.red)
                    }
                    HStack(spacing: 8) {
                        Button("Add", action: add).buttonStyle(.akariSolid)
                            .disabled(addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") { showAddForm = false; addText = ""; addError = nil }
                            .buttonStyle(.borderless)
                            .akariIconHover(idle: Color(nsColor: .secondaryLabelColor))
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 8) {
                    Button("Add a connector…") { showAddForm = true }
                        .buttonStyle(.akariSolid)
                    Button("Open mcp.json", action: openConfig)
                        .buttonStyle(.akariSolid)
                    Spacer()
                }
            }
            DisclosureGroup(isExpanded: $showTokenForm) {
                if !tokenNames.isEmpty {
                    LabeledContent("Stored") {
                        Text(tokenNames.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                TextField("Name (e.g. WEATHER_API_KEY)", text: $tokenName)
                SecureField("Secret", text: $tokenSecret)
                HStack {
                    Button("Save to Keychain", action: saveToken)
                        .buttonStyle(.akariSolid)
                        .disabled(tokenName.trimmingCharacters(in: .whitespaces).isEmpty || tokenSecret.isEmpty)
                    Spacer()
                }
                Text("Reference it from mcp.json as keychain:NAME — the secret itself stays in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: {
                Text("Tokens").font(.body)
            }
        } header: {
            SettingsHeader(icon: "puzzlepiece.extension", title: "Integrations")
        } footer: {
            Text("Connectors run as local processes, stop when Akari quits, and every action they take asks first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { reload() }   // pick up hand-edits to mcp.json
    }

    /// Parse the pasted snippet, write it into mcp.json, then immediately
    /// test-connect each added server so the row shows "Running — N tools"
    /// (or the real error) without another click.
    private func add() {
        let added = MCPConfig.addServers(fromSnippet: addText)
        guard !added.isEmpty else {
            addError = "That doesn't look like a server entry — paste the JSON block from the server's README."
            return
        }
        addText = ""
        addError = nil
        showAddForm = false
        reload()
        for name in added { check(name) }
    }

    private func remove(_ name: String) {
        Task { @MainActor in
            await MCPService.shared.disconnect(name: name)
            MCPConfig.removeServer(named: name)
            reload()
        }
    }

    private func restingStatus(_ name: String) -> String {
        if MCPService.shared.isConnected(name: name) {
            let n = MCPService.shared.cachedTools(name: name)?.count
            return n.map { "Running — \($0) tool\($0 == 1 ? "" : "s")" } ?? "Running"
        }
        return "Not running — connects when needed"
    }

    private func check(_ name: String) {
        checking.insert(name)
        Task { @MainActor in
            defer { checking.remove(name) }
            do {
                let handle = try await MCPService.shared.connect(configuredName: name)
                let tools = try await MCPService.shared.listTools(handle)
                status[name] = "Running — \(tools.count) tool\(tools.count == 1 ? "" : "s")"
            } catch {
                status[name] = error.localizedDescription
            }
        }
    }

    private func stop(_ name: String) {
        Task { @MainActor in
            await MCPService.shared.disconnect(name: name)
            status[name] = restingStatus(name)
        }
    }

    private func reload() {
        configs = MCPConfig.load()
        status = [:]
        tokenNames = MCPKeychain.allNames()
    }

    private func openConfig() {
        let url = MCPConfig.url
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = """
            {
              "mcpServers": {
              }
            }
            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private func saveToken() {
        let name = tokenName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !tokenSecret.isEmpty else { return }
        MCPKeychain.set(tokenSecret, for: name)
        tokenName = ""
        tokenSecret = ""
        tokenNames = MCPKeychain.allNames()
    }
}

/// App version + copyright + open-source acknowledgements — folded in from the
/// removed standalone About page. The licenses live here because the bundled
/// MIT/Apache dependencies require their notices to ship with the app.
private struct AboutSection: View {
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
            Text("Akari is built on open-source software — thank you to these projects. \(AppInfo.copyrightString).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
