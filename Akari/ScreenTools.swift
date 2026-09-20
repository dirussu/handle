import AppKit
import CoreGraphics

/// Hands and eyes inside the loop (ASSISTANT.md phase 2): see what's on screen
/// as numbered elements, click one, type, press keys, scroll, switch apps, read
/// the screen's text. `click_element` is executed by the loop itself (highlight →
/// confirm card → press, the validated pointing path); the rest run here.
@MainActor
enum ScreenTools {
    static var tools: [Tool] { [listWindowsTool, focusAppTool, readWindowTool, clickElementTool, typeTextTool, pressKeyTool, scrollTool, readScreenTextTool] }

    static let listWindowsTool = Tool(
        name: "list_windows",
        description: "List the open windows on this Mac (app, title, display) — including ones behind others. Use it to know what's open before switching or reading.",
        inputSchema: ["type": "object", "properties": [:]],
        confirmation: .auto)

    static let focusAppTool = Tool(
        name: "focus_app",
        description: "Bring an app to the front (launching it if needed). Give the app's name as it appears in the Dock or Applications (\"Safari\", \"Mail\", \"Visual Studio Code\").",
        inputSchema: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
        confirmation: .auto)

    static let readWindowTool = Tool(
        name: "read_window",
        description: "Read the front window of an app as a numbered list of on-screen elements — buttons, fields, text, links — with their labels and values. The numbers are what click_element takes. With no app, reads the frontmost window. Call it again after anything changes; the numbers change too.",
        inputSchema: ["type": "object", "properties": ["app": ["type": "string", "description": "App name (default: the frontmost app)"], "limit": ["type": "integer", "description": "Max elements (default 60)"]]],
        confirmation: .auto)

    static let clickElementTool = Tool(
        name: "click_element",
        description: "Click one element by its index from the latest read_window (or the on-screen element list). Akari highlights it and asks the user before pressing.",
        inputSchema: ["type": "object", "properties": ["index": ["type": "integer"]], "required": ["index"]],
        confirmation: .confirm)   // the loop shows the click card itself (highlight + press)

    static let typeTextTool = Tool(
        name: "type_text",
        description: "Type text into whatever has keyboard focus right now (click a field first if needed). Newlines press Return. Long text is pasted, and the clipboard is restored afterwards.",
        inputSchema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]],
        confirmation: .confirm)

    static let pressKeyTool = Tool(
        name: "press_key",
        description: "Press one key, optionally with modifiers — e.g. return, tab, escape, space, delete, up/down/left/right, home/end, pageup/pagedown, f1–f12, a–z, 0–9. Modifiers: command, shift, option, control.",
        inputSchema: ["type": "object",
                      "properties": ["key": ["type": "string"], "modifiers": ["type": "array", "items": ["type": "string", "enum": ["command", "shift", "option", "control"]]]],
                      "required": ["key"]],
        confirmation: .confirm)

    static let scrollTool = Tool(
        name: "scroll",
        description: "Scroll the content under the mouse pointer. direction up|down|left|right; amount in lines (default 5).",
        inputSchema: ["type": "object", "properties": ["direction": ["type": "string", "enum": ["up", "down", "left", "right"]], "amount": ["type": "integer"]], "required": ["direction"]],
        confirmation: .auto)

    static let readScreenTextTool = Tool(
        name: "read_screen_text",
        description: "Read all text visible on the screen right now (OCR, on this Mac) — cheaper than a screenshot when you only need the words. Excluded apps are never read.",
        inputSchema: ["type": "object", "properties": [:]],
        confirmation: .auto)

    // MARK: - Implementations

    static func listWindows() async -> String {
        let windows = await ScreenCapture.windowManifest(maxCount: 30)
        guard !windows.isEmpty else { return "(no windows open)" }
        return windows.map { w in
            let display = w.displayIndex.map { " (display \($0))" } ?? ""
            return "\(w.appName) — \(w.title.isEmpty ? "(untitled)" : w.title)\(display)"
        }.joined(separator: "\n")
    }

    /// Running app by name (case-insensitive, exact or contains) or bundle id.
    static func runningApp(named name: String) -> NSRunningApplication? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !n.isEmpty else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { $0.localizedName?.lowercased() == n || $0.bundleIdentifier?.lowercased() == n }
            ?? apps.first { $0.localizedName?.lowercased().contains(n) == true }
    }

    static func focusApp(named name: String) async throws -> String {
        if let app = runningApp(named: name) {
            app.activate()
            return "\(app.localizedName ?? name) is now in front."
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let candidates = [URL(fileURLWithPath: "/Applications/\(trimmed).app"),
                          URL(fileURLWithPath: "/System/Applications/\(trimmed).app"),
                          URL(fileURLWithPath: "/System/Applications/Utilities/\(trimmed).app")]
            + (NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed).map { [$0] } ?? [])
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ScreenToolError.appNotFound(trimmed)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        return "Launched \(trimmed); it should be in front in a moment."
    }

    /// Enumerate the app's front window; returns the numbered list AND the
    /// elements, so the caller can store them for click_element.
    static func readWindow(app: String?, limit: Int, conversation: Conversation) -> String {
        let target: NSRunningApplication? = app.flatMap(runningApp(named:)) ?? NSWorkspace.shared.frontmostApplication
        if let app, target == nil { return "No running app named \"\(app)\". Call list_windows to see what's open, or focus_app to launch it." }
        if SeeSettings.isExcluded(target?.bundleIdentifier) {
            return "Not read: \(target?.localizedName ?? "that app") is on the user's excluded-apps list."
        }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let rect = CGRect(origin: .zero, size: screen.frame.size)
        let elements = AccessibilityProbe.elements(in: rect, of: target?.bundleIdentifier, limit: max(10, min(limit, 150)))
        conversation.axElements = elements
        conversation.capturedAppName = target?.localizedName
        conversation.capturedBundleID = target?.bundleIdentifier
        guard !elements.isEmpty else {
            return "No readable elements in \(target?.localizedName ?? "the front app")'s window (it may have no accessibility tree, or no focused window). Try recapture_screen to look at it instead."
        }
        return "\(target?.localizedName ?? "Front app") — \(elements.count) element(s):\n" + format(elements)
    }

    /// "[3] Button \"Send\"" / "[4] TextField \"Search\" = \"foo\"" — pure.
    static func format(_ elements: [AXElement]) -> String {
        elements.enumerated().map { i, e in
            let role = e.role.hasPrefix("AX") ? String(e.role.dropFirst(2)) : e.role
            var line = "[\(i)] \(role) \"\(e.label)\""
            if let v = e.value, !v.isEmpty, v != e.label { line += " = \"\(v.prefix(80))\"" }
            return line
        }.joined(separator: "\n")
    }

    // MARK: Keyboard

    /// US-layout virtual key codes for the names the model may use. Pure.
    static func keyCode(for name: String) -> CGKeyCode? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        let named: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "forwarddelete": 117, "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119,
            "pageup": 116, "pagedown": 121, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
        ]
        if let c = named[n] { return c }
        let letters = "asdfhgzxcv bqweryt123465=97-80]ou[ip"   // key codes 0…35 in order (space = unused slot 10)
        if n.count == 1, let ch = n.first, let i = letters.firstIndex(of: ch), ch != " " {
            return CGKeyCode(letters.distance(from: letters.startIndex, to: i))
        }
        let rest: [String: CGKeyCode] = ["l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
        return rest[n]
    }

    static func flags(for modifiers: [String]) -> CGEventFlags {
        var f = CGEventFlags()
        for m in modifiers.map({ $0.lowercased() }) {
            switch m {
            case "command", "cmd", "⌘": f.insert(.maskCommand)
            case "shift", "⇧": f.insert(.maskShift)
            case "option", "alt", "⌥": f.insert(.maskAlternate)
            case "control", "ctrl", "⌃": f.insert(.maskControl)
            default: break
            }
        }
        return f
    }

    static func pressKey(_ name: String, modifiers: [String]) throws -> String {
        guard let code = keyCode(for: name) else { throw ScreenToolError.unknownKey(name) }
        let src = CGEventSource(stateID: .hidSystemState)
        let flags = flags(for: modifiers)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else {
            throw ScreenToolError.eventFailed
        }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); usleep(15_000); up.post(tap: .cghidEventTap)
        let mods = modifiers.isEmpty ? "" : modifiers.joined(separator: "+") + "+"
        return "Pressed \(mods)\(name)."
    }

    /// Short text is typed as key events (no clipboard); long text is pasted via
    /// ⌘V with the clipboard restored. Newlines become Return presses.
    static func typeText(_ text: String) async throws -> String {
        guard !text.isEmpty else { return "(nothing to type)" }
        if text.count > 300 {
            let prior = ClipboardScratch.setString(text)
            _ = try pressKey("v", modifiers: ["command"])
            try await Task.sleep(for: .milliseconds(400))
            ClipboardScratch.restore(prior)
            return "Pasted \(text.count) characters into the focused field (clipboard restored)."
        }
        let src = CGEventSource(stateID: .hidSystemState)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            for chunk in chunks(of: String(line), size: 20) {
                var utf16 = Array(chunk.utf16)
                guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { throw ScreenToolError.eventFailed }
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(12))
            }
            if i < lines.count - 1 { _ = try pressKey("return", modifiers: []) ; try await Task.sleep(for: .milliseconds(30)) }
        }
        return "Typed \(text.count) characters."
    }

    static func chunks(of s: String, size: Int) -> [String] {
        var out: [String] = []; var cur = ""
        for ch in s { cur.append(ch); if cur.count >= size { out.append(cur); cur = "" } }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func scroll(direction: String, amount: Int) throws -> String {
        let n = Int32(max(1, min(amount, 50)))
        let (dy, dx): (Int32, Int32)
        switch direction.lowercased() {
        case "up": (dy, dx) = (n, 0)
        case "down": (dy, dx) = (-n, 0)
        case "left": (dy, dx) = (0, n)
        case "right": (dy, dx) = (0, -n)
        default: throw ScreenToolError.badDirection(direction)
        }
        guard let ev = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            throw ScreenToolError.eventFailed
        }
        ev.post(tap: .cghidEventTap)
        return "Scrolled \(direction) by \(n) lines under the pointer."
    }

    static func readScreenText() async throws -> String {
        let front = NSWorkspace.shared.frontmostApplication
        if SeeSettings.isExcluded(front?.bundleIdentifier) {
            return "Not read: \(front?.localizedName ?? "the front app") is on the user's excluded-apps list."
        }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let image = try await ScreenCapture.captureRegion(CGRect(origin: .zero, size: screen.frame.size), on: screen)
        let text = try await OCR.recognize(in: image)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(no readable text on screen)" }
        return trimmed.count > 8000 ? String(trimmed.prefix(8000)) + "\n…(truncated)" : trimmed
    }
}

enum ScreenToolError: LocalizedError {
    case appNotFound(String), unknownKey(String), badDirection(String), eventFailed
    var errorDescription: String? {
        switch self {
        case .appNotFound(let n): return "No app named \"\(n)\" is installed."
        case .unknownKey(let k): return "Unknown key \"\(k)\"."
        case .badDirection(let d): return "Unknown scroll direction \"\(d)\"."
        case .eventFailed: return "Couldn't synthesize the input event."
        }
    }
}

struct FocusAppInput: Decodable { let name: String }
struct ReadWindowInput: Decodable { let app: String?; let limit: Int? }
struct TypeTextInput: Decodable { let text: String }
struct PressKeyInput: Decodable { let key: String; let modifiers: [String]? }
struct ScrollInput: Decodable { let direction: String; let amount: Int? }
