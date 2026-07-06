import SwiftUI
import AppKit

/// First-run gate + hardware verdict (PRODUCT.md: refuse below M1/16 GB
/// rather than degrade). Pure logic split out so self-tests can hit it.
enum Onboarding {
    static let doneKey = "akari.onboarding.done"

    @MainActor static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    /// The minimum bar: Apple Silicon + 16 GB.
    static func hardwareOK(memGB: Int, isAppleSilicon: Bool) -> Bool {
        isAppleSilicon && memGB >= 16
    }

    static var currentMemGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1 << 30))
    }

    static var currentIsAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.hasPrefix("arm64")
    }
}

/// The first-run walk-through, as a page inside the notch panel (the notch is
/// the app's only surface). Four steps: hardware verdict → staged permissions
/// (each with its rationale, skippable) → model disclosure + download with
/// visible progress and retry → ready + example queries.
struct OnboardingBody: View {
    let onDone: () -> Void
    @State private var step = 0
    private let hardwareOK = Onboarding.hardwareOK(memGB: Onboarding.currentMemGB,
                                                   isAppleSilicon: Onboarding.currentIsAppleSilicon)

    var body: some View {
        VStack(alignment: .leading, spacing: AkariSpacing.m) {
            switch step {
            case 0:  welcome
            case 1:  permissions
            case 2:  modelDownload
            default: ready
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Step 0 — welcome + hardware verdict
    private var welcome: some View {
        VStack(alignment: .leading, spacing: AkariSpacing.m) {
            Text("Welcome to Akari")
                .font(.akariSection)
            Text("The private Mac AI that lives in your notch. It sees your screen, answers, and acts — entirely on this Mac. Nothing you show it or say to it ever leaves.")
                .font(.akariBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hardwareOK {
                Label("This Mac is ready (Apple Silicon, \(Onboarding.currentMemGB) GB memory).",
                      systemImage: "checkmark.circle.fill")
                    .font(.akariBody)
                    .foregroundStyle(.green)
                Button("Continue") { step = 1 }
                    .buttonStyle(.akariSolid)
            } else {
                Label("Akari needs an Apple Silicon Mac (M1 or later) with at least 16 GB of memory. This Mac doesn't meet that bar, so the local AI would be too slow to be useful.",
                      systemImage: "xmark.octagon.fill")
                    .font(.akariBody)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Quit Akari") { NSApp.terminate(nil) }
                    .buttonStyle(.akariSolid)
            }
        }
    }

    // Step 1 — staged permissions with rationale
    private var permissions: some View {
        VStack(alignment: .leading, spacing: AkariSpacing.m) {
            Text("Permissions")
                .font(.akariSection)
            Text("Each one unlocks a part of Akari. Grant them now, or skip — Akari asks again the first time a feature needs one.")
                .font(.akariBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            OnboardingPermissionList()
            HStack {
                Button("Continue") { step = 2 }
                    .buttonStyle(.akariSolid)
                Button("Skip for now") { step = 2 }
                    .buttonStyle(.borderless)
            }
        }
    }

    // Step 2 — model disclosure + download (with visible progress and retry)
    private var modelDownload: some View {
        VStack(alignment: .leading, spacing: AkariSpacing.m) {
            Text("The AI lives on your Mac")
                .font(.akariSection)
            Text("Akari downloads its model once, then never needs the internet for AI again.")
                .font(.akariBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Label("Qwen3-VL 4B (vision + language) — about 2.5 GB", systemImage: "brain")
                Label("Whisper (voice, downloads on first talk) — about 0.6 GB", systemImage: "waveform")
                Label("Needs roughly 10 GB of free disk in total", systemImage: "internaldrive")
            }
            .font(.akariBody)
            .foregroundStyle(.secondary)
            OnboardingDownload(onFinished: { step = 3 })
            Button("Skip — download on first use") { step = 3 }
                .buttonStyle(.borderless)
        }
    }

    // Step 3 — ready + example queries
    private var ready: some View {
        VStack(alignment: .leading, spacing: AkariSpacing.m) {
            Text("You're set")
                .font(.akariSection)
            VStack(alignment: .leading, spacing: 4) {
                Label("Hover the notch and ask anything — Akari sees your screen", systemImage: "eye")
                Label("Try \u{201C}what's this error?\u{201D} or \u{201C}click the send button\u{201D}", systemImage: "cursorarrow.rays")
                Label("Hold ⌃⌥Space and speak — nothing audible leaves this Mac", systemImage: "mic")
                Label("Say \u{201C}every day at 6pm, set my volume to 20\u{201D} to automate", systemImage: "clock.arrow.circlepath")
            }
            .font(.akariBody)
            .foregroundStyle(.secondary)
            Button("Start using Akari") {
                Onboarding.isDone = true
                onDone()
            }
            .buttonStyle(.akariSolid)
        }
    }
}

/// The onboarding permission rows — same status source as Settings →
/// Permissions, but each row can PROMPT (that's the point of staging them
/// here: the dialogs fire while the user is watching, with the reason fresh).
private struct OnboardingPermissionList: View {
    struct Row: Identifiable {
        let id: String
        let icon: String
        let name: String
        let why: String
        let status: PermissionsService.Status
        let request: () -> Void
    }
    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { r in
                HStack(spacing: 8) {
                    Image(systemName: r.icon)
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).font(.akariBody)
                        Text(r.why).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if r.status == .granted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(.green)
                    } else {
                        Button("Grant") { r.request(); refreshSoon() }
                            .buttonStyle(.akariSolid)
                    }
                }
            }
        }
        .task { await refresh() }
    }

    private func refreshSoon() {
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await refresh() }
    }

    @MainActor
    private func refresh() async {
        rows = [
            Row(id: "sr", icon: "rectangle.dashed.badge.record", name: "Screen Recording",
                why: "so Akari can see the screen you're asking about",
                status: PermissionsService.screenRecording(),
                request: { PermissionsService.requestScreenRecording() }),
            Row(id: "ax", icon: "hand.point.up.left", name: "Accessibility",
                why: "so Akari can point at and click things for you",
                status: PermissionsService.accessibility(),
                request: { PermissionsService.requestAccessibility() }),
            Row(id: "mic", icon: "mic", name: "Microphone",
                why: "so you can talk to Akari (transcribed on-device)",
                status: PermissionsService.microphone(),
                request: { PermissionsService.requestMicrophone() }),
            Row(id: "cal", icon: "calendar", name: "Calendars",
                why: "so Akari can read and add events",
                status: PermissionsService.calendars(),
                request: { PermissionsService.requestCalendars() }),
            Row(id: "rem", icon: "checklist", name: "Reminders",
                why: "so Akari can read and add to-dos",
                status: PermissionsService.reminders(),
                request: { PermissionsService.requestReminders() }),
            Row(id: "not", icon: "bell.badge", name: "Notifications",
                why: "so finished background tasks can tell you",
                status: await PermissionsService.notifications(),
                request: { PermissionsService.requestNotifications() }),
        ]
    }
}

/// Download button + live progress driven by LocalEngine's observable load
/// state; failure shows the error and a Retry (ensureVisionModel resets its
/// in-flight task on failure, so calling again really retries).
private struct OnboardingDownload: View {
    let onFinished: () -> Void
    @ObservedObject private var engine = LocalEngine.shared
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch engine.visionState {
            case .notLoaded:
                Button("Download now") { start() }
                    .buttonStyle(.akariSolid)
            case .downloading(let f):
                ProgressView(value: f) {
                    Text(f < 0.001 ? "Starting download…" : "Downloading… \(Int(f * 100))%")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .progressViewStyle(.linear)
            case .loading:
                ProgressView { Text("Loading the model…").font(.system(size: 10)).foregroundStyle(.secondary) }
            case .ready:
                Label("Model ready.", systemImage: "checkmark.circle.fill")
                    .font(.akariBody).foregroundStyle(.green)
                    .onAppear { if started { onFinished() } }
            case .failed(let why):
                Label("Download failed: \(why)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { start() }
                    .buttonStyle(.akariSolid)
            }
        }
    }

    private func start() {
        started = true
        Task { _ = try? await LocalEngine.shared.ensureVisionModel() }
    }
}
