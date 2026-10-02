import Foundation
import EventKit

enum ReminderToolError: LocalizedError {
    case permissionDenied
    case invalidDate(String)
    case noDefaultList
    case storeError(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:    return "Handle doesn't have permission to access Reminders."
        case .invalidDate(let s):  return "Couldn't parse due date: \(s)."
        case .noDefaultList:       return "No default Reminders list set on this Mac."
        case .storeError(let s):   return "Reminders error: \(s)."
        }
    }
}

struct CreateReminderInput: Decodable {
    let title: String
    let due_iso: String?
    let notes: String?
    let priority: Int?

    enum CodingKeys: String, CodingKey { case title, due_iso, notes, priority }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        due_iso = try c.decodeIfPresent(String.self, forKey: .due_iso)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        // Lenient: the 7B may send an int, a numeric string, or a word (high/medium/low).
        if let i = try? c.decode(Int.self, forKey: .priority) {
            priority = i
        } else if let s = try? c.decode(String.self, forKey: .priority) {
            switch s.lowercased() {
            case "high":                 priority = 1
            case "medium", "med", "normal": priority = 5
            case "low":                  priority = 9
            default:                     priority = Int(s)
            }
        } else {
            priority = nil
        }
    }
}

struct ListRemindersInput: Decodable {
    let state: String?  // "incomplete" | "complete" | "all"
}

@MainActor
final class ReminderTools {
    static let shared = ReminderTools()
    private let store = EKEventStore()

    private init() {}

    // MARK: - Tool registry

    static var tools: [Tool] {
        [createReminderTool, listRemindersTool]
    }

    static let createReminderTool = Tool(
        name: "create_reminder",
        description: """
        Create a reminder/task in the user's default Reminders list. The user is shown the \
        reminder and confirms before it is saved. Use this when the user asks you to make \
        a to-do, save something as a task, or remind them about something later.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Reminder title — concise and actionable (e.g. 'Reply to Alice', 'Buy milk')."
                ],
                "due_iso": [
                    "type": "string",
                    "description": "Optional due date/time in ISO 8601 with timezone offset. Omit for an undated reminder."
                ],
                "notes": [
                    "type": "string",
                    "description": "Optional notes/description."
                ],
                "priority": [
                    "type": "integer",
                    "description": "Optional priority. 0=none, 1-4=high, 5=medium, 6-9=low. Default 0."
                ],
            ],
            "required": ["title"]
        ],
        confirmation: .confirm
    )

    static let listRemindersTool = Tool(
        name: "list_reminders",
        description: """
        List the user's reminders. Returns titles, due dates, completion status, and notes. \
        Use this to answer "what's on my to-do list?" or to find a specific reminder.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "state": [
                    "type": "string",
                    "enum": ["incomplete", "complete", "all"],
                    "description": "Filter. Default: incomplete."
                ],
            ]
        ],
        confirmation: .auto
    )

    // MARK: - Permission

    func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        print("[Reminders] authorizationStatus: \(Self.name(of: status))")
        switch status {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            print("[Reminders] not determined — calling requestFullAccessToReminders()")
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToReminders()
            } else {
                granted = try await store.requestAccess(to: .reminder)
            }
            print("[Reminders] request returned granted=\(granted) — new status: \(Self.name(of: EKEventStore.authorizationStatus(for: .reminder)))")
            if !granted { throw ReminderToolError.permissionDenied }
        case .denied, .restricted:
            throw ReminderToolError.permissionDenied
        case .writeOnly:
            // writeOnly applies to events, not reminders — treat as denied.
            throw ReminderToolError.permissionDenied
        @unknown default:
            throw ReminderToolError.permissionDenied
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

    func decodeCreateReminder(from json: String) throws -> CreateReminderInput {
        guard let data = json.data(using: .utf8) else {
            throw ReminderToolError.storeError("Tool input wasn't valid UTF-8.")
        }
        return try JSONDecoder().decode(CreateReminderInput.self, from: data)
    }

    func decodeListReminders(from json: String) throws -> ListRemindersInput {
        guard let data = json.data(using: .utf8) else {
            throw ReminderToolError.storeError("Tool input wasn't valid UTF-8.")
        }
        return try JSONDecoder().decode(ListRemindersInput.self, from: data)
    }

    func createReminder(from input: CreateReminderInput) throws -> EKReminder {
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw ReminderToolError.noDefaultList
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = input.title
        reminder.notes = input.notes
        if let p = input.priority { reminder.priority = p }
        if let dueISO = input.due_iso, !dueISO.isEmpty {
            guard let date = Self.parseDate(dueISO) else {
                throw ReminderToolError.invalidDate(dueISO)
            }
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .timeZone],
                from: date
            )
            // Add a single absolute alarm so Reminders fires a notification.
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
        reminder.calendar = calendar
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ReminderToolError.storeError(error.localizedDescription)
        }
        return reminder
    }

    func listReminders(from input: ListRemindersInput) async throws -> [EKReminder] {
        let mode = (input.state ?? "incomplete").lowercased()
        let predicate: NSPredicate
        switch mode {
        case "complete":
            predicate = store.predicateForCompletedReminders(
                withCompletionDateStarting: nil, ending: nil, calendars: nil
            )
        case "all":
            predicate = store.predicateForReminders(in: nil)
        default:
            predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: nil
            )
        }
        // EKEventStore's fetch is callback-based; bridge to async.
        return await withCheckedContinuation { (cont: CheckedContinuation<[EKReminder], Never>) in
            store.fetchReminders(matching: predicate) { reminders in
                cont.resume(returning: reminders ?? [])
            }
        }
    }

    // MARK: - Helpers

    private static func parseDate(_ s: String) -> Date? {
        CalendarTools.parseDate(s)   // reuse the lenient shared parser (accepts the 7B's zone-less local times)
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func summarize(reminders: [EKReminder]) -> String {
        if reminders.isEmpty { return "No reminders." }
        return reminders.map { r in
            let check = r.isCompleted ? "[x]" : "[ ]"
            var line = "\(check) \(r.title ?? "(untitled)")"
            if let due = r.dueDateComponents?.date {
                line += " — due \(format(due))"
            }
            return line
        }.joined(separator: "\n")
    }
}
