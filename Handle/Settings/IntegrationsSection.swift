import SwiftUI
import AppKit

/// MCP connectors: the visible, controllable side of
/// mcp.json. Rows show each configured server with live status; Check connects
/// and lists its tools in place, Stop disconnects. Tokens store to the
/// Keychain here (referenced from mcp.json as `keychain:NAME`). The config
/// FILE stays the editing surface in v1 — entries paste straight from any
/// server's README (claude-desktop format).
struct IntegrationsSection: View {
    @State private var configs: [MCPServerConfig] = MCPConfig.load()
    @State private var status: [String: String] = [:]
    @State private var checking: Set<String> = []
    @State private var showAddForm = false
    @State private var addText = ""
    @State private var addError: String?
    @State private var showTokenForm = false
    @State private var tokenName = ""
    @State private var tokenSecret = ""
    @State private var tokenNames: [String] = MCPKeychain.allNames()

    var body: some View {
        Section {
            if configs.isEmpty {
                SettingsEmptyState(
                    icon: "puzzlepiece.extension",
                    title: "No connectors yet",
                    hint: "Add MCP servers to mcp.json — entries copy straight from any server's README.")
            } else {
                ForEach(configs, id: \.name) { c in
                    HStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name).font(.body)
                            Text(status[c.name] ?? restingStatus(c.name))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer()
                        if checking.contains(c.name) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { check(c.name) } label: {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12))
                            }
                            .buttonStyle(.borderless)
                            .handleIconHover(idle: Color(nsColor: .secondaryLabelColor))
                            .help("Connect and list its tools")
                            if MCPService.shared.isConnected(name: c.name) {
                                Button { stop(c.name) } label: {
                                    Image(systemName: "stop.circle").font(.system(size: 12))
                                }
                                .buttonStyle(.borderless)
                                .handleIconHover(idle: Color(nsColor: .secondaryLabelColor))
                                .help("Disconnect")
                            }
                            Button { remove(c.name) } label: {
                                Image(systemName: "trash").font(.system(size: 12))
                            }
                            .buttonStyle(.borderless)
                            .handleIconHover()
                            .help("Remove this connector")
                        }
                    }
                }
            }
            if showAddForm {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Paste the server's JSON from its README", text: $addText, axis: .vertical)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(3...8)
                    if let addError {
                        Text(addError).font(.caption).foregroundStyle(.red)
                    }
                    HStack(spacing: 8) {
                        Button("Add", action: add).buttonStyle(.handleSolid)
                            .disabled(addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") { showAddForm = false; addText = ""; addError = nil }
                            .buttonStyle(.borderless)
                            .handleIconHover(idle: Color(nsColor: .secondaryLabelColor))
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 8) {
                    Button("Add a connector…") { showAddForm = true }
                        .buttonStyle(.handleSolid)
                    Button("Open mcp.json", action: openConfig)
                        .buttonStyle(.handleSolid)
                    Spacer()
                }
            }
            DisclosureGroup(isExpanded: $showTokenForm) {
                if !tokenNames.isEmpty {
                    LabeledContent("Stored") {
                        Text(tokenNames.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                TextField("Name (e.g. WEATHER_API_KEY)", text: $tokenName)
                SecureField("Secret", text: $tokenSecret)
                HStack {
                    Button("Save to Keychain", action: saveToken)
                        .buttonStyle(.handleSolid)
                        .disabled(tokenName.trimmingCharacters(in: .whitespaces).isEmpty || tokenSecret.isEmpty)
                    Spacer()
                }
                Text("Reference it from mcp.json as keychain:NAME — the secret itself stays in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: {
                Text("Tokens").font(.body)
            }
        } header: {
            SettingsHeader(icon: "puzzlepiece.extension", title: "Integrations")
        } footer: {
            Text("Connectors run as local processes, stop when Handle quits, and every action they take asks first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { reload() }   // pick up hand-edits to mcp.json
    }

    /// Parse the pasted snippet, write it into mcp.json, then immediately
    /// test-connect each added server so the row shows "Running — N tools"
    /// (or the real error) without another click.
    private func add() {
        let added = MCPConfig.addServers(fromSnippet: addText)
        guard !added.isEmpty else {
            addError = "That doesn't look like a server entry — paste the JSON block from the server's README."
            return
        }
        addText = ""
        addError = nil
        showAddForm = false
        reload()
        for name in added { check(name) }
    }

    private func remove(_ name: String) {
        Task { @MainActor in
            await MCPService.shared.disconnect(name: name)
            MCPConfig.removeServer(named: name)
            reload()
        }
    }

    private func restingStatus(_ name: String) -> String {
        if MCPService.shared.isConnected(name: name) {
            let n = MCPService.shared.cachedTools(name: name)?.count
            return n.map { "Running — \($0) tool\($0 == 1 ? "" : "s")" } ?? "Running"
        }
        return "Not running — connects when needed"
    }

    private func check(_ name: String) {
        checking.insert(name)
        Task { @MainActor in
            defer { checking.remove(name) }
            do {
                let handle = try await MCPService.shared.connect(configuredName: name)
                let tools = try await MCPService.shared.listTools(handle)
                status[name] = "Running — \(tools.count) tool\(tools.count == 1 ? "" : "s")"
            } catch {
                status[name] = error.localizedDescription
            }
        }
    }

    private func stop(_ name: String) {
        Task { @MainActor in
            await MCPService.shared.disconnect(name: name)
            status[name] = restingStatus(name)
        }
    }

    private func reload() {
        configs = MCPConfig.load()
        status = [:]
        tokenNames = MCPKeychain.allNames()
    }

    private func openConfig() {
        let url = MCPConfig.url
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = """
            {
              "mcpServers": {
              }
            }
            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private func saveToken() {
        let name = tokenName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !tokenSecret.isEmpty else { return }
        MCPKeychain.set(tokenSecret, for: name)
        tokenName = ""
        tokenSecret = ""
        tokenNames = MCPKeychain.allNames()
    }
}
