import Foundation

enum ShortcutsToolError: LocalizedError {
    case decodeFailed(String)
    case cliMissing
    case ioFailed(String)

    var errorDescription: String? {
        switch self {
        case .decodeFailed(let s): return "Tool input invalid: \(s)"
        case .cliMissing:          return "The Shortcuts command-line tool (/usr/bin/shortcuts) isn't available on this Mac."
        case .ioFailed(let s):     return s
        }
    }
}

struct RunShortcutInput: Decodable {
    let name: String
}

/// Reach into Shortcuts.app via the documented `shortcuts` CLI (AUTOMATIONS.md Phase 0).
/// We TRIGGER shortcuts by name; we never author `.shortcut` files (undocumented
/// format — PRODUCT.md keeps creation out of scope).
@MainActor
final class ShortcutsTools {
    static let shared = ShortcutsTools()
    private init() {}

    private nonisolated static let cliPath = "/usr/bin/shortcuts"
    /// A shortcut that shows UI or asks for input can stall the CLI — cap the wait.
    private nonisolated static let timeoutSeconds: TimeInterval = 60

    static var tools: [Tool] { [listShortcutsTool, runShortcutTool] }

    static let listShortcutsTool = Tool(
        name: "list_shortcuts",
        description: """
        List the names of every Shortcut installed in the user's Shortcuts.app, one per line. \
        Read-only. Call this before run_shortcut when you aren't certain of the exact name.
        """,
        inputSchema: [
            "type": "object",
            "properties": [:],
            "required": []
        ],
        confirmation: .auto
    )

    static let runShortcutTool = Tool(
        name: "run_shortcut",
        description: """
        Run an installed Shortcut by its EXACT name (as shown by list_shortcuts). The user \
        confirms before it runs. A shortcut can do anything the user built it to do, so only \
        run one the user asked for. If the name might not match exactly, call list_shortcuts first.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "Exact name of the shortcut to run, e.g. \"Morning Routine\"."
                ]
            ],
            "required": ["name"]
        ],
        confirmation: .confirm
    )

    func decodeRun(_ json: String) throws -> RunShortcutInput {
        guard let data = json.data(using: .utf8) else {
            throw ShortcutsToolError.decodeFailed("not UTF-8")
        }
        do { return try JSONDecoder().decode(RunShortcutInput.self, from: data) }
        catch { throw ShortcutsToolError.decodeFailed(error.localizedDescription) }
    }

    /// Installed shortcut names, one per `shortcuts list` line.
    func listNames() async throws -> [String] {
        let r = try await runCLI(arguments: ["list"])
        guard r.exitCode == 0 else { throw ShortcutsToolError.ioFailed(r.output) }
        return r.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Run a shortcut by name. On failure the thrown message includes the installed
    /// names so the model can self-correct instead of retrying a bad guess.
    func run(name: String) async throws -> String {
        let r = try await runCLI(arguments: ["run", name])
        if r.exitCode == 0 {
            return r.output == "(no output)" ? "Ran “\(name)”." : "Ran “\(name)”.\n\n\(r.output)"
        }
        var message = "Running “\(name)” failed: \(r.output)"
        if let names = try? await listNames(), !names.isEmpty {
            message += "\n\nInstalled shortcuts:\n" + names.prefix(40).joined(separator: "\n")
        }
        throw ShortcutsToolError.ioFailed(message)
    }

    /// Invoke the CLI directly (argument array, no shell quoting) with a timeout,
    /// mirroring ShellTool.run's wait-and-cap pattern.
    nonisolated private func runCLI(arguments: [String]) async throws -> (output: String, exitCode: Int32) {
        guard FileManager.default.isExecutableFile(atPath: Self.cliPath) else {
            throw ShortcutsToolError.cliMissing
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.cliPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw ShortcutsToolError.ioFailed("Couldn't start shortcuts CLI: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(Self.timeoutSeconds)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            process.terminate()
            return ("(timed out after \(Int(Self.timeoutSeconds))s — the shortcut may be waiting for input on screen)", -1)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        let maxBytes = 50_000
        var combined = ""
        if let s = String(data: outData, encoding: .utf8), !s.isEmpty { combined += s }
        if let s = String(data: errData, encoding: .utf8), !s.isEmpty {
            if !combined.isEmpty { combined += "\n--- stderr ---\n" }
            combined += s
        }
        combined = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.count > maxBytes {
            combined = String(combined.prefix(maxBytes)) + "\n\n[truncated, output was \(combined.count) chars]"
        }
        if combined.isEmpty { combined = "(no output)" }
        return (combined, process.terminationStatus)
    }
}
