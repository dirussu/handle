import Foundation
import MCP
import Security
import System
import os.log

private let mcpLog = Logger(subsystem: "com.dimarussu.Handle", category: "Agent")

/// MCP client (v2-before-ship #1) — the integrations story, PRODUCT.md.
///
/// Spawns LOCAL MCP servers as child processes and speaks JSON-RPC over their
/// stdio via the official swift-sdk. Everything stays on this Mac: the servers
/// run locally, their tools will surface through the SAME recipe pipeline as
/// everything else (prefilter → select-by-index → fill → confirm → audit) — the
/// small model never sees an open-ended tool list.
///
/// Configured servers live in `~/Library/Application Support/Handle/mcp.json`
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

/// One entry under `mcpServers` — plain Foundation types so callers (HandleApp,
/// Settings UI) can hold these without `import MCP`.
struct MCPServerConfig: Equatable {
    let name: String
    let command: String
    let args: [String]
    let env: [String: String]
}

enum MCPConfig {
    /// ~/Library/Application Support/Handle/mcp.json
    static var url: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
         ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Handle/mcp.json")
    }

    /// Parse claude-desktop-format JSON. Tolerant: malformed JSON → [],
    /// an entry without a `command` is skipped, `args`/`env` default empty.
    /// Sorted by name so callers see a stable order.
    static func parse(_ data: Data) -> [MCPServerConfig] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["mcpServers"] as? [String: Any] else { return [] }
        return configs(fromEntries: entries)
    }

    private static func configs(fromEntries entries: [String: Any]) -> [MCPServerConfig] {
        entries.compactMap { name, raw -> MCPServerConfig? in
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

    /// What Settings' "Add a connector" paste box accepts — the shapes READMEs
    /// actually show: the whole `{"mcpServers": {...}}` file, or the bare
    /// `{"name": {"command": ...}}` fragment. Returns the VALID entries' raw
    /// dicts (unknown per-entry keys survive the round-trip to disk).
    static func parseSnippet(_ text: String) -> [String: [String: Any]] {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        let entries = (root["mcpServers"] as? [String: Any]) ?? root
        var out: [String: [String: Any]] = [:]
        for (name, raw) in entries {
            guard let entry = raw as? [String: Any],
                  let command = entry["command"] as? String, !command.isEmpty else { continue }
            out[name] = entry
        }
        return out
    }

    /// Merge snippet entries into the config file (created if missing; other
    /// top-level keys preserved; same-name entries overwritten). Returns the
    /// added names, [] when the snippet had no valid entry.
    @discardableResult
    static func addServers(fromSnippet text: String, to fileURL: URL = MCPConfig.url) -> [String] {
        let additions = parseSnippet(text)
        guard !additions.isEmpty else { return [] }
        var root = (try? Data(contentsOf: fileURL))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        var entries = root["mcpServers"] as? [String: Any] ?? [:]
        for (name, entry) in additions { entries[name] = entry }
        root["mcpServers"] = entries
        write(root, to: fileURL)
        return additions.keys.sorted()
    }

    /// Remove one entry (no-op when absent).
    static func removeServer(named name: String, from fileURL: URL = MCPConfig.url) {
        guard var root = (try? Data(contentsOf: fileURL))
            .flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }),
              var entries = root["mcpServers"] as? [String: Any] else { return }
        entries.removeValue(forKey: name)
        root["mcpServers"] = entries
        write(root, to: fileURL)
    }

    private static func write(_ root: [String: Any], to fileURL: URL) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL)
        }
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

    /// A GUI app's PATH is launchd's bare `/usr/bin:/bin:…` — npx (nvm) and
    /// uvx (homebrew) live outside it. Append the missing dirs (dedup, order
    /// kept) so `/usr/bin/env` finds what a terminal would.
    static func augmentedPATH(base: String, extras: [String]) -> String {
        var seen = Set(base.split(separator: ":").map(String.init))
        var path = base
        for dir in extras where !seen.contains(dir) {
            seen.insert(dir)
            path += ":" + dir
        }
        return path
    }

    /// The standard tool homes on a Mac: homebrew, /usr/local, ~/.local/bin,
    /// plus every installed nvm node version's bin (newest first, so the
    /// freshest npx wins if several are installed).
    static func standardExtraDirs(home: String = NSHomeDirectory()) -> [String] {
        let nvmBase = home + "/.nvm/versions/node"
        let nvmBins = ((try? FileManager.default.contentsOfDirectory(atPath: nvmBase)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvmBase + "/" + $0 + "/bin" }
        return ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"] + nvmBins
    }

    /// 3+ exits inside 60s = a crash loop; stop respawning and surface it.
    static func isCrashLooping(_ crashes: [Date], now: Date) -> Bool {
        crashes.filter { now.timeIntervalSince($0) < 60 }.count >= 3
    }
}

/// Secrets for MCP servers. mcp.json stays claude-desktop
/// compatible, but an env VALUE of the form `keychain:NAME` is resolved from
/// the macOS Keychain at spawn time — the token itself never sits in the
/// plaintext config. Items are generic passwords under one service name, so
/// they're visible (and deletable) in Keychain Access.
enum MCPKeychain {
    static let service = "com.dimarussu.Handle.mcp"
    private static let store = SecretStore(service: service)   // one Keychain helper for the app (Handle/AI/SecretStore.swift)

    /// "keychain:API_KEY" → "API_KEY"; anything else → nil. Pure (self-tested);
    /// the SecItem calls below are covered by the live `__keychaintest__`.
    static func reference(in value: String) -> String? {
        guard value.hasPrefix("keychain:") else { return nil }
        let name = String(value.dropFirst("keychain:".count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Upsert one secret.
    @discardableResult
    static func set(_ secret: String, for name: String) -> Bool { store.set(secret, for: name) }
    static func get(_ name: String) -> String? { store.get(name) }
    static func delete(_ name: String) { store.delete(name) }
    /// The names (never the secrets) of every stored token — for Settings.
    static func allNames() -> [String] { store.allNames() }

    /// Resolve every `keychain:` reference in a config env. A missing secret
    /// resolves to "" (and logs) rather than leaking the sentinel to the child.
    static func resolveEnv(_ env: [String: String]) -> [String: String] {
        env.mapValues { value in
            guard let name = reference(in: value) else { return value }
            if let secret = get(name) { return secret }
            mcpLog.error("mcp keychain: no item named \(name, privacy: .public) — env var sent empty")
            return ""
        }
    }
}

/// One tool from a connected MCP server, in plain Foundation types — safe to
/// hold anywhere (no `import MCP` needed; schema is the raw JSON-Schema dict).
struct MCPToolInfo {
    let server: String
    let name: String
    let description: String
    let schema: [String: Any]
}

/// The MCP client: reads the server config, starts servers on demand, lists their tools,
/// calls them, restarts a server that crashed, and shuts everything down on quit.
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
        var childEnv = ProcessInfo.processInfo.environment
        childEnv["PATH"] = MCPConfig.augmentedPATH(base: childEnv["PATH"] ?? "/usr/bin:/bin",
                                                   extras: MCPConfig.standardExtraDirs())
        if !env.isEmpty {
            // keychain: references resolve HERE, at spawn time — the secret
            // lives only in the child's environment, never in memory longer.
            childEnv.merge(MCPKeychain.resolveEnv(env)) { _, new in new }
        }
        proc.environment = childEnv
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
        let client = Client(name: "Handle", version: "1.0")
        try await client.connect(transport: transport)
        mcpLog.info("mcp: \(name, privacy: .public) initialized")

        let handle = ServerHandle(name: name, process: proc, client: client)
        servers[name] = handle
        return handle
    }

    /// Settings UI reads: live connection state + the cached tool list.
    func isConnected(name: String) -> Bool { servers[name]?.process.isRunning == true }
    func cachedTools(name: String) -> [MCPToolInfo]? { toolCache[name]?.tools }

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

    /// App quit: tear down every child so no orphan servers outlive Handle.
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
    /// (`MCP.Tool` fully qualified — Handle has its own `Tool` type.)
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

// MARK: - Cross-file helpers
// MemberImportVisibility (Swift 6.4 / Xcode 27): members of MCP types are only
// visible in files that `import MCP`. HandleApp.swift can't import it (MCP's
// `Notification` clashes with Foundation's in the AppDelegate callbacks), so the
// DEBUG harness reads tool names through here.
extension MCPService {
    nonisolated static func toolNames(_ tools: [MCP.Tool]) -> [String] { tools.map(\.name) }
}


/// Configured MCP tools as loop tools: one native tool per
/// server tool, named `mcp__<server>__<tool>` (sanitised to the providers' name
/// rules), every one confirmed. The map takes a sanitised name back to its info.
@MainActor
enum MCPLoopTools {
    nonisolated static func toolName(server: String, name: String) -> String {
        func clean(_ s: String) -> String {   // the providers' rule: ^[a-zA-Z0-9_-]{1,64}$
            String(s.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" || $0 == "-" ? $0 : "_" })
        }
        let full = "mcp__\(clean(server))__\(clean(name))"
        return full.count > 64 ? String(full.prefix(64)) : full
    }

    /// Providers cap the tools array (OpenAI: 128); keep the loop well under it.
    static let maxTools = 80

    static func make(_ infos: [MCPToolInfo]) -> (tools: [Tool], map: [String: MCPToolInfo]) {
        var tools: [Tool] = []; var map: [String: MCPToolInfo] = [:]
        if infos.count > maxTools { mcpLog.error("mcp loop: \(infos.count) tools configured — only the first \(Self.maxTools) are offered") }
        let infos = Array(infos.prefix(maxTools))
        for info in infos {
            var name = toolName(server: info.server, name: info.name)
            var n = 2
            while map[name] != nil { name = String(toolName(server: info.server, name: info.name).prefix(60)) + "_\(n)"; n += 1 }
            var schema = info.schema
            if schema["type"] == nil { schema["type"] = "object" }
            if schema["properties"] == nil { schema["properties"] = [String: Any]() }
            tools.append(Tool(name: name, description: "[\(info.server) connector] " + String(info.description.prefix(400)),
                              inputSchema: schema, confirmation: .confirm))
            map[name] = info
        }
        return (tools, map)
    }
}
