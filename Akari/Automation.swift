import Foundation

/// A saved, optionally-scheduled automation: a recipe + its filled params, approved
/// ONCE at save time (standing consent) so a SCHEDULED run needs no confirm card
/// (the user isn't there). Every run is still written to the audit log. See AGENTS.md.
struct Automation: Codable, Identifiable {
    var id: String
    var name: String
    var recipeId: String
    var paramsJSON: String            // the filled params, as JSON
    var schedule: AutomationSchedule? // nil = no time trigger
    var trigger: AutomationTrigger?   // nil = no event trigger (see TriggerEngine)
    var enabled: Bool = true
    var lastRunKey: String = ""       // "yyyy-MM-dd-HH-mm" — dedupe so a minute fires once
}

/// A local-EVENT trigger (Phase 6, AGENTS.md) — the reactive counterpart to
/// `AutomationSchedule`. Flat struct (not an enum) so Codable stays synthesized and
/// old automations.json files (no `trigger` key) keep decoding. `kind` selects which
/// fields matter: fileAppears | appLaunches | wifiConnects.
struct AutomationTrigger: Codable {
    var kind: String       // "fileAppears" | "appLaunches" | "wifiConnects"
    var folder: String?    // fileAppears: the watched folder (~-paths allowed)
    var ext: String?       // fileAppears: extension filter, e.g. "pdf" (nil = any file)
    var app: String?       // appLaunches: app name or bundle id, e.g. "zoom.us"
    var ssid: String?      // wifiConnects: network name (nil = any Wi-Fi join)

    var describe: String {
        switch kind {
        case "fileAppears":
            let what = ext.map { ".\($0.trimmingCharacters(in: .init(charactersIn: "."))) file" } ?? "file"
            return "when a \(what) appears in \(folder ?? "?")"
        case "appLaunches":
            return "when \(app ?? "?") opens"
        case "wifiConnects":
            return ssid.map { "when Wi-Fi joins “\($0)”" } ?? "when Wi-Fi connects"
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

/// Persists saved automations to ~/Library/Application Support/Akari/automations.json.
@MainActor
final class AutomationStore {
    static let shared = AutomationStore()
    private(set) var automations: [Automation] = []
    private let url: URL

    private init() {
        url = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
               ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Akari/automations.json")
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
