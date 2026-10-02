import Foundation

/// Manages Handle's "allowed folders" — directories where Handle has standing
/// read/write consent. By default this includes the workspace folder plus
/// common user folders (Desktop, Documents, Downloads). The user can extend
/// or restrict the list in Settings.
///
/// The first folder in `allowedFolders` is treated as the **default workspace**:
/// relative paths Claude provides resolve against it, and that's where freshly
/// generated files land if no destination is specified.
@MainActor
final class WorkspaceManager {
    static let shared = WorkspaceManager()
    private init() {}

    private static let workspaceKey = "handle.workspace.path"
    private static let extraFoldersKey = "handle.allowedFolders.extra"

    /// The "default workspace" — first folder in the allowed list. Relative
    /// paths and unqualified file creation default here.
    var workspaceURL: URL {
        if let saved = UserDefaults.standard.string(forKey: Self.workspaceKey), !saved.isEmpty {
            return URL(fileURLWithPath: saved).standardizedFileURL
        }
        return defaultWorkspace
    }

    var defaultWorkspace: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Handle")
            .standardizedFileURL
    }

    /// Always-on default folders Handle can read/write in.
    var defaultAllowedFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            workspaceURL,
            home.appendingPathComponent("Desktop").standardizedFileURL,
            home.appendingPathComponent("Documents").standardizedFileURL,
            home.appendingPathComponent("Downloads").standardizedFileURL,
        ]
    }

    /// Extra folders the user has added in Settings.
    var userExtraFolders: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: Self.extraFoldersKey) ?? []
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    /// Combined: defaults + user-added.
    var allowedFolders: [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in defaultAllowedFolders + userExtraFolders {
            let path = url.path
            if !seen.contains(path) {
                seen.insert(path)
                result.append(url)
            }
        }
        return result
    }

    func setWorkspace(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: Self.workspaceKey)
    }

    func addAllowedFolder(_ url: URL) {
        var current = userExtraFolders.map(\.path)
        let p = url.standardizedFileURL.path
        if !current.contains(p) {
            current.append(p)
            UserDefaults.standard.set(current, forKey: Self.extraFoldersKey)
        }
    }

    func removeAllowedFolder(_ url: URL) {
        var current = userExtraFolders.map(\.path)
        let p = url.standardizedFileURL.path
        current.removeAll { $0 == p }
        UserDefaults.standard.set(current, forKey: Self.extraFoldersKey)
    }

    /// Create the workspace folder on disk if it doesn't exist yet.
    @discardableResult
    func ensureWorkspaceExists() throws -> URL {
        let url = workspaceURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// True if `url` is inside any allowed folder (or is the folder itself).
    func isAllowed(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        for folder in allowedFolders {
            let p = folder.path
            if target == p || target.hasPrefix(p.hasSuffix("/") ? p : p + "/") {
                return true
            }
        }
        return false
    }

    /// Resolve a path string Claude provided.
    /// - Absolute paths (`/...` or `~/...`) are taken as-is.
    /// - Relative paths are resolved against the workspace root.
    func resolve(_ path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath).standardizedFileURL
        }
        return workspaceURL.appendingPathComponent(trimmed).standardizedFileURL
    }

    /// Format a path nicely for display (replace home with ~).
    func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~/" + String(path.dropFirst(home.count + 1))
        }
        return path
    }
}
