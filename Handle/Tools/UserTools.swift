import Foundation
import AppKit
import os

private let utLog = Logger(subsystem: "com.dimarussu.Handle", category: "Agent")

/// One user-defined tool, as written in a `*.json` file (CUSTOMIZING.md).
nonisolated struct UserToolDef: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var params: [String: UserToolParam]? = nil
    var runner: String                 // shell | applescript | shortcut
    var script: String                 // zsh command line | AppleScript source | Shortcut name
    var confirm: Bool? = nil           // default true: a card before every run
    var timeout: Double? = nil         // seconds; default 30, max 300
}

nonisolated struct UserToolParam: Codable, Equatable, Sendable {
    var type: String? = nil            // string (default) | number | integer | boolean
    var description: String? = nil
    var required: Bool? = nil
}

nonisolated enum UserToolError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let s) = self { return s }; return nil }
}

/// USER TOOLS — the customization surface. Every `*.json` in
/// `~/Library/Application Support/Handle/tools/` is one tool the model sees exactly
/// like a built-in (native definition, card before it runs unless the file says
/// `"confirm": false`). A call runs the file's script with the arguments as
/// `$HANDLE_<NAME>` environment variables and `{{name}}` placeholders. The folder
/// is re-read when a file changes (stamps checked at most every 2 s) — save the
/// file and the tool is there; no restart.
@MainActor
enum UserTools {
    static let folderURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Handle/tools", isDirectory: true)

    struct LoadError: Identifiable, Equatable {
        var id: String { file }
        let file: String
        let reason: String
    }

    static let runners: Set<String> = ["shell", "applescript", "shortcut"]

    /// Names the loader refuses: the built-ins and the loop's own tools.
    static var reservedNames: Set<String> {
        Set(ToolRegistry.builtinTools.map(\.name) + AgentTools.tools.map(\.name)
            + ["run_recipe", "recapture_screen", "point_at", "web_search"])
    }

    private struct Cache { var checked: Date; var stamp: String; var defs: [UserToolDef]; var errors: [LoadError] }
    private static var cache: Cache?

    static var definitions: [UserToolDef] { load().defs }
    static var errors: [LoadError] { load().errors }
    static var tools: [Tool] { definitions.map(tool(for:)) }
    static func definition(named name: String) -> UserToolDef? { definitions.first { $0.name == name } }
    static func invalidate() { cache = nil }

    static func tool(for d: UserToolDef) -> Tool {
        Tool(name: d.name, description: d.description, inputSchema: schema(for: d),
             confirmation: (d.confirm ?? true) ? .confirm : .auto)
    }

    /// JSON Schema for the provider: an object, the declared params, `required` from the file.
    nonisolated static func schema(for d: UserToolDef) -> ToolSchema {
        var props: [String: Any] = [:]
        var required: [String] = []
        for (k, p) in (d.params ?? [:]).sorted(by: { $0.key < $1.key }) {
            let t = p.type ?? "string"
            var prop: [String: Any] = ["type": ["string", "number", "integer", "boolean"].contains(t) ? t : "string"]
            if let desc = p.description, !desc.isEmpty { prop["description"] = desc }
            props[k] = prop
            if p.required ?? false { required.append(k) }
        }
        return ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }

    /// Why a definition can't be loaded, or nil when it can.
    nonisolated static func validate(_ d: UserToolDef, reserved: Set<String>, taken: Set<String>) -> String? {
        let name = d.name
        let nameOK = name.count >= 2 && name.count <= 64
            && (name.first.map { $0.isASCII && $0.isLetter && $0.isLowercase } ?? false)
            && name.allSatisfy { ($0.isASCII && (($0.isLetter && $0.isLowercase) || $0.isNumber)) || $0 == "_" }
        if !nameOK { return "name must be 2–64 characters of a–z, 0–9 and _, starting with a letter" }
        if name.hasPrefix("mcp__") { return "names starting with mcp__ belong to connectors" }
        if reserved.contains(name) { return "“\(name)” is a built-in tool" }
        if taken.contains(name) { return "another file already defines “\(name)”" }
        if d.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "description is empty" }
        if !runners.contains(d.runner) { return "runner must be shell, applescript or shortcut" }
        if d.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "script is empty" }
        for k in (d.params ?? [:]).keys
        where k.isEmpty || !k.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }) {
            return "param “\(k)”: letters, digits and _ only"
        }
        return nil
    }

    private static func load() -> (defs: [UserToolDef], errors: [LoadError]) {
        let now = Date()
        if let c = cache, now.timeIntervalSince(c.checked) < 2 { return (c.defs, c.errors) }
        let stamp = folderStamp()
        if var c = cache, c.stamp == stamp { c.checked = now; cache = c; return (c.defs, c.errors) }
        var defs: [UserToolDef] = []
        var errors: [LoadError] = []
        let reserved = reservedNames
        let files = ((try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            do {
                let d = try JSONDecoder().decode(UserToolDef.self, from: Data(contentsOf: f))
                if let why = validate(d, reserved: reserved, taken: Set(defs.map(\.name))) {
                    errors.append(LoadError(file: f.lastPathComponent, reason: why))
                } else {
                    defs.append(d)
                }
            } catch let e as DecodingError {
                errors.append(LoadError(file: f.lastPathComponent, reason: describe(e)))
            } catch {
                errors.append(LoadError(file: f.lastPathComponent, reason: error.localizedDescription))
            }
        }
        if cache?.stamp != stamp {
            utLog.info("user tools: \(defs.count) loaded, \(errors.count) skipped")
        }
        cache = Cache(checked: now, stamp: stamp, defs: defs, errors: errors)
        return (defs, errors)
    }

    /// Names + modification times of the folder's json files — changes when anything does.
    private static func folderStamp() -> String {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey]) else { return "" }
        return urls.filter { $0.pathExtension.lowercased() == "json" }.map { u -> String in
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(u.lastPathComponent):\(m)"
        }.sorted().joined(separator: "|")
    }

    nonisolated private static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, _): return "missing \"\(k.stringValue)\""
        case .typeMismatch(_, let ctx): return "wrong type at \(ctx.codingPath.map(\.stringValue).joined(separator: ".").ifEmpty("top level"))"
        case .valueNotFound(_, let ctx): return "null at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted: return "not valid JSON"
        @unknown default: return "unreadable"
        }
    }

    // MARK: Running

    /// Run a call. Arguments reach the script as `$HANDLE_<NAME>` (upper-cased) and as
    /// `{{name}}` placeholders (quoted for AppleScript). A non-zero exit throws.
    static func run(_ d: UserToolDef, args: [String: Any]) async throws -> String {
        let values = stringValues(args, for: d)
        let timeout = min(max(d.timeout ?? 30, 1), 300)
        switch d.runner {
        case "shell":
            var env = ProcessInfo.processInfo.environment
            for (k, v) in values { env["HANDLE_" + envName(k)] = v }
            let script = substitute(d.script, values, quoting: .none)
            let r = try await runProcess(exe: "/bin/zsh", args: ["-c", script], env: env, timeout: timeout)
            if r.exitCode != 0 { throw UserToolError.failed("Exit \(r.exitCode): \(r.output)") }
            return r.output
        case "applescript":
            let out = try AppleScriptTool.shared.runScript(substitute(d.script, values, quoting: .appleScript))
            return out.isEmpty ? "Done." : out
        case "shortcut":
            var a = ["run", d.script]
            var tmp: URL?
            if !values.isEmpty {
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("handle-tool-\(UUID().uuidString).json")
                try JSONSerialization.data(withJSONObject: args).write(to: u)
                tmp = u
                a += ["-i", u.path]
            }
            defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }
            let r = try await runProcess(exe: "/usr/bin/shortcuts", args: a, env: ProcessInfo.processInfo.environment, timeout: timeout)
            if r.exitCode != 0 { throw UserToolError.failed(r.output) }
            return r.output == "(no output)" ? "Ran “\(d.script)”." : r.output
        default:
            throw UserToolError.failed("Unknown runner “\(d.runner)”.")
        }
    }

    nonisolated enum Quoting { case none, appleScript }

    /// `{{name}}` → value for every declared param (missing ones become empty).
    nonisolated static func substitute(_ template: String, _ values: [String: String], quoting: Quoting) -> String {
        var s = template
        for (k, v) in values {
            let q = quoting == .appleScript
                ? v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                : v
            s = s.replacingOccurrences(of: "{{\(k)}}", with: q)
        }
        return s
    }

    /// "file_name" → "FILE_NAME"; anything not a letter or digit becomes "_".
    nonisolated static func envName(_ k: String) -> String {
        String(k.uppercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "_" })
    }

    /// Every declared param as a string ("" when the model left it out).
    nonisolated static func stringValues(_ args: [String: Any], for d: UserToolDef) -> [String: String] {
        var out: [String: String] = [:]
        for k in (d.params ?? [:]).keys {
            guard let v = args[k] else { out[k] = ""; continue }
            if let n = v as? NSNumber {
                out[k] = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
            } else if v is NSNull {
                out[k] = ""
            } else {
                out[k] = String(describing: v)
            }
        }
        return out
    }

    nonisolated private static func runProcess(exe: String, args: [String], env: [String: String], timeout: Double) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { throw UserToolError.failed("Couldn't start: \(error.localizedDescription)") }
        let outHandle = outPipe.fileHandleForReading, errHandle = errPipe.fileHandleForReading
        let outTask = Task.detached { outHandle.readDataToEndOfFile() }
        let errTask = Task.detached { errHandle.readDataToEndOfFile() }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        var timedOut = false
        if process.isRunning { process.terminate(); timedOut = true }
        let outData = await outTask.value, errData = await errTask.value
        if timedOut {
            let partial = String(data: outData + errData, encoding: .utf8) ?? ""
            return ("(timed out after \(Int(timeout))s)" + (partial.isEmpty ? "" : "\n" + partial.prefix(10_000)), -1)
        }
        var combined = String(data: outData, encoding: .utf8) ?? ""
        if let s = String(data: errData, encoding: .utf8), !s.isEmpty {
            if !combined.isEmpty { combined += "\n--- stderr ---\n" }
            combined += s
        }
        combined = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.count > 50_000 { combined = String(combined.prefix(50_000)) + "\n\n[truncated]" }
        return (combined.isEmpty ? "(no output)" : combined, process.terminationStatus)
    }

    // MARK: Examples

    /// Two starter files (existing ones are left alone). Returns what was written.
    @discardableResult
    static func writeExamples() throws -> [URL] {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let examples: [(String, String)] = [
            ("battery_status.json", """
            {
              "name": "battery_status",
              "description": "The Mac's battery level, charging state and time remaining (read-only).",
              "runner": "shell",
              "script": "pmset -g batt",
              "confirm": false
            }

            """),
            ("show_notification.json", """
            {
              "name": "show_notification",
              "description": "Show a macOS notification banner with a short message.",
              "params": {
                "message": { "type": "string", "description": "The text to show", "required": true }
              },
              "runner": "applescript",
              "script": "display notification \\"{{message}}\\" with title \\"Handle\\"",
              "confirm": true
            }

            """),
        ]
        var written: [URL] = []
        for (file, body) in examples {
            let u = folderURL.appendingPathComponent(file)
            guard !FileManager.default.fileExists(atPath: u.path) else { continue }
            try body.write(to: u, atomically: true, encoding: .utf8)
            written.append(u)
        }
        invalidate()
        return written
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
