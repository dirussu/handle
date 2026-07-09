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
/// Configured servers live in `~/Library/Application Support/Akari/mcp.json`
/// in the claude-desktop format, so users can paste server entries straight
/// from any MCP server's README:
///
///     { "mcpServers": { "weather": { "command": "npx", "args": ["-y", "…"],
///                                    "env": { "API_KEY": "…" } } } }
///
/// Lifecycle: connect on demand (`connect(configuredName:)`), crash detected
/// via `terminationHandler` (handle dropped → next use reconnects; a crash
/// LOOP — 3 exits in 60s — refuses instead of respawning forever), all
/// children terminated on app quit (`disconnectAll`).

/// One entry under `mcpServers` — plain Foundation types so callers (AkariApp,
/// Settings UI) can hold these without `import MCP`.
struct MCPServerConfig: Equatable {
    let name: String
    let command: String
    let args: [String]
    let env: [String: String]
}

enum MCPConfig {
    /// ~/Library/Application Support/Akari/mcp.json
    static var url: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
         ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Akari/mcp.json")
    }

    /// Parse claude-desktop-format JSON. Tolerant: malformed JSON → [],
    /// an entry without a `command` is skipped, `args`/`env` default empty.
    /// Sorted by name so callers see a stable order.
    static func parse(_ data: Data) -> [MCPServerConfig] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["mcpServers"] as? [String: Any] else { return [] }
        return entries.compactMap { name, raw -> MCPServerConfig? in
            guard let entry = raw as? [String: Any],
                  let command = entry["command"] as? String, !command.isEmpty else {
                mcpLog.error("mcp config: entry \(name, privacy: .public) has no command — skipped")
                return nil
            }
            return MCPServerConfig(name: name,
                                   command: command,
                                   args: entry["args"] as? [String] ?? [],
                                   env: entry["env"] as? [String: String] ?? [:])
        }.sorted { $0.name < $1.name }
    }

    /// The configured servers on disk (no file → none configured).
    static func load() -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }

    static func server(named name: String) -> MCPServerConfig? {
        load().first { $0.name == name }
    }

    /// README configs say `npx`/`uvx`/`python3`, not absolute paths — `Process`
    /// needs one, so bare names launch through `/usr/bin/env` (PATH lookup).
    static func resolveInvocation(command: String, args: [String]) -> (executable: String, args: [String]) {
        command.hasPrefix("/") ? (command, args) : ("/usr/bin/env", [command] + args)
    }

    /// 3+ exits inside 60s = a crash loop; stop respawning and surface it.
    static func isCrashLooping(_ crashes: [Date], now: Date) -> Bool {
        crashes.filter { now.timeIntervalSince($0) < 60 }.count >= 3
    }
}

/// The NL→arguments fill step for MCP tools (increment ② — the recipe
/// pipeline's `fillParams`, generalized to real JSON-Schema). Pure functions:
/// condense a tool's inputSchema into the flat param spec the 4B can fill
/// from, and build the fill prompt — WORKED EXAMPLES + when-X-do-Y framing
/// (the house rule: abstract instructions fail on the 4B; proven twice).
/// Prompt quality is eval-gated: `__mcpfilleval__` runs real dumped schemas
/// (tools/mcp_schemas.json) against the live model.
/// One tool from a connected MCP server, in plain Foundation types — safe to
/// hold anywhere (no `import MCP` needed; schema is the raw JSON-Schema dict).
struct MCPToolInfo {
    let server: String
    let name: String
    let description: String
    let schema: [String: Any]
}

/// Routing MCP tools into the recipe pipeline: the keyword prefilter that
/// decides which tools the model gets to pick from (select-by-index — the
/// model NEVER sees the full tool list, per the load-bearing rule).
enum MCPRoute {
    static let stopwords: Set<String> = ["the", "a", "an", "in", "on", "at", "to", "of", "my",
                                         "me", "and", "or", "for", "with", "it", "is", "this",
                                         "that", "please", "can", "you", "use", "using"]

    static func tokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    /// Score = 3 per goal-token hit on the tool's NAME tokens + 1 per hit in
    /// its description. Unlike recipes there are no curated keywords, so name
    /// hits carry the weight; the ≥3 bar (a name hit, or several description
    /// hits) keeps weak matches from hijacking the turn — below the bar the
    /// goal falls through to the freeform loop.
    static func prefilter(_ goal: String, tools: [MCPToolInfo], limit: Int = 5) -> [MCPToolInfo] {
        let goalTokens = Set(tokens(goal))
        guard !goalTokens.isEmpty else { return [] }
        let scored = tools.compactMap { tool -> (MCPToolInfo, Int)? in
            let nameTokens = Set(tokens(tool.name))
            let descTokens = Set(tokens(tool.description))
            let score = goalTokens.intersection(nameTokens).count * 3
                      + goalTokens.intersection(descTokens).count
            return score >= 3 ? (tool, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }
}

enum MCPFill {
    /// "- path (string, required): the file path" — one line per property.
    /// Enums render as the value list (the model must pick, not invent);
    /// arrays name their element type. Long descriptions truncate at a word
    /// boundary (~140 chars) — schema prose can run to paragraphs
    /// (sequential-thinking) and would drown the 4B.
    static func condenseSchema(_ schema: [String: Any]) -> String {
        let props = schema["properties"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        return props.keys.sorted().map { name -> String in
            let p = props[name] as? [String: Any] ?? [:]
            var kind = p["type"] as? String ?? "string"
            if let values = p["enum"] as? [Any] {
                kind = "one of: " + values.map { "\($0)" }.joined(separator: " | ")
            } else if kind == "array" {
                let item = (p["items"] as? [String: Any])?["type"] as? String ?? "string"
                kind = "list of \(item)"
            }
            let flag = required.contains(name) ? ", required" : ""
            var desc = (p["description"] as? String ?? p["title"] as? String ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            if desc.count > 140 {
                desc = String(desc.prefix(140))
                if let cut = desc.range(of: " ", options: .backwards) { desc = String(desc[..<cut.lowerBound]) }
                desc += "…"
            }
            return "- \(name) (\(kind)\(flag))" + (desc.isEmpty ? "" : ": \(desc)")
        }.joined(separator: "\n")
    }

    /// The fill prompt. Two worked examples carry the rules the 4B won't take
    /// abstractly: values come from the user's words (typed correctly), and
    /// optional arguments the user didn't mention are LEFT OUT.
    static func prompt(goal: String, toolName: String, description: String, schema: [String: Any]) -> String {
        var desc = description.replacingOccurrences(of: "\n", with: " ")
        if desc.count > 200 { desc = String(desc.prefix(200)) + "…" }
        return """
        Fill in the arguments for a tool call. Reply with ONLY a JSON object mapping each \
        argument name to its value. Take values from the user's request — text as a string, \
        a number as a number, true/false as a boolean. Include every required argument. \
        When the user didn't mention an optional argument, LEAVE IT OUT.

        Example — the user wants "play Hey Jude by the Beatles", the tool play_song takes:
        - artist (string): the artist name
        - title (string, required): the song title
        Reply: {"title": "Hey Jude", "artist": "The Beatles"}

        Example — the user wants "show the 3 newest photos", the tool list_photos takes:
        - count (number): how many to show
        - folder (string): only this album
        Reply: {"count": 3}

        Now the user wants: "\(goal)"
        The tool \(toolName)\(desc.isEmpty ? "" : " — \(desc)") takes:
        \(condenseSchema(schema))
        Reply:
        """
    }
}

/// This file is the transport + lifecycle layer: config, connect, list tools,
/// call a tool, crash recovery, disconnect — proven by the `__mcptest__`
/// harness against `tools/fake_mcp_server.py`. Recipe-engine routing, Keychain
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
    private var recentCrashes: [String: [Date]] = [:]
    /// Tool list per server, keyed to the pid it was listed from — a
    /// reconnected (fresh-pid) server re-lists automatically.
    private var toolCache: [String: (pid: Int32, tools: [MCPToolInfo])] = [:]

    /// Connect to a server from mcp.json by its entry name (on-demand path —
    /// this is what the recipe pipeline and Routines will call).
    func connect(configuredName: String) async throws -> ServerHandle {
        guard let config = MCPConfig.server(named: configuredName) else {
            throw NSError(domain: "MCPService", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "No MCP server named \"\(configuredName)\" in \(MCPConfig.url.path)."])
        }
        return try await connect(name: config.name, command: config.command,
                                 args: config.args, env: config.env)
    }

    /// Spawn `command args…` and complete the MCP initialize handshake.
    /// Idempotent per `name` — an existing live handle is reused; a crashed
    /// server reconnects here (unless it's crash-looping).
    func connect(name: String, command: String, args: [String],
                 env: [String: String] = [:]) async throws -> ServerHandle {
        if let existing = servers[name] {
            if existing.process.isRunning { return existing }
            // Dead but terminationHandler not yet run — clean up here instead.
            servers.removeValue(forKey: name)
            Task { await existing.client.disconnect() }
        }
        if MCPConfig.isCrashLooping(recentCrashes[name] ?? [], now: Date()) {
            throw NSError(domain: "MCPService", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "MCP server \"\(name)\" keeps crashing — not restarting. Check its command in mcp.json."])
        }

        let proc = Process()
        let invocation = MCPConfig.resolveInvocation(command: command, args: args)
        proc.executableURL = URL(fileURLWithPath: invocation.executable)
        proc.arguments = invocation.args
        if !env.isEmpty {
            proc.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice   // server logs stay out of ours
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in self?.serverExited(name: name, process: p) }
        }
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

    /// Called from `terminationHandler` on ANY child exit. A deliberate
    /// `disconnect` removes the handle FIRST, so reaching here with the handle
    /// still registered (and pointing at this process) means a crash: drop the
    /// dead handle so the next use reconnects, and record it for loop detection.
    private func serverExited(name: String, process: Process) {
        guard let h = servers[name], h.process === process else { return }
        servers.removeValue(forKey: name)
        recentCrashes[name, default: []].append(Date())
        mcpLog.error("mcp: \(name, privacy: .public) exited unexpectedly (status \(process.terminationStatus)) — will reconnect on next use")
        Task { await h.client.disconnect() }
    }

    /// Disconnect the client and terminate the child process.
    func disconnect(name: String) async {
        guard let h = servers.removeValue(forKey: name) else { return }
        await h.client.disconnect()
        if h.process.isRunning { h.process.terminate() }
        mcpLog.info("mcp: \(name, privacy: .public) disconnected")
    }

    /// App quit: tear down every child so no orphan servers outlive Akari.
    func disconnectAll() async {
        for name in Array(servers.keys) { await disconnect(name: name) }
    }

    /// Synchronous quit path (applicationWillTerminate has no async runway):
    /// remove handles first so terminationHandler doesn't log these as crashes,
    /// then SIGTERM each child. The client objects die with the process.
    func terminateAllChildren() {
        let handles = servers.values
        servers.removeAll()
        for h in handles where h.process.isRunning {
            h.process.terminate()
            mcpLog.info("mcp: \(h.name, privacy: .public) terminated (app quit)")
        }
    }

    /// The server's tools (name / description / JSON-Schema input).
    /// (`MCP.Tool` fully qualified — Akari has its own `Tool` type.)
    func listTools(_ handle: ServerHandle) async throws -> [MCP.Tool] {
        try await handle.client.listTools().tools
    }

    /// Every tool from every CONFIGURED server, as plain-Foundation MCPToolInfo —
    /// the recipe pipeline's discovery call. Connects on demand (children stay
    /// alive for later calls); tool lists are cached per live pid. A server that
    /// fails to come up is skipped (logged), not fatal — the others still route.
    func allConfiguredTools() async -> [MCPToolInfo] {
        var all: [MCPToolInfo] = []
        for config in MCPConfig.load() {
            do {
                let handle = try await connect(configuredName: config.name)
                let pid = handle.process.processIdentifier
                if let cached = toolCache[config.name], cached.pid == pid {
                    all += cached.tools
                    continue
                }
                let tools = try await listTools(handle).map { tool in
                    MCPToolInfo(server: config.name,
                                name: tool.name,
                                description: tool.description ?? "",
                                schema: foundationObject(tool.inputSchema) as? [String: Any] ?? [:])
                }
                toolCache[config.name] = (pid, tools)
                all += tools
            } catch {
                mcpLog.error("mcp: \(config.name, privacy: .public) unavailable for discovery — \(error.localizedDescription, privacy: .public)")
            }
        }
        return all
    }

    /// Call a tool with plain-Foundation arguments (the filled JSON object) on
    /// a configured server — connects on demand if needed.
    func callConfiguredTool(server: String, name: String, arguments: [String: Any]) async throws -> String {
        let handle = try await connect(configuredName: server)
        let data = try JSONSerialization.data(withJSONObject: arguments)
        guard case .object(let args)? = try? JSONDecoder().decode(Value.self, from: data) else {
            throw NSError(domain: "MCPService", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Arguments didn't convert to MCP values."])
        }
        return try await callTool(handle, name: name, arguments: args)
    }

    /// MCP `Value` → Foundation (via its Codable JSON form) — keeps `Value`
    /// out of every file but this one.
    private func foundationObject(_ value: Value?) -> Any? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
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
