import AppKit
import OSLog

// One-shot questions to the model that must come back as structured data.

extension AppDelegate {
    /// One text-only model turn → the reply string.
    func askModel(_ prompt: String) async -> String {
        var out = ""
        // Select/fill one-shots: low effort — they're index picks and JSON fills,
        // not reasoning tasks.
        let label = "one-shot · " + String(prompt.split(separator: "\n").first ?? "").prefix(90)
        do {
            for try await d in CloudEngine.shared.chat(messages: [.user(prompt)], effort: .low, label: label) { out += d }
        } catch {
            agentLog.error("askModel: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        return out
    }

    /// Ask for ONE structured answer by offering a single tool: the schema does
    /// the parsing. Returns the call's arguments — nil when the model made no
    /// call (its way of saying "none fits") — plus any prose it wrote instead,
    /// for the callers' scrapers. Low effort: picks and fills, not reasoning.
    func askForStructured(_ prompt: String, tool: AIToolSpec, label: String) async -> (args: [String: Any]?, text: String) {
        var text = ""
        var args: [String: Any]? = nil
        do {
            for try await ev in CloudEngine.shared.turn(system: "", messages: [.user(prompt)], tools: [tool], effort: .low, label: label) {
                switch ev {
                case .textDelta(let t): text += t
                case .toolCall(_, let name, let json) where args == nil && name == tool.name: args = AgentToolCall.parseArgs(json)
                default: break
                }
            }
        } catch {
            agentLog.error("askForStructured(\(tool.name, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
        return (args, text)
    }

    /// `select_<what>{index}` — the select-by-index contract as a tool (-1 = none).
    static func selectSpec(name: String, what: String) -> AIToolSpec {
        AIToolSpec(name: name,
                   description: "Pick the \(what) that best matches the user's request, by its index in the numbered list — or -1 if none fits.",
                   inputSchema: ["type": "object",
                                 "properties": ["index": ["type": "integer", "description": "Index from the list, or -1 for no match."]],
                                 "required": ["index"], "additionalProperties": false])
    }

    /// A recipe's params as a JSON Schema for `fill_parameters`. Pure (self-tested).
    static func schema(for params: [RecipeParam]) -> [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        for p in params {
            var prop: [String: Any]
            switch p.type {
            case .string: prop = ["type": "string"]
            case .int: prop = ["type": "integer"]
            case .stringList: prop = ["type": "array", "items": ["type": "string"]]
            case .oneOf(let values): prop = ["type": "string", "enum": values]
            }
            prop["description"] = p.prompt
            props[p.name] = prop
            if p.default == nil { required.append(p.name) }
        }
        return ["type": "object", "properties": props, "required": required]
    }
}
