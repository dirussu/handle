import Foundation
import MCP
import System
import os.log

private let mcpLog = Logger(subsystem: "com.dimarussu.Akari", category: "Agent")

/// MCP client (v2-before-ship #1) — the integrations story, PRODUCT.md.
///
/// Spawns LOCAL MCP servers as child processes and speaks JSON-RPC over their
/// stdio via the official swift-sdk. Everything stays on this Mac: the servers
/// run locally, their tools will surface through the SAME recipe pipeline as
/// everything else (prefilter → select-by-index → fill → confirm → audit) — the
/// small model never sees an open-ended tool list.
///
/// This file is the transport + lifecycle floor (spike scope): connect, list
/// tools, call a tool, disconnect — proven by the `__mcptest__` harness against
/// `tools/fake_mcp_server.py`. Config file, recipe-engine routing, Keychain
/// tokens, and Settings UI are the next increments.
@MainActor
final class MCPService {
    static let shared = MCPService()
    private init() {}

    /// A live, initialized connection to one local MCP server.
    struct ServerHandle {
        let name: String
        let process: Process
        let client: Client
    }

    private var servers: [String: ServerHandle] = [:]

    /// Spawn `command args…` and complete the MCP initialize handshake.
    /// Idempotent per `name` — an existing live handle is reused.
    func connect(name: String, command: String, args: [String]) async throws -> ServerHandle {
        if let existing = servers[name], existing.process.isRunning { return existing }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = args
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice   // server logs stay out of ours
        try proc.run()
        mcpLog.info("mcp: spawned \(name, privacy: .public) pid=\(proc.processIdentifier)")

        // Wire the SDK's stdio transport to the CHILD's pipes: we read the
        // server's stdout, write to the server's stdin.
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        )
        let client = Client(name: "Akari", version: "1.0")
        try await client.connect(transport: transport)
        mcpLog.info("mcp: \(name, privacy: .public) initialized")

        let handle = ServerHandle(name: name, process: proc, client: client)
        servers[name] = handle
        return handle
    }

    /// Disconnect the client and terminate the child process.
    func disconnect(name: String) async {
        guard let h = servers.removeValue(forKey: name) else { return }
        await h.client.disconnect()
        if h.process.isRunning { h.process.terminate() }
        mcpLog.info("mcp: \(name, privacy: .public) disconnected")
    }

    /// The server's tools (name / description / JSON-Schema input).
    /// (`MCP.Tool` fully qualified — Akari has its own `Tool` type.)
    func listTools(_ handle: ServerHandle) async throws -> [MCP.Tool] {
        try await handle.client.listTools().tools
    }

    /// String-only convenience so callers never need MCP's `Value` type (it
    /// leaks type clashes — e.g. `Notification` — into importing files).
    func callTool(_ handle: ServerHandle, name: String, textArguments: [String: String]) async throws -> String {
        try await callTool(handle, name: name, arguments: textArguments.mapValues { Value.string($0) })
    }

    /// Call one tool and flatten its text content into a single string.
    func callTool(_ handle: ServerHandle, name: String, arguments: [String: Value]) async throws -> String {
        let result = try await handle.client.callTool(name: name, arguments: arguments)
        let text = result.content.compactMap { item -> String? in
            if case .text(let s, _, _) = item { return s }
            return nil
        }.joined(separator: "\n")
        if result.isError == true {
            throw NSError(domain: "MCPService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "Tool reported an error." : text])
        }
        return text
    }
}
