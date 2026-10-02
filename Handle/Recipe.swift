import Foundation

/// A parameterized automation recipe — the load-bearing unit of Handle's agentic
/// layer (see AGENTS.md). The local 7B does NOT plan; it SELECTS a recipe (by index,
/// the pointing trick) and FILLS its params (its proven strength). The recipe's body
/// carries the reliability the 7B can't generate.
///
/// Prototype: recipes are hardcoded in `RecipeLibrary`. Phase 2 loads `*.md` files
/// (frontmatter + body) mined from macos-automator-mcp.
struct Recipe: Identifiable {
    let id: String
    let title: String
    let description: String
    let keywords: [String]
    let params: [RecipeParam]
    /// Shown on the confirm card, e.g. "Quit ${apps}".
    let confirmTemplate: String
    /// AppleScript with `${param}` placeholders, run via `run_applescript`.
    let body: String

    /// Substitute `${name}` placeholders in `template`, formatting each value by its
    /// declared type (a list → AppleScript items `"a", "b"`, ints bare, strings raw).
    func resolve(_ template: String, with values: [String: Any]) -> String {
        var out = template
        for p in params {
            out = out.replacingOccurrences(of: "${\(p.name)}", with: p.substitution(from: values[p.name]))
        }
        return out
    }

    var resolvedBodyPlaceholders: [String] { params.map { $0.name } }
}

struct RecipeParam {
    let name: String
    let type: ParamType
    let prompt: String
    var `default`: String? = nil

    enum ParamType {
        case string, int, stringList
        case oneOf([String])

        var describe: String {
            switch self {
            case .string:        return "text"
            case .int:           return "a number"
            case .stringList:    return "a list of names"
            case .oneOf(let o):  return "one of: " + o.joined(separator: ", ")
            }
        }

        var isScalar: Bool { if case .stringList = self { return false }; return true }
    }

    /// Format a filled value for AppleScript substitution.
    func substitution(from raw: Any?) -> String {
        var raw = raw
        // The 7B sometimes wraps a scalar in a 1-element array ([25], ["true"]) — unwrap it.
        if type.isScalar, let arr = raw as? [Any], arr.count == 1 { raw = arr[0] }
        switch type {
        case .stringList:
            if let arr = raw as? [Any] { return arr.map { "\"\($0)\"" }.joined(separator: ", ") }
            if let s = raw as? String { return "\"\(s)\"" }   // single-value fallback
            return "\"\""
        case .int:
            if let n = raw as? NSNumber { return "\(n.intValue)" }
            if let s = raw as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return "\(i)" }
            return `default` ?? "0"
        case .string:
            if let s = raw as? String { return s }
            if let raw { return "\(raw)" }
            return `default` ?? ""
        case .oneOf(let opts):
            let v = (raw as? String) ?? raw.map { "\($0)" } ?? ""
            // Exact (case-insensitive) match wins.
            if let m = opts.first(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) { return m }
            // Coerce boolean-ish values (1/on/yes ↔ 0/off/no) onto a true/false-style enum.
            let truthy: Set<String> = ["1", "true", "on", "yes", "enable", "enabled"]
            let falsy:  Set<String> = ["0", "false", "off", "no", "disable", "disabled"]
            if truthy.contains(v.lowercased()), let t = opts.first(where: { ["true", "on", "yes", "enabled"].contains($0.lowercased()) }) { return t }
            if falsy.contains(v.lowercased()),  let f = opts.first(where: { ["false", "off", "no", "disabled"].contains($0.lowercased()) }) { return f }
            return `default` ?? opts.first ?? v
        }
    }
}

/// The seed recipe library (prototype — hardcoded). Chosen to be common, distinct
/// (so retrieval is testable), and parameterized (so fill is testable).
enum RecipeLibrary {
    static let all: [Recipe] = [
        Recipe(id: "quit-apps", title: "Quit applications",
               description: "Quit one or more running apps.",
               keywords: ["quit", "close", "exit", "kill", "shut"],
               params: [RecipeParam(name: "apps", type: .stringList, prompt: "The app names to quit, e.g. Mail, Slack")],
               confirmTemplate: "Quit ${apps}",
               body: "repeat with a in {${apps}}\n    tell application (contents of a) to quit\nend repeat"),

        Recipe(id: "open-folder", title: "Open a folder",
               description: "Open a folder in Finder (Downloads, Documents, Desktop, any path).",
               keywords: ["open", "folder", "directory", "finder", "reveal", "show"],
               params: [RecipeParam(name: "path", type: .string, prompt: "Folder path, e.g. ~/Downloads")],
               confirmTemplate: "Open ${path}",
               body: "do shell script \"open \" & quoted form of (\"${path}\")"),

        Recipe(id: "music-control", title: "Control Music playback",
               description: "Play, pause, or skip tracks in the Music app.",
               keywords: ["music", "play", "pause", "song", "track", "skip", "resume", "stop"],
               params: [RecipeParam(name: "action", type: .oneOf(["play", "pause", "next track", "previous track"]),
                                    prompt: "One of: play, pause, next track, previous track")],
               confirmTemplate: "Music: ${action}",
               body: "tell application \"Music\" to ${action}"),

        Recipe(id: "set-volume", title: "Set system volume",
               description: "Set the Mac output volume from 0 to 100.",
               keywords: ["volume", "sound", "loud", "quiet", "turn up", "turn down"],
               params: [RecipeParam(name: "level", type: .int, prompt: "Volume from 0 to 100")],
               confirmTemplate: "Set volume to ${level}",
               body: "set volume output volume ${level}"),

        Recipe(id: "new-note", title: "Create a note",
               description: "Create a new note in the Notes app with a title and body.",
               keywords: ["note", "notes", "jot", "memo", "write down", "remember"],
               params: [RecipeParam(name: "title", type: .string, prompt: "Note title"),
                        RecipeParam(name: "body", type: .string, prompt: "Note body text")],
               confirmTemplate: "New note “${title}”",
               body: "tell application \"Notes\" to make new note with properties {name:\"${title}\", body:\"${body}\"}"),

        Recipe(id: "empty-trash", title: "Empty the Trash",
               description: "Permanently empty the macOS Trash.",
               keywords: ["trash", "empty", "bin", "garbage", "clear trash"],
               params: [],
               confirmTemplate: "Empty the Trash",
               body: "tell application \"Finder\" to empty trash"),

        Recipe(id: "web-search", title: "Search the web",
               description: "Open a web search in the default browser.",
               keywords: ["search", "google", "look up", "find online", "web"],
               params: [RecipeParam(name: "query", type: .string, prompt: "What to search for")],
               confirmTemplate: "Search the web for “${query}”",
               body: "open location \"https://www.google.com/search?q=${query}\""),

        Recipe(id: "dark-mode", title: "Toggle Dark Mode",
               description: "Turn macOS Dark Mode on or off.",
               keywords: ["dark mode", "light mode", "appearance", "theme", "dark", "light"],
               params: [RecipeParam(name: "state", type: .oneOf(["true", "false"]), prompt: "true for dark, false for light")],
               confirmTemplate: "Set Dark Mode to ${state}",
               body: "tell application \"System Events\" to tell appearance preferences to set dark mode to ${state}"),
    ]

    /// Keyword prefilter: score recipes by goal overlap, best first. At 200-recipe
    /// scale this narrows to a shortlist; for the prototype's 8 it just orders them.
    /// Returns all (ordered) when nothing matches — let the model decide or decline.
    static func prefilter(_ goal: String, in recipes: [Recipe] = all, limit: Int = 8) -> [Recipe] {
        let g = goal.lowercased()
        let scored = recipes.map { r -> (Recipe, Int) in
            var s = 0
            for kw in r.keywords where g.contains(kw) { s += 2 }
            for w in r.title.lowercased().split(separator: " ") where w.count >= 3 && g.contains(w) { s += 1 }
            return (r, s)
        }
        // Strict: only keyword hits (empty = no recipe fits → the loop falls through to
        // freeform tools, no wasted model call).
        return Array(scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit)).map { $0.0 }
    }
}

/// Parses a recipe `.md` file — frontmatter (between `---` lines) + AppleScript body.
/// Deliberately-simple non-YAML frontmatter so we need no dependency:
///   id: quit-apps
///   title: Quit applications
///   keywords: quit, close, exit                     (comma-separated)
///   confirm: Quit ${apps}
///   param: apps | stringList | prompt text | default   (one line per param; type is
///          string | int | stringList | oneOf(a,b,c))
enum RecipeFile {
    static func parse(_ text: String) -> Recipe? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var i = start + 1
        var meta: [String: String] = [:], params: [RecipeParam] = [], keywords: [String] = []
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            defer { i += 1 }
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "keywords": keywords = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "param":    if let p = parseParam(val) { params.append(p) }
            default:         meta[key] = val
            }
        }
        i += 1   // skip closing ---
        let body = i < lines.count ? lines[i...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard let id = meta["id"], let title = meta["title"], !body.isEmpty else { return nil }
        return Recipe(id: id, title: title, description: meta["description"] ?? "",
                      keywords: keywords, params: params, confirmTemplate: meta["confirm"] ?? title, body: body)
    }

    private static func parseParam(_ s: String) -> RecipeParam? {
        let p = s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.count >= 3, !p[0].isEmpty else { return nil }
        return RecipeParam(name: p[0], type: parseType(p[1]), prompt: p[2],
                           default: p.count >= 4 && !p[3].isEmpty ? p[3] : nil)
    }

    private static func parseType(_ s: String) -> RecipeParam.ParamType {
        if s.hasPrefix("oneOf(") && s.hasSuffix(")") {
            return .oneOf(String(s.dropFirst(6).dropLast()).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        switch s.lowercased() {
        case "int":        return .int
        case "stringlist": return .stringList
        default:           return .string
        }
    }
}

/// The live recipe set: built-in `RecipeLibrary.all` PLUS any `*.md` files in
/// ~/Library/Application Support/Handle/recipes/ (a file with a built-in's id overrides
/// it). This is how the library grows — mining macos-automator-mcp writes .md files here,
/// and Phase 3 saves user automations the same way. No recompile to add a recipe.
@MainActor
final class RecipeStore {
    static let shared = RecipeStore()
    private let dir: URL
    private var fileRecipes: [Recipe] = []

    private init() {
        dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
               ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Handle/recipes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
    }

    var recipesDir: URL { dir }

    /// Built-ins + file recipes (files override built-ins by id).
    var recipes: [Recipe] {
        let overridden = Set(fileRecipes.map { $0.id })
        return RecipeLibrary.all.filter { !overridden.contains($0.id) } + fileRecipes
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        fileRecipes = files.filter { $0.pathExtension == "md" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .compactMap(RecipeFile.parse)
        if !fileRecipes.isEmpty { print("[RecipeStore] loaded \(fileRecipes.count) file recipe(s) from \(dir.path)") }
    }
}
