import Foundation

enum ShellToolError: LocalizedError {
    case disabled
    case decodeFailed(String)
    case cwdNotAllowed(String)
    case ioFailed(String)

    var errorDescription: String? {
        switch self {
        case .disabled:           return "Shell tool is disabled. Enable it in Akari Settings → Power user."
        case .decodeFailed(let s): return "Tool input invalid: \(s)"
        case .cwdNotAllowed(let p): return "Working directory \(p) is not in an allowed folder."
        case .ioFailed(let s):    return s
        }
    }
}

struct RunShellInput: Decodable {
    let command: String
    let working_directory: String?
}

@MainActor
final class ShellTool {
    static let shared = ShellTool()
    private init() {}

    private static let enabledKey = "akari.shell.enabled"
    private static let timeoutSeconds: TimeInterval = 60

    /// Off by default. User must opt in via Settings → Power user.
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    }

    /// Tool list — empty when disabled, so Claude can't even see this tool when it's off.
    static var tools: [Tool] {
        ShellTool.shared.isEnabled ? [runShellTool] : []
    }

    static let runShellTool = Tool(
        name: "run_shell",
        description: """
        Execute a shell command on the user's Mac via /bin/zsh. The user is shown the EXACT command \
        and confirms before each run. Use for developer workflows: package managers (npm, pip, brew), \
        git, build scripts (make, cargo, npm run build), search (find, grep, du), file ops not covered \
        by the file tools.

        Constraints:
        - Working directory must be inside an allowed folder (workspace, Desktop, Documents, Downloads, \
          or user-added). Defaults to workspace.
        - 60-second wall-clock timeout per command.
        - Output (stdout + stderr) is returned to you, capped at ~50KB.

        Be cautious. Never run destructive commands (rm -rf, dd) without an explicit user request \
        for that exact action. Prefer the file tools (delete_file, move_file, etc.) over shell rm/mv \
        because they show clearer confirmation cards and use the Trash.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description": "Full shell command line. Single line. Quote arguments as needed."
                ],
                "working_directory": [
                    "type": "string",
                    "description": "Optional path to run in. Defaults to the workspace root. Must be inside an allowed folder."
                ]
            ],
            "required": ["command"]
        ],
        confirmation: .confirm
    )

    func decode(_ json: String) throws -> RunShellInput {
        guard let data = json.data(using: .utf8) else {
            throw ShellToolError.decodeFailed("not UTF-8")
        }
        return try JSONDecoder().decode(RunShellInput.self, from: data)
    }

    /// Run the command synchronously (we're on @MainActor, but Process.run() doesn't block).
    /// Returns combined stdout+stderr, capped at maxOutputBytes.
    nonisolated func run(command: String, cwd: URL) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = cwd

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw ShellToolError.ioFailed("Couldn't start process: \(error.localizedDescription)")
        }

        // Drain the pipes WHILE waiting — a pipe buffer is ~64KB, and a command
        // with more output (any build log) blocks writing to a full pipe, never
        // exits, and used to be falsely reported as a timeout with its output
        // lost. Reading concurrently keeps the pipes flowing.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let outTask = Task.detached { outHandle.readDataToEndOfFile() }
        let errTask = Task.detached { errHandle.readDataToEndOfFile() }

        // Wait with a timeout.
        let deadline = Date().addingTimeInterval(Self.timeoutSeconds)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        var timedOut = false
        if process.isRunning {
            process.terminate()
            timedOut = true
        }

        let outData = await outTask.value
        let errData = await errTask.value
        if timedOut {
            let partial = String(data: outData + errData, encoding: .utf8) ?? ""
            return ("(timed out after \(Int(Self.timeoutSeconds))s)"
                    + (partial.isEmpty ? "" : "\n--- output before timeout ---\n" + partial.prefix(10_000)), -1)
        }

        let maxBytes = 50_000
        var combined = ""
        if let s = String(data: outData, encoding: .utf8), !s.isEmpty {
            combined += s
        }
        if let s = String(data: errData, encoding: .utf8), !s.isEmpty {
            if !combined.isEmpty { combined += "\n--- stderr ---\n" }
            combined += s
        }
        if combined.count > maxBytes {
            combined = String(combined.prefix(maxBytes)) + "\n\n[truncated, output was \(combined.count) chars]"
        }
        if combined.isEmpty {
            combined = "(no output)"
        }
        return (combined, process.terminationStatus)
    }
}
