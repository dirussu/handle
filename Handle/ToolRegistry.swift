import Foundation
import EventKit

/// Aggregates the (previously orphaned) per-app ACTION tool registries and looks
/// them up for the local-model agent loop. The loop offers a GATED subset per
/// turn and dispatches returned calls by name through here.
///
/// Deliberately EXCLUDES the visual tools `point_at` and `highlight`: those use
/// the model's pixel-coordinate schema, which is the validated dead-end (the 7B
/// can't localize). `point_at` is dispatched separately via the index-select path
/// (`dispatchPointAtIfPresent`) against the live AX candidate list; `highlight`
/// must move to AX-select before it's wired. So this registry is action tools only.
@MainActor
enum ToolRegistry {
    /// Every dispatchable action tool: the built-ins plus the user's own
    /// (`UserTools`, one JSON file each — see CUSTOMIZING.md).
    static var all: [Tool] { builtinTools + UserTools.tools }

    /// The tools Handle ships with. (Built with incremental appends rather than
    /// one big `+` chain, which Swift's type-checker chokes on.)
    static var builtinTools: [Tool] {
        var t: [Tool] = []
        t += FileTools.tools
        t += CalendarTools.tools
        t += ReminderTools.tools
        t += EmailTools.tools
        t += MessageTools.tools
        t += AppleScriptTool.tools
        t += ShortcutsTools.tools
        t += ShellTool.tools
        t += ScreenTools.tools
        t += WebTools.tools
        return t
    }

    static var names: [String] { all.map(\.name) }

    static func tool(named name: String) -> Tool? { all.first { $0.name == name } }

    /// Compact, token-cheap prompt rendering — ONE line per tool, args derived from
    /// the schema (not the full JSON Schema, which would bloat the 7B's context
    /// alongside the candidate list). Required args first, optional in [brackets]:
    ///   - create_calendar_event(title, start_iso, end_iso, [location]) — add an event…
    static func promptSpec(for tools: [Tool]) -> String {
        tools.map { t in
            let propsDict = (t.inputSchema["properties"] as? [String: Any]) ?? [:]
            let props = Array(propsDict.keys)
            let required = (t.inputSchema["required"] as? [String]) ?? []
            let optional = props.filter { !required.contains($0) }.sorted()
            let args = (required + optional.map { "[\($0)]" }).joined(separator: ", ")
            let desc = t.description.split(separator: "\n").first.map(String.init) ?? t.description
            return "- \(t.name)(\(args)) — \(desc.prefix(90))"
        }.joined(separator: "\n")
    }

    /// Dispatch a parsed tool call to its handler and return a text result to feed
    /// back to the model. The args dict is re-serialized to JSON for the existing
    /// `decode` handlers. Increment: read-only `read_calendar_events` is wired;
    /// `.confirm` tools are handled by the loop's confirm gate (next increment), not
    /// here, so any unwired name returns a clean error the model can recover from.
    static func execute(name: String, args: [String: Any], in conversation: Conversation) async -> ToolResult {
        let argsJSON = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        do {
            switch name {
            case "read_calendar_events":
                let input = try CalendarTools.shared.decodeReadEvents(from: argsJSON)
                try await CalendarTools.shared.ensureAccess()
                let events = try CalendarTools.shared.readEvents(from: input)
                return ToolResult(content: CalendarTools.summarize(events: events),
                                  isError: false, displaySummary: "\(events.count) event(s)")
            case "create_calendar_event":   // .confirm — the loop has already gotten the user's approval
                let input = try CalendarTools.shared.decodeCreateEvent(from: argsJSON)
                try await CalendarTools.shared.ensureAccess()
                let event = try CalendarTools.shared.createEvent(from: input)
                return ToolResult(content: "Created “\(event.title ?? input.title)” on \(CalendarTools.format(event.startDate)).",
                                  isError: false, displaySummary: "Event created")
            case "run_applescript":         // .confirm — the user has seen the script and approved it
                let input = try AppleScriptTool.shared.decode(argsJSON)
                let output = try AppleScriptTool.shared.runScript(input.script)
                let purpose = input.purpose?.isEmpty == false ? input.purpose! : "Done."
                return ToolResult(content: output.isEmpty ? purpose : "\(purpose)\n\n\(output)",
                                  isError: false, displaySummary: input.purpose ?? "Script ran")
            case "list_reminders":
                let input = try ReminderTools.shared.decodeListReminders(from: argsJSON)
                try await ReminderTools.shared.ensureAccess()
                let reminders = try await ReminderTools.shared.listReminders(from: input)
                return ToolResult(content: ReminderTools.summarize(reminders: reminders),
                                  isError: false, displaySummary: "\(reminders.count) reminder(s)")
            case "create_reminder":         // .confirm
                let input = try ReminderTools.shared.decodeCreateReminder(from: argsJSON)
                try await ReminderTools.shared.ensureAccess()
                let reminder = try ReminderTools.shared.createReminder(from: input)
                let due = reminder.dueDateComponents?.date.map { " (due \(ReminderTools.format($0)))" } ?? ""
                return ToolResult(content: "Added reminder “\(reminder.title ?? input.title)”\(due).",
                                  isError: false, displaySummary: "Reminder added")
            case "create_folder":
                let input = try FileTools.shared.decode(CreateFolderInput.self, from: argsJSON)
                let path = try FileTools.shared.createFolder(input: input)
                return ToolResult(content: "Created folder \(path.path).", isError: false, displaySummary: "Folder created")
            case "fetch_url":
                let input = try FileTools.shared.decode(FetchURLInput.self, from: argsJSON)
                return ToolResult(content: try await WebTools.fetch(input.url), isError: false, displaySummary: "Fetched \(URL(string: input.url)?.host ?? input.url)")
            case "list_windows":
                return ToolResult(content: await ScreenTools.listWindows(), isError: false, displaySummary: "Listed windows")
            case "focus_app":
                let input = try FileTools.shared.decode(FocusAppInput.self, from: argsJSON)
                return ToolResult(content: try await ScreenTools.focusApp(named: input.name), isError: false, displaySummary: "Focused \(input.name)")
            case "read_window":
                let input = try FileTools.shared.decode(ReadWindowInput.self, from: argsJSON)
                let text = ScreenTools.readWindow(app: input.app, limit: input.limit ?? 60, conversation: conversation)
                return ToolResult(content: text, isError: false, displaySummary: "Read \(conversation.axElements.count) element(s)")
            case "click_element":
                return ToolResult(content: "click_element is executed by the agent loop.", isError: true, displaySummary: nil)
            case "type_text":
                let input = try FileTools.shared.decode(TypeTextInput.self, from: argsJSON)
                return ToolResult(content: try await ScreenTools.typeText(input.text), isError: false, displaySummary: "Typed \(input.text.count) chars")
            case "press_key":
                let input = try FileTools.shared.decode(PressKeyInput.self, from: argsJSON)
                return ToolResult(content: try await ScreenTools.pressKey(input.key, modifiers: input.modifiers ?? []), isError: false, displaySummary: "Pressed \(input.key)")
            case "scroll":
                let input = try FileTools.shared.decode(ScrollInput.self, from: argsJSON)
                return ToolResult(content: try ScreenTools.scroll(direction: input.direction, amount: input.amount ?? 5), isError: false, displaySummary: "Scrolled \(input.direction)")
            case "read_screen_text":
                return ToolResult(content: try await ScreenTools.readScreenText(), isError: false, displaySummary: "Read screen text")
            case "list_files":
                let names = try FileTools.shared.listFiles(input: FileTools.shared.decode(ListFilesInput.self, from: argsJSON))
                return ToolResult(content: names.isEmpty ? "(empty folder)" : names.joined(separator: "\n"),
                                  isError: false, displaySummary: "\(names.count) item(s)")
            case "read_file":
                let content = try FileTools.shared.readFile(input: FileTools.shared.decode(ReadFileInput.self, from: argsJSON))
                return ToolResult(content: content, isError: false, displaySummary: "Read file")
            case "write_file":              // .auto — scoped to allowed folders; new files (overwrite throws unless set)
                let url = try FileTools.shared.writeFile(input: FileTools.shared.decode(WriteFileInput.self, from: argsJSON))
                return ToolResult(content: "Wrote \(url.path).", isError: false, displaySummary: "Saved \(url.lastPathComponent)")
            case "open_file":
                let url = try FileTools.shared.openFile(input: FileTools.shared.decode(OpenFileInput.self, from: argsJSON))
                return ToolResult(content: "Opened \(url.lastPathComponent).", isError: false, displaySummary: "Opened")
            case "open_url":
                let url = try FileTools.shared.openURL(input: FileTools.shared.decode(OpenURLInput.self, from: argsJSON))
                return ToolResult(content: "Opened \(url.absoluteString).", isError: false, displaySummary: "Opened URL")
            case "delete_file":             // .confirm
                let url = try FileTools.shared.deleteFile(input: FileTools.shared.decode(DeleteFileInput.self, from: argsJSON))
                return ToolResult(content: "Moved \(url.lastPathComponent) to Trash.", isError: false, displaySummary: "Trashed")
            case "move_file":               // .confirm
                let moved = try FileTools.shared.moveFile(input: FileTools.shared.decode(MoveFileInput.self, from: argsJSON))
                return ToolResult(content: "Moved to \(moved.dst.path).", isError: false, displaySummary: "Moved")
            case "draft_email_reply":       // .confirm — opens a compose window (mailto:); NEVER sends
                let input = try EmailTools.shared.decodeDraftReply(from: argsJSON)
                try EmailTools.shared.openMailDraft(to: input.to, subject: input.subject, body: input.body)
                return ToolResult(content: "Opened an email draft\(input.to.map { " to \($0)" } ?? "") in your mail app — review and send it yourself.",
                                  isError: false, displaySummary: "Email draft ready")
            case "list_shortcuts":
                let names = try await ShortcutsTools.shared.listNames()
                return ToolResult(content: names.isEmpty ? "(no shortcuts installed)" : names.joined(separator: "\n"),
                                  isError: false, displaySummary: "\(names.count) shortcut(s)")
            case "run_shortcut":            // .confirm — the user has seen the name and approved it
                let input = try ShortcutsTools.shared.decodeRun(argsJSON)
                let output = try await ShortcutsTools.shared.run(name: input.name)
                return ToolResult(content: output, isError: false, displaySummary: "Ran “\(input.name)”")
            case "run_shell":               // .confirm — user saw the exact command line
                guard ShellTool.shared.isEnabled else { throw ShellToolError.disabled }
                let input = try ShellTool.shared.decode(argsJSON)
                let cwd: URL
                if let dir = input.working_directory, !dir.isEmpty {
                    cwd = WorkspaceManager.shared.resolve(dir)
                    guard WorkspaceManager.shared.isAllowed(cwd) else { throw ShellToolError.cwdNotAllowed(cwd.path) }
                } else {
                    cwd = try WorkspaceManager.shared.ensureWorkspaceExists()
                }
                let r = try await ShellTool.shared.run(command: input.command, cwd: cwd)
                return ToolResult(content: r.output,
                                  isError: r.exitCode != 0,
                                  displaySummary: r.exitCode == 0 ? "Command ran" : "Exit \(r.exitCode)")
            case "draft_imessage":          // .confirm — opens Messages pre-filled (sms:); NEVER sends
                let input = try MessageTools.shared.decodeDraft(from: argsJSON)
                try MessageTools.shared.openMessageDraft(to: input.to, body: input.body)
                return ToolResult(content: "Opened a message draft\(input.to.map { " to \($0)" } ?? "") in Messages — review and send it yourself.",
                                  isError: false, displaySummary: "Message draft ready")
            case _ where UserTools.definition(named: name) != nil:   // a user tool (CUSTOMIZING.md)
                let out = try await UserTools.run(UserTools.definition(named: name)!, args: args)
                return ToolResult(content: out, isError: false, displaySummary: "Ran \(name)")
            default:
                return ToolResult(content: "The tool '\(name)' isn't wired yet — answer the user directly.", isError: true)
            }
        } catch let e as DecodingError {
            // A DecodingError's localizedDescription is the useless "The data
            // couldn't be read because it is missing." — the 4B can't self-correct
            // from that (observed live: identical broken run_applescript calls
            // repeated across days). Name the exact broken argument + the spec.
            return ToolResult(content: describeDecodingError(e, tool: name), isError: true)
        } catch {
            return ToolResult(content: error.localizedDescription, isError: true)
        }
    }

    /// Actionable decode-failure text: which argument is missing/mistyped, then
    /// the tool's one-line argument spec so the retry has the full shape.
    private static func describeDecodingError(_ e: DecodingError, tool name: String) -> String {
        let what: String
        switch e {
        case .keyNotFound(let key, _):
            what = "the required argument '\(key.stringValue)' is missing"
        case .valueNotFound(let type, let ctx):
            what = "the argument '\(ctx.codingPath.map(\.stringValue).joined(separator: "."))' is null (expected \(type))"
        case .typeMismatch(let type, let ctx):
            what = "the argument '\(ctx.codingPath.map(\.stringValue).joined(separator: "."))' has the wrong type (expected \(type))"
        case .dataCorrupted(let ctx):
            what = ctx.debugDescription.isEmpty ? "the arguments are not valid JSON" : ctx.debugDescription
        @unknown default:
            what = "the arguments could not be parsed"
        }
        let spec = tool(named: name).map { promptSpec(for: [$0]) } ?? "- \(name)(…)"
        return "Bad call: \(what). Call \(name) again with ALL required arguments filled in:\n\(spec)"
    }
}

/// Outcome of running an action tool — `content` is fed back to the model (folded
/// into the next user prompt as text); `displaySummary` is the UI label.
struct ToolResult {
    let content: String
    let isError: Bool
    var displaySummary: String? = nil
    /// A screenshot the tool took — goes to the model inside the tool result.
    var attachedImage: CGImage? = nil
}
