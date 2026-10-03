import AppKit
import SwiftUI
import MarkdownUI

struct ToolUseCard: View {
    let toolUse: ToolUseBlock
    let result: ToolResultBlock?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HandleSpacing.m) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.handleBody.weight(.medium))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.handleCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            statusBadge
        }
        .padding(.horizontal, HandleSpacing.m)
        .padding(.vertical, HandleSpacing.m)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
        }
        .animation(HandleMotion.swap, value: result?.isError)
    }

    private var iconName: String {
        switch toolUse.name {
        case "create_calendar_event": return "calendar.badge.plus"
        case "read_calendar_events":  return "calendar"
        case "create_reminder":       return "checklist"
        case "list_reminders":        return "list.bullet.rectangle"
        case "draft_email_reply":     return "envelope.badge"
        case "draft_imessage":        return "message.badge"
        case "point_at":              return "scope"
        case "write_file":            return "doc.badge.plus"
        case "read_file":             return "doc.text"
        case "list_files":            return "folder"
        case "create_folder":         return "folder.badge.plus"
        case "delete_file":           return "trash"
        case "move_file":             return "arrow.right.doc.on.clipboard"
        case "open_file":             return "arrow.up.forward.app"
        case "open_url":              return "safari"
        case "pick_file":             return "doc.viewfinder"
        case "recapture_screen":      return "arrow.triangle.2.circlepath.camera"
        case "web_search":            return "magnifyingglass.circle"
        case "run_applescript":       return "applescript"
        case "run_shell":             return "terminal"
        case "code_execution":        return "curlybraces"
        case "list_shortcuts":        return "square.grid.2x2"
        case "run_shortcut":          return "play.square"
        default:                       return "wrench.and.screwdriver"
        }
    }

    private var headline: String {
        switch toolUse.name {
        case "create_calendar_event":
            if let title = inputField("title"), !title.isEmpty {
                return "Create event: \(title)"
            }
            return "Create calendar event"
        case "read_calendar_events":
            return "Read calendar"
        case "create_reminder":
            if let title = inputField("title"), !title.isEmpty {
                return "Add reminder: \(title)"
            }
            return "Create reminder"
        case "list_reminders":
            return "List reminders"
        case "draft_email_reply":
            if let to = inputField("to"), !to.isEmpty {
                return "Draft reply to \(to)"
            }
            return "Draft email reply"
        case "draft_imessage":
            if let to = inputField("to"), !to.isEmpty {
                return "Draft message to \(to)"
            }
            return "Draft iMessage"
        case "point_at":
            if let label = inputField("label"), !label.isEmpty {
                return "Point at \"\(label)\""
            }
            return "Point at element"
        case "write_file":
            if let path = inputField("path"), !path.isEmpty {
                return "Write \(path)"
            }
            return "Write file"
        case "read_file":
            if let path = inputField("path"), !path.isEmpty {
                return "Read \(path)"
            }
            return "Read file"
        case "list_files":
            if let path = inputField("path"), !path.isEmpty {
                return "List \(path)"
            }
            return "List workspace"
        case "create_folder":
            if let path = inputField("path"), !path.isEmpty {
                return "Create folder \(path)"
            }
            return "Create folder"
        case "delete_file":
            if let path = inputField("path"), !path.isEmpty {
                return "Move \(path) to Trash"
            }
            return "Delete file"
        case "move_file":
            return "Move file"
        case "open_file":
            if let path = inputField("path"), !path.isEmpty {
                return "Open \(path)"
            }
            return "Open file"
        case "open_url":
            if let url = inputField("url"), !url.isEmpty {
                return "Open \(url)"
            }
            return "Open URL"
        case "pick_file":
            return "Pick a file…"
        case "recapture_screen":
            return "Refreshed screen view"
        case "run_applescript":
            if let purpose = inputField("purpose"), !purpose.isEmpty {
                return purpose
            }
            return "Run AppleScript"
        case "run_shell":
            if let cmd = inputField("command"), !cmd.isEmpty {
                let short = cmd.count > 50 ? String(cmd.prefix(50)) + "…" : cmd
                return "Shell: \(short)"
            }
            return "Run shell command"
        case "code_execution":
            return "Run code"
        case "list_shortcuts":
            return "List shortcuts"
        case "run_shortcut":
            if let name = inputField("name"), !name.isEmpty {
                return "Run shortcut: \(name)"
            }
            return "Run shortcut"
        default:
            return toolUse.name
        }
    }

    private var subtitle: String? {
        if let r = result, !r.isError {
            return r.displaySummary
        }
        if let r = result, r.isError {
            return r.displaySummary ?? "Error"
        }
        if !toolUse.isComplete {
            return "Preparing…"
        }
        return "Awaiting confirmation"
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let r = result {
            Image(systemName: r.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(r.isError ? .red : .green)
        } else if !toolUse.isComplete {
            ProgressView().controlSize(.mini)
        } else {
            // Pending-confirmation state: a small white dot (white-only accent).
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
        }
    }

    private func inputField(_ key: String) -> String? {
        guard let data = toolUse.inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[key] as? String
    }
}

// MARK: - Confirmation card (replaces input bar while pending)
