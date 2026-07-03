import Foundation
import os.log

private let trigLog = Logger(subsystem: "com.dimarussu.Akari", category: "Agent")

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
    private var recentFires: Set<String> = []             // "autoID|file" dedupe

    static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

    /// Does `filename` pass the trigger's extension filter?
    static func matches(ext: String?, filename: String) -> Bool {
        guard let ext, !ext.isEmpty else { return true }
        let want = ext.trimmingCharacters(in: .init(charactersIn: ". ")).lowercased()
        return (filename as NSString).pathExtension.lowercased() == want
    }

    /// Reconcile watchers with the enabled fileAppears automations in the store.
    /// Called at launch, after saving a triggered automation, and after toggles/deletes.
    func refresh() {
        let wanted = Set(AutomationStore.shared.automations
            .filter { $0.enabled && $0.trigger?.kind == "fileAppears" }
            .compactMap { $0.trigger?.folder.map(Self.expand) })
        for gone in Set(watchers.keys).subtracting(wanted) { watchers[gone] = nil }
        for folder in wanted where watchers[folder] == nil {
            watchers[folder] = FolderWatcher(path: folder) { [weak self] files in
                Task { @MainActor in self?.handleNewFiles(files, in: folder) }
            }
            trigLog.info("triggers: \(self.watchers[folder] == nil ? "FAILED to watch" : "watching", privacy: .public) \(folder, privacy: .public)")
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
}
