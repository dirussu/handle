import SwiftUI
import AppKit

/// Every TCC permission Handle depends on, with live status — plus per-app Automation
/// consent for the apps saved automations control. The staging half lives in the save
/// flows (PermissionsService.primeAutomationTargets); this is the visible half.
struct PermissionsSection: View {
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
                            Button("Ask") { ask(); refreshSoon() }.buttonStyle(.handleSolid)
                        } else if let pane = p.pane {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(PermissionsService.settingsURL(pane: pane))
                            }.buttonStyle(.handleSolid)
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
            // is Handle's only completion surface and needs no permission.)
        ]
        // Location exists ONLY because macOS gates Wi-Fi SSID reads behind it
        // (named-network triggers). A permanent "Location" row in a privacy-
        // first app reads wrong — show it only once a
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
