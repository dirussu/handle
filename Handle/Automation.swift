import Foundation

/// A saved, optionally-scheduled automation: a recipe + its filled params, approved
/// ONCE at save time (standing consent) so a SCHEDULED run needs no confirm card
/// (the user isn't there). Every run is still written to the audit log. See AGENTS.md.
///
/// Two payload kinds share this struct (flat, so Codable stays synthesized and old
/// automations.json files keep decoding):
/// - RECIPE (routineGoal == nil): resolved script, runs verbatim — deterministic.
/// - ROUTINE (routineGoal != nil): an agentic GOAL; each run gathers fresh via
///   read-only tools + MCP connectors, the local model synthesizes, and the result
///   lands under the notch ("every morning, summarize my calendar"). v2 #2.
struct Automation: Codable, Identifiable {
    var id: String
    var name: String
    var recipeId: String
    var paramsJSON: String            // the filled params, as JSON
    var schedule: AutomationSchedule? // nil = no time trigger
    var trigger: AutomationTrigger?   // nil = no event trigger (see TriggerEngine)
    var enabled: Bool = true
    var lastRunKey: String = ""       // "yyyy-MM-dd-HH-mm" — dedupe so a minute fires once
    var routineGoal: String?          // set = ROUTINE (see above); recipeId is ignored
    var policy: AgentPolicy? = nil    // what a routine may do (nil = read-only, no standing consent)

    /// A routine's display name: the goal's first line, capped like chat titles.
    static func routineName(_ goal: String) -> String {
        let firstLine = goal.split(separator: "\n").first.map(String.init) ?? goal
        return String(firstLine.prefix(60))
    }
}

/// A local-EVENT trigger (Phase 6, AGENTS.md) — the reactive counterpart to
/// `AutomationSchedule`. Flat struct (not an enum) so Codable stays synthesized and
/// old automations.json files (no `trigger` key) keep decoding. `kind` selects which
/// fields matter: fileAppears | appLaunches | wifiConnects | windowMatches |
/// calendarSoon | screenLocks (the v2 triggers batch).
struct AutomationTrigger: Codable {
    var kind: String          // one of the kinds above
    var folder: String?       // fileAppears: the watched folder (~-paths allowed)
    var ext: String?          // fileAppears: extension filter, e.g. "pdf" (nil = any file)
    var app: String?          // appLaunches: app name or bundle id, e.g. "zoom.us"
    var ssid: String?         // wifiConnects: network name (nil = any Wi-Fi join)
    var window: String?       // windowMatches: text the frontmost window's TITLE contains
    var minutesBefore: Int?   // calendarSoon: lead time in minutes (default 10)
    var state: String?        // screenLocks: "lock" (default) | "unlock"

    var describe: String {
        switch kind {
        case "fileAppears":
            let what = ext.map { ".\($0.trimmingCharacters(in: .init(charactersIn: "."))) file" } ?? "file"
            return "when a \(what) appears in \(folder ?? "?")"
        case "appLaunches":
            return "when \(app ?? "?") opens"
        case "wifiConnects":
            return ssid.map { "when Wi-Fi joins “\($0)”" } ?? "when Wi-Fi connects"
        case "windowMatches":
            return "when a window titled “\(window ?? "?")” is in front"
        case "calendarSoon":
            return "\(minutesBefore ?? 10) min before a calendar event"
        case "screenLocks":
            return state == "unlock" ? "when the screen unlocks" : "when the screen locks"
        default:
            return kind
        }
    }
}

/// A simple recurring time trigger: HH:MM, on the given weekdays (nil = every day).
struct AutomationSchedule: Codable {
    var hour: Int          // 0–23
    var minute: Int        // 0–59
    var days: [Int]?       // 1=Sun … 7=Sat; nil = daily

    func isDue(_ now: DateComponents) -> Bool {
        guard now.hour == hour, now.minute == minute else { return false }
        if let days, let wd = now.weekday { return days.contains(wd) }
        return true
    }

    var describe: String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let t = String(format: "%d:%02d %@", h12, minute, hour < 12 ? "AM" : "PM")
        if let days, days.count < 7 {
            let n = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return days.sorted().map { n[$0] }.joined(separator: "/") + " at \(t)"
        }
        return "every day at \(t)"
    }

    /// "18:30" / "8:05" → (18, 30) / (8, 5); nil for anything malformed.
    /// The edit UI's time field parses through this (kept here for self-tests).
    static func parseTime(_ s: String) -> (hour: Int, minute: Int)? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// The time as the edit field's text ("18:05").
    var timeText: String { String(format: "%d:%02d", hour, minute) }
}

/// Persists saved automations to ~/Library/Application Support/Handle/automations.json.
@MainActor
final class AutomationStore {
    static let shared = AutomationStore()
    private(set) var automations: [Automation] = []
    private let url: URL

    private init() {
        url = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
               ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Handle/automations.json")
        if let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([Automation].self, from: d) {
            automations = a
        }
    }

    func add(_ a: Automation) { automations.removeAll { $0.id == a.id }; automations.append(a); persist() }
    func remove(id: String)   { automations.removeAll { $0.id == id }; persist() }
    func replace(_ a: Automation) { if let i = automations.firstIndex(where: { $0.id == a.id }) { automations[i] = a; persist() } }

    private func persist() {
        if let d = try? JSONEncoder().encode(automations) { try? d.write(to: url) }
    }
}
