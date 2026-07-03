import Foundation
import AppKit
import CoreWLAN
import os.log

private let trigLog = Logger(subsystem: "com.dimarussu.Akari", category: "Agent")

/// Wi-Fi association watcher — event-driven via CWWiFiClient's ssidDidChange event.
/// NOTE: reading the SSID string requires Location permission on modern macOS; without
/// it `ssid()` returns nil, so named-network triggers can't match (any-network triggers
/// still fire). Surfacing that permission is onboarding work (task #16).
final class WifiWatcher: NSObject, CWEventDelegate {
    private let onChange: (String?) -> Void
    private let client = CWWiFiClient.shared()

    init?(onChange: @escaping (String?) -> Void) {
        self.onChange = onChange
        super.init()
        client.delegate = self
        do { try client.startMonitoringEvent(with: .ssidDidChange) } catch {
            trigLog.error("triggers: wifi monitoring failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        let ssid = client.interface(withName: interfaceName)?.ssid()
        onChange(ssid)
    }

    deinit {
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
    }
}

/// Watches ONE folder for NEW files — event-driven (kqueue via DispatchSource on the
/// directory fd; the directory "writes" when an entry is added/removed), no polling.
/// New entries are detected by diffing a name snapshot, debounced so a burst of file
/// events (download + rename, Finder writing .DS_Store) coalesces into one callback.
///
/// Deliberately single-folder, non-recursive: exactly what "a file appears in
/// ~/Downloads" needs. If/when multi-folder trees land, swap the backend to FSEvents
/// (see REPOS.md §3) behind the same callback.
final class FolderWatcher {
    let path: String                       // expanded absolute path
    private let fd: Int32
    private let source: DispatchSourceFileSystemObject
    private var known: Set<String>
    private var pending: DispatchWorkItem?

    /// Names in `now` that aren't in `known`, ignoring dotfiles (.DS_Store etc.).
    static func newEntries(known: Set<String>, now: Set<String>) -> [String] {
        now.subtracting(known).filter { !$0.hasPrefix(".") }.sorted()
    }

    init?(path: String, onNewFiles: @escaping ([String]) -> Void) {
        let expanded = (path as NSString).expandingTildeInPath
        let fd = open(expanded, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.path = expanded
        self.fd = fd
        self.known = Set((try? FileManager.default.contentsOfDirectory(atPath: expanded)) ?? [])
        self.source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let now = Set((try? FileManager.default.contentsOfDirectory(atPath: self.path)) ?? [])
                let fresh = Self.newEntries(known: self.known, now: now)
                self.known = now
                if !fresh.isEmpty { onNewFiles(fresh) }
            }
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

/// The reactive half of the automation layer (Phase 6, AGENTS.md): matches LOCAL
/// events to saved automations and fires them under the same standing consent as the
/// time scheduler — approved once at save, no card at fire time, every run audited.
/// Event-driven throughout; costs ~nothing at idle.
@MainActor
final class TriggerEngine {
    static let shared = TriggerEngine()
    private init() {}

    /// Set by the AppDelegate at launch: runs the automation (merging `extra` into the
    /// recipe substitutions — e.g. trigger_file = the new file's full path).
    var onFire: ((Automation, [String: String]) -> Void)?

    private var watchers: [String: FolderWatcher] = [:]   // expanded folder → watcher
    private var recentFires: Set<String> = []             // "autoID|file" / "autoID|pid" dedupe
    private var appLaunchObserver: NSObjectProtocol?
    private var wifiWatcher: WifiWatcher?
    private var lastSSID: String?

    static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

    /// Does `filename` pass the trigger's extension filter?
    static func matches(ext: String?, filename: String) -> Bool {
        guard let ext, !ext.isEmpty else { return true }
        let want = ext.trimmingCharacters(in: .init(charactersIn: ". ")).lowercased()
        return (filename as NSString).pathExtension.lowercased() == want
    }

    /// Does a launched app (name and/or bundle id) match the trigger's `app`?
    /// Normalized contains-either-way, so "zoom" matches "zoom.us" and "us.zoom.xos".
    static func appMatches(want: String?, name: String?, bundleID: String?) -> Bool {
        guard let want, !want.isEmpty else { return false }
        let w = normalized(want)
        guard !w.isEmpty else { return false }
        for candidate in [name, bundleID].compactMap({ $0 }) {
            let c = normalized(candidate)
            if !c.isEmpty, c.contains(w) || w.contains(c) { return true }
        }
        return false
    }

    /// Does a joined network match the trigger's `ssid`? nil = any network.
    static func ssidMatches(want: String?, got: String?) -> Bool {
        guard let want, !want.isEmpty else { return true }
        guard let got else { return false }
        return normalized(want) == normalized(got)
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private var enabledTriggers: [Automation] {
        AutomationStore.shared.automations.filter { $0.enabled && $0.trigger != nil }
    }

    /// Reconcile event sources with the enabled triggered automations in the store.
    /// Called at launch, after saving a triggered automation, and after toggles/deletes.
    /// Each source runs only while at least one automation needs it.
    func refresh() {
        let triggers = enabledTriggers

        // fileAppears → one FolderWatcher per unique folder
        let wanted = Set(triggers.filter { $0.trigger?.kind == "fileAppears" }
            .compactMap { $0.trigger?.folder.map(Self.expand) })
        for gone in Set(watchers.keys).subtracting(wanted) { watchers[gone] = nil }
        for folder in wanted where watchers[folder] == nil {
            watchers[folder] = FolderWatcher(path: folder) { [weak self] files in
                Task { @MainActor in self?.handleNewFiles(files, in: folder) }
            }
            trigLog.info("triggers: \(self.watchers[folder] == nil ? "FAILED to watch" : "watching", privacy: .public) \(folder, privacy: .public)")
        }

        // appLaunches → one NSWorkspace observer while any exist
        let needsAppSource = triggers.contains { $0.trigger?.kind == "appLaunches" }
        if needsAppSource, appLaunchObserver == nil {
            appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let name = app?.localizedName, bundle = app?.bundleIdentifier, pid = app?.processIdentifier ?? -1
                Task { @MainActor in self?.handleAppLaunch(name: name, bundleID: bundle, pid: pid) }
            }
            trigLog.info("triggers: watching app launches")
        } else if !needsAppSource, let obs = appLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appLaunchObserver = nil
        }

        // wifiConnects → one CoreWLAN watcher while any exist
        let needsWifi = triggers.contains { $0.trigger?.kind == "wifiConnects" }
        if needsWifi, wifiWatcher == nil {
            lastSSID = CWWiFiClient.shared().interface()?.ssid()
            wifiWatcher = WifiWatcher { [weak self] ssid in
                Task { @MainActor in self?.handleWifiChange(ssid: ssid) }
            }
            trigLog.info("triggers: \(self.wifiWatcher == nil ? "FAILED to watch" : "watching", privacy: .public) Wi-Fi (ssid readable: \(self.lastSSID != nil))")
        } else if !needsWifi {
            wifiWatcher = nil
        }
    }

    private func handleNewFiles(_ files: [String], in folder: String) {
        for a in AutomationStore.shared.automations {
            guard a.enabled, let t = a.trigger, t.kind == "fileAppears",
                  let f = t.folder, Self.expand(f) == folder else { continue }
            for file in files where Self.matches(ext: t.ext, filename: file) {
                let key = "\(a.id)|\(file)"
                guard !recentFires.contains(key) else { continue }
                recentFires.insert(key)
                if recentFires.count > 500 { recentFires.removeAll() }   // cheap cap
                trigLog.info("triggers: firing \"\(a.name, privacy: .public)\" — new file \(file, privacy: .public)")
                onFire?(a, ["trigger_file": (folder as NSString).appendingPathComponent(file)])
            }
        }
    }

    private func handleAppLaunch(name: String?, bundleID: String?, pid: Int32) {
        for a in AutomationStore.shared.automations {
            guard a.enabled, let t = a.trigger, t.kind == "appLaunches",
                  Self.appMatches(want: t.app, name: name, bundleID: bundleID) else { continue }
            let key = "\(a.id)|pid\(pid)"       // a RE-launch (new pid) fires again
            guard !recentFires.contains(key) else { continue }
            recentFires.insert(key)
            trigLog.info("triggers: firing \"\(a.name, privacy: .public)\" — \(name ?? bundleID ?? "app", privacy: .public) launched")
            onFire?(a, ["trigger_app": name ?? bundleID ?? ""])
        }
    }

    private func handleWifiChange(ssid: String?) {
        guard ssid != lastSSID else { return }   // association events repeat; fire on change
        lastSSID = ssid
        guard ssid != nil || AutomationStore.shared.automations.contains(where: { $0.trigger?.kind == "wifiConnects" && $0.trigger?.ssid == nil }) else { return }
        for a in AutomationStore.shared.automations {
            guard a.enabled, let t = a.trigger, t.kind == "wifiConnects",
                  Self.ssidMatches(want: t.ssid, got: ssid) else { continue }
            // nil ssid means "left a network / unreadable" — only any-network triggers
            // with a real join should fire; skip the disconnect edge entirely.
            guard ssid != nil else { continue }
            trigLog.info("triggers: firing \"\(a.name, privacy: .public)\" — Wi-Fi changed")
            onFire?(a, ["trigger_ssid": ssid ?? ""])
        }
    }
}
