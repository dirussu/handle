import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import CoreLocation
import EventKit
import UserNotifications
import os.log

private let permLog = Logger(subsystem: "com.dimarussu.Handle", category: "Agent")

/// TCC permission awareness + staging (task #16). Two jobs:
///  1. STATUS — read every permission Handle depends on, for the Settings panel.
///  2. STAGING — surface consent dialogs at moments the user is PRESENT. The killer
///     case: an automation saved with standing consent fires later (scheduled or
///     triggered) and macOS pops its per-app Automation dialog with nobody at the
///     Mac — the AppleEvent times out and the run dies. So at SAVE time we "prime"
///     each app the recipe controls via AEDeterminePermissionToAutomateTarget,
///     putting the dialog on screen right after the user tapped Save.
enum PermissionsService {

    enum Status: Equatable {
        case granted, denied, notDetermined
        case unavailable(String)   // e.g. Automation target not running — can't know yet

        var label: String {
            switch self {
            case .granted:            return "Granted"
            case .denied:             return "Denied"
            case .notDetermined:      return "Not asked yet"
            case .unavailable(let s): return s
            }
        }
    }

    // MARK: - Status reads (non-interactive)

    static func accessibility() -> Status { AXIsProcessTrusted() ? .granted : .denied }

    static func screenRecording() -> Status { CGPreflightScreenCaptureAccess() ? .granted : .denied }

    static func calendars() -> Status { ekStatus(EKEventStore.authorizationStatus(for: .event)) }
    static func reminders() -> Status { ekStatus(EKEventStore.authorizationStatus(for: .reminder)) }

    private static func ekStatus(_ s: EKAuthorizationStatus) -> Status {
        switch s {
        case .fullAccess, .writeOnly: return .granted
        case .notDetermined:          return .notDetermined
        default:                      return .denied
        }
    }

    static func location() -> Status {
        switch CLLocationManager().authorizationStatus {
        case .authorized, .authorizedAlways: return .granted
        case .notDetermined:                 return .notDetermined
        default:                             return .denied
        }
    }

    static func notifications() async -> Status {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional: return .granted
        case .notDetermined:            return .notDetermined
        default:                        return .denied
        }
    }

    static func microphone() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .notDetermined: return .notDetermined
        default:             return .denied
        }
    }

    static func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // Onboarding-time prompts. AX/SR "denied" really means "not in the list
    // yet" on first run — these put the app IN the list with the system prompt.

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func requestCalendars() {
        EKEventStore().requestFullAccessToEvents { _, _ in }
    }

    static func requestReminders() {
        EKEventStore().requestFullAccessToReminders { _, _ in }
    }

    // MARK: - Automation (AppleEvents) — per-target-app

    /// Map AEDeterminePermissionToAutomateTarget's OSStatus to a Status.
    /// -1744 = would need to ask; -1743 = user denied; -600 = target not running.
    static func mapAEStatus(_ err: OSStatus) -> Status {
        switch err {
        case noErr:                                 return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted):      return .denied
        case OSStatus(procNotFound):                return .unavailable("App not running")
        default:                                    return .unavailable("Error \(err)")
        }
    }

    /// The apps a recipe body controls: every `tell application "X"` /
    /// `tell application id "y"` target, deduped, in order of appearance.
    static func tellTargets(in script: String) -> [String] {
        let pattern = #"tell application (?:id )?"([^"]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var seen = Set<String>(), out: [String] = []
        for m in re.matches(in: script, range: NSRange(script.startIndex..., in: script)) {
            guard let r = Range(m.range(at: 1), in: script) else { continue }
            let name = String(script[r])
            if seen.insert(name.lowercased()).inserted { out.append(name) }
        }
        return out
    }

    /// Non-interactive Automation status for one app (by tell-target name or bundle id).
    static func automationStatus(for appName: String) -> Status {
        guard let app = runningApp(named: appName) else { return .unavailable("App not running") }
        return determinePermission(pid: app.processIdentifier, askIfNeeded: false)
    }

    /// SAVE-TIME PRIME: for each app the script controls, pop the Automation consent
    /// dialog NOW if it would otherwise appear at first fire. Runs off-main (the AE
    /// call blocks while the dialog is up). Returns the targets that could not be
    /// primed because they aren't running — the caller warns the user about those.
    @discardableResult
    static func primeAutomationTargets(inScript script: String) -> [String] {
        let targets = tellTargets(in: script)
        var notRunning: [String] = []
        for name in targets {
            guard let app = runningApp(named: name) else {
                notRunning.append(name)
                permLog.info("perms: cannot prime \(name, privacy: .public) — not running")
                continue
            }
            let pid = app.processIdentifier
            DispatchQueue.global(qos: .userInitiated).async {
                let status = determinePermission(pid: pid, askIfNeeded: true)
                permLog.info("perms: primed \(name, privacy: .public) → \(status.label, privacy: .public)")
            }
        }
        return notRunning
    }

    private static func runningApp(named name: String) -> NSRunningApplication? {
        let want = name.lowercased()
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased() == want || $0.bundleIdentifier?.lowercased() == want
        }
    }

    private static func determinePermission(pid: pid_t, askIfNeeded: Bool) -> Status {
        var addr = NSAppleEventDescriptor(processIdentifier: pid).aeDesc?.pointee ?? AEAddressDesc()
        let err = AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, askIfNeeded)
        return mapAEStatus(err)
    }

    // MARK: - Requests + deep links

    /// Ask for Location (needed to read Wi-Fi SSIDs for named-network triggers).
    /// The manager must outlive the request, hence the static retain.
    private static let locationManager = CLLocationManager()
    static func requestLocation() {
        locationManager.requestWhenInUseAuthorization()
    }

    static func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// System Settings → Privacy & Security deep link for a given pane.
    static func settingsURL(pane: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    /// Notifications live outside Privacy & Security — their own Settings extension.
    static let notificationsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
}
