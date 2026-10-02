import SwiftUI
import AppKit

/// Manage saved automations — the visible, controllable side of the scheduler.
/// Each row: name, its schedule, an enable/disable switch, and delete.
struct AutomationsSection: View {
    @State private var automations: [Automation] = AutomationStore.shared.automations
    @State private var editingID: String?

    var body: some View {
        Section {
            if automations.isEmpty {
                SettingsEmptyState(
                    icon: "clock.arrow.circlepath",
                    title: "No automations yet",
                    hint: "Tell Handle what and when — e.g. \u{201C}every day at 6pm, set my volume to 20\u{201D}.")
            } else {
                ForEach(automations) { a in
                    HStack(spacing: 8) {
                        Image(systemName: a.routineGoal != nil ? "sparkles" : (a.trigger != nil ? "bolt" : "clock.arrow.circlepath"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.body)
                            Text(a.schedule?.describe ?? a.trigger?.describe ?? "manual only").font(.caption).foregroundStyle(.secondary)
                            if a.routineGoal != nil {
                                Text(((a.policy?.standingConsent ?? false) ? "May act without asking" : "Read-only") + " · up to \(AICost.format((a.policy ?? AgentPolicy()).budgetUSD)) / \((a.policy ?? AgentPolicy()).maxSteps) steps per run" + (lastRuns[a.id].map { " · last run \($0)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if a.routineGoal != nil {
                            Toggle("May act", isOn: consentBinding(a)).controlSize(.mini).font(.caption)
                                .help("Standing consent: this automation may take consequential actions without a card. Off = read-only; it says when something needs your OK.")
                            Button("Run") { NotchController.shared.onRunAutomation(a) }
                                .buttonStyle(.handleSolid).controlSize(.small)
                        }
                        Toggle("", isOn: enabledBinding(a)).labelsHidden().controlSize(.mini)
                        Button {
                            editingID = editingID == a.id ? nil : a.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .handleIconHover(idle: editingID == a.id ? Color.white : Color(nsColor: .secondaryLabelColor))
                        .help("Edit")
                        Button { delete(a) } label: {
                            Image(systemName: "trash").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .handleIconHover()
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
                // Creation IS a chat request (a deliberate choice) — the button just
                // opens a fresh chat; the pipeline (parse → recipe/routine →
                // consent card) takes it from there.
                Button("New automation…") { NotchController.shared.onNewChat() }
                    .buttonStyle(.handleSolid)
                Spacer()
            }
        } header: {
            SettingsHeader(icon: "clock.arrow.circlepath", title: "Automations")
        } footer: {
            Text("Approved once when saved; every run lands in Activity.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { automations = AutomationStore.shared.automations }
        .task { await loadLastRuns() }
    }

    @State private var lastRuns: [String: String] = [:]

    private func loadLastRuns() async {
        let routines = automations.filter { $0.routineGoal != nil }
        let found = await AuditLog.shared.lastRuns(for: Set(routines.map { "routine:\($0.name)" }))
        var out: [String: String] = [:]
        for a in routines {
            guard let r = found["routine:\(a.name)"] else { continue }
            let cost = r.summary.hasPrefix("$") ? " · " + (r.summary.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") : ""
            out[a.id] = "\(AuditLog.localTime(fromISO: r.ts)) · \(r.outcome)\(cost)"
        }
        lastRuns = out
    }

    private func consentBinding(_ a: Automation) -> Binding<Bool> {
        Binding(
            get: { AutomationStore.shared.automations.first { $0.id == a.id }?.policy?.standingConsent ?? false },
            set: { on in
                if var u = AutomationStore.shared.automations.first(where: { $0.id == a.id }) {
                    var p = u.policy ?? AgentPolicy()
                    p.standingConsent = on
                    u.policy = p
                    AutomationStore.shared.replace(u)
                    automations = AutomationStore.shared.automations
                }
            }
        )
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

/// Shows the recent tool activity from the local audit log — the visible half of
/// PRODUCT.md's "audit log" differentiator. Read-only; the data never leaves the Mac.
/// In-place editor for one saved automation — name, the schedule time/days or
/// the trigger's fields (within its kind; changing kind = re-ask Handle), and
/// the filled recipe params as JSON. Save validates everything; an edit keeps
/// the standing consent (same recipe, user-reviewed changes) and re-primes
/// Automation permission for any newly-targeted running app.
struct AutomationEditor: View {
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
    @State private var goal: String
    @State private var budget: Double
    @State private var steps: Int
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
        _goal = State(initialValue: original.routineGoal ?? "")
        let policy = original.policy ?? AgentPolicy()
        _budget = State(initialValue: policy.budgetUSD)
        _steps = State(initialValue: policy.maxSteps)
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

            if original.routineGoal != nil {
                TextField("What to do each run", text: $goal, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("Budget per run $").font(.caption).foregroundStyle(.secondary)
                        TextField("", value: $budget, format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder).frame(width: 56)
                    }
                    Stepper("Max steps: \(steps)", value: $steps, in: 1...50).font(.caption)
                    Spacer()
                }
                Text("0 = no budget. Each run stops at whichever limit comes first.").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Recipe params (JSON)", text: $paramsText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1...4)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Save", action: save).buttonStyle(.handleSolid)
                Button("Cancel", action: onCancel).buttonStyle(.borderless)
                    .handleIconHover(idle: Color(nsColor: .secondaryLabelColor))
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

        if original.routineGoal != nil {
            let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !g.isEmpty else { error = "The routine needs a goal."; return }
            updated.routineGoal = g
            var p = updated.policy ?? AgentPolicy()
            p.budgetUSD = max(0, budget)
            p.maxSteps = max(1, min(50, steps))
            updated.policy = p
            error = nil
            onSave(updated)
            return
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

/// S M T W T F S toggle chips (1=Sun … 7=Sat, matching AutomationSchedule).
/// Shared by the automation editor and the Settings creator form.
struct WeekdayPicker: View {
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
