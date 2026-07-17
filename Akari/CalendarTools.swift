import Foundation
import EventKit

enum CalendarToolError: LocalizedError {
    case permissionDenied
    case invalidDate(String)
    case noDefaultCalendar
    case storeError(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:    return "Akari doesn't have permission to access your calendar."
        case .invalidDate(let s):  return "Couldn't parse date: \(s)."
        case .noDefaultCalendar:   return "No default calendar set on this Mac."
        case .storeError(let s):   return "Calendar error: \(s)."
        }
    }
}

/// Inputs decoded from Claude's tool_use JSON.
struct CreateEventInput: Decodable {
    let title: String
    let start_iso: String
    let end_iso: String
    let location: String?
    let notes: String?
}

struct ReadEventsInput: Decodable {
    let start_iso: String
    let end_iso: String
}

/// Calendar agent — owns EventKit, exposes tool definitions, executes calls.
@MainActor
final class CalendarTools {
    static let shared = CalendarTools()
    private let store = EKEventStore()
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        return f
    }()
    private static let isoParserNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f
    }()

    private init() {}

    // MARK: - Tool registry

    static var tools: [Tool] {
        [createEventTool, readEventsTool]
    }

    static let createEventTool = Tool(
        name: "create_calendar_event",
        description: """
        Create an event in the user's default calendar. The user is shown the event \
        and confirms before it is saved. Times must be ISO 8601 with timezone (e.g. \
        "2026-05-09T14:00:00+02:00"). Use the user's local timezone when one isn't \
        specified by the source content.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Concise event title (e.g. 'Lunch with Alice', 'Flight LX319')."
                ],
                "start_iso": [
                    "type": "string",
                    "description": "Start time in ISO 8601 with timezone offset."
                ],
                "end_iso": [
                    "type": "string",
                    "description": "End time in ISO 8601 with timezone offset."
                ],
                "location": [
                    "type": "string",
                    "description": "Optional event location (address, room name, URL, etc.)."
                ],
                "notes": [
                    "type": "string",
                    "description": "Optional notes to include in the event description."
                ],
            ],
            "required": ["title", "start_iso", "end_iso"]
        ],
        confirmation: .confirm
    )

    static let readEventsTool = Tool(
        name: "read_calendar_events",
        description: """
        Read events on the user's calendar within a date range. Returns titles, times, \
        and locations. Use this to answer "what's on my calendar?", "am I free at X?", \
        or to find an event the user is referring to.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "start_iso": ["type": "string", "description": "Range start, ISO 8601 with timezone."],
                "end_iso":   ["type": "string", "description": "Range end, ISO 8601 with timezone."],
            ],
            "required": ["start_iso", "end_iso"]
        ],
        confirmation: .auto
    )

    // MARK: - Permission

    func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        print("[Calendar] authorizationStatus: \(Self.name(of: status))")
        switch status {
        case .fullAccess, .authorized, .writeOnly:
            print("[Calendar] already authorized — skipping prompt")
            return
        case .notDetermined:
            print("[Calendar] not determined — calling requestFullAccessToEvents()")
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            print("[Calendar] request returned granted=\(granted) — new status: \(Self.name(of: EKEventStore.authorizationStatus(for: .event)))")
            if !granted { throw CalendarToolError.permissionDenied }
        case .denied, .restricted:
            print("[Calendar] denied/restricted — cannot prompt again from app")
            throw CalendarToolError.permissionDenied
        @unknown default:
            throw CalendarToolError.permissionDenied
        }
    }

    private static func name(of status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .fullAccess:    return "fullAccess"
        case .writeOnly:     return "writeOnly"
        @unknown default:    return "unknown(\(status.rawValue))"
        }
    }

    // MARK: - Tool execution

    func decodeCreateEvent(from json: String) throws -> CreateEventInput {
        guard let data = json.data(using: .utf8) else {
            throw CalendarToolError.storeError("Tool input wasn't valid UTF-8.")
        }
        return try JSONDecoder().decode(CreateEventInput.self, from: data)
    }

    func decodeReadEvents(from json: String) throws -> ReadEventsInput {
        guard let data = json.data(using: .utf8) else {
            throw CalendarToolError.storeError("Tool input wasn't valid UTF-8.")
        }
        return try JSONDecoder().decode(ReadEventsInput.self, from: data)
    }

    func createEvent(from input: CreateEventInput) throws -> EKEvent {
        guard let start = Self.parseDate(input.start_iso) else {
            throw CalendarToolError.invalidDate(input.start_iso)
        }
        guard let end = Self.parseDate(input.end_iso) else {
            throw CalendarToolError.invalidDate(input.end_iso)
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw CalendarToolError.noDefaultCalendar
        }
        let event = EKEvent(eventStore: store)
        event.title = input.title
        event.startDate = start
        event.endDate = end
        event.location = input.location
        event.notes = input.notes
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw CalendarToolError.storeError(error.localizedDescription)
        }
        return event
    }

    /// Now → the end of tomorrow, non-all-day, capped — the personal-context
    /// digest's fetch. Authorized-only: a background injection must never
    /// trigger a permission prompt.
    func upcomingForDigest(limit: Int = 8) -> [EKEvent] {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return [] }
        let cal = Calendar.current
        let now = Date()
        let end = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return Array(store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate != nil }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit))
    }

    /// Non-all-day events starting within the next `minutes` — the calendarSoon
    /// trigger's poll. Returns [] without access (a timer must never prompt;
    /// the permission is primed at save time while the user is present).
    func eventsStartingSoon(within minutes: Int) -> [EKEvent] {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return [] }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now,
                                                 end: now.addingTimeInterval(TimeInterval(minutes * 60)),
                                                 calendars: nil)
        return store.events(matching: predicate).filter { !$0.isAllDay }
    }

    func readEvents(from input: ReadEventsInput) throws -> [EKEvent] {
        guard let start = Self.parseDate(input.start_iso) else {
            throw CalendarToolError.invalidDate(input.start_iso)
        }
        guard let end = Self.parseDate(input.end_iso) else {
            throw CalendarToolError.invalidDate(input.end_iso)
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
    }

    // MARK: - Helpers

    /// Lenient parse for the local model's output. The 7B is inconsistent: it emits
    /// full ISO-8601 (with `Z` or an offset), OR — once told not to use `Z` — a
    /// "naked" local time with no zone and often no seconds ("2026-07-02T15:00").
    /// Strict ISO parsing rejects the naked form, which was silently failing event
    /// creation. Naked times are interpreted in the user's CURRENT timezone (which
    /// is what "3pm" means to them). Exposed so the confirm card formats it the same.
    static func parseDate(_ s: String) -> Date? {
        if let d = isoParser.date(from: s) { return d }
        if let d = isoParserNoFraction.date(from: s) { return d }
        for f in localFallbackFormatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    /// Local-timezone fallbacks for zone-less strings the ISO parsers reject.
    private static let localFallbackFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"].map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = fmt
            return f
        }
    }()

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func summarize(events: [EKEvent]) -> String {
        if events.isEmpty { return "No events." }
        return events.map { e in
            let start = format(e.startDate)
            let end = format(e.endDate)
            let loc = e.location?.isEmpty == false ? " @ \(e.location!)" : ""
            return "• \(e.title ?? "(untitled)") — \(start) → \(end)\(loc)"
        }.joined(separator: "\n")
    }
}
