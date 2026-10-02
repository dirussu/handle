import AppKit
import OSLog

// Matching a request to a recipe, filling its parameters and running it.

extension AppDelegate {
    /// RECIPE MATCH — prefilter by keyword, then the 7B SELECTS one by index (the
    /// pointing trick: enumerate candidates → pick an index; -1 = none fit). No free
    /// generation, so it can't hallucinate a tool.
    func matchRecipe(goal: String) async -> Recipe? {
        let candidates = RecipeLibrary.prefilter(goal, in: RecipeStore.shared.recipes)
        guard !candidates.isEmpty else { return nil }
        let list = candidates.enumerated().map { "[\($0)] \($1.title) — \($1.description)" }.joined(separator: "\n")
        if AIConfig.nativeTools {   // the pick is a tool call; the schema parses it
            let (args, text) = await askForStructured("""
            The user wants: "\(goal)"

            Which automation best matches? Call select_automation with the index of the best match, or -1 if NONE fit.
            Match the user's INTENT — asking ABOUT something is not the same as doing it. The user's \
            specific values (names, paths, amounts) get filled in later, so an automation with input \
            fields still matches.
            \(list)
            """, tool: Self.selectSpec(name: "select_automation", what: "automation"), label: "recipe select")
            let idx = args.flatMap { Self.intArg($0["index"]) } ?? firstInt(in: text)
            agentLog.info("recipe: select over \(candidates.count) [\(candidates.map(\.id).joined(separator: ", "), privacy: .public)] → \(idx.map(String.init) ?? "none", privacy: .public)")
            guard let idx, idx >= 0, idx < candidates.count else { return nil }
            return candidates[idx]
        }
        let reply = await askModel("""
        The user wants: "\(goal)"

        Which automation best matches? Reply with ONLY the number of the best match, or -1 if NONE fit.
        Match the user's INTENT — asking ABOUT something is not the same as doing it. The user's \
        specific values (names, paths, amounts) get filled in later, so an automation with input \
        fields still matches.
        Example — "mute the sound", [0] Set system volume, [1] Play a song: reply 0
        Example — "what song is this", [0] Search and play a song, [1] Current track info: reply 1
        Example — "order a pizza", [0] Empty the Trash, [1] Open a folder: reply -1
        \(list)
        """)
        let idx = firstInt(in: reply)
        agentLog.info("recipe: select over \(candidates.count) [\(candidates.map(\.id).joined(separator: ", "), privacy: .public)] → reply \"\(reply.prefix(60), privacy: .public)\"")
        guard let idx else { return nil }
        return (idx >= 0 && idx < candidates.count) ? candidates[idx] : nil
    }

    /// RECIPE FILL — the 7B emits a JSON object of parameter values from the goal
    /// (structured output = its strength). `[:]` for a param-less recipe.
    func fillParams(recipe: Recipe, goal: String) async -> [String: Any] {
        guard !recipe.params.isEmpty else { return [:] }
        if AIConfig.nativeTools {   // the recipe's params ARE the tool schema
            let (args, text) = await askForStructured("""
            The user wants: "\(goal)"

            Call fill_parameters with the values for the "\(recipe.title)" automation, taken from the user's words. Use each value DIRECTLY — a number as a number, text as a string.
            """, tool: AIToolSpec(name: "fill_parameters", description: "The parameter values for the \(recipe.title) automation.", inputSchema: Self.schema(for: recipe.params)), label: "recipe fill")
            if let args { return args }
            for json in jsonObjectCandidates(in: text) {
                if let d = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return obj }
            }
            return [:]
        }
        let spec = recipe.params.map { "- \($0.name) (\($0.type.describe)): \($0.prompt)" }.joined(separator: "\n")
        let reply = await askModel("""
        The user wants: "\(goal)"

        Fill the parameters for the "\(recipe.title)" automation. Reply with ONLY a JSON object
        mapping each parameter name to its value. Use the value DIRECTLY — a number as a number,
        text as a string; ONLY a "list of names" param takes a JSON array:
        \(spec)
        """)
        for json in jsonObjectCandidates(in: reply) {
            if let d = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return obj
            }
        }
        return [:]
    }

    /// First integer (incl. negative) in a string.
    func firstInt(in s: String) -> Int? {
        guard let r = s.range(of: "-?\\d+", options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    /// `run_recipe` — a recipe as a loop tool: the candidates for this request are
    /// listed in the turn prefix (`recipeCandidatesLine`); the model calls with an id
    /// and params; the same card/AppleScript/chip/audit path as before runs it.
    static let runRecipeTool = Tool(
        name: "run_recipe",
        description: "Run one of the ready-made automations listed for this request, by its id, with its parameters filled from the user's words. The user confirms before it runs. Prefer a recipe over run_applescript when one fits.",
        inputSchema: ["type": "object",
                      "properties": ["id": ["type": "string"], "params": ["type": "object", "description": "Parameter values by name, as listed"]],
                      "required": ["id"]],
        confirmation: .confirm)

    /// The keyword-matched recipes for this request, as a prefix block (stable across the turn's steps). Pure.
    static func recipeCandidatesLine(for text: String, recipes: [Recipe]? = nil) -> String {
        let cands = RecipeLibrary.prefilter(text, in: recipes ?? RecipeStore.shared.recipes).prefix(8)
        guard !cands.isEmpty else { return "" }
        let lines = cands.map { r -> String in
            let params = r.params.map { "\($0.name) (\($0.type.describe))" }.joined(separator: ", ")
            return "- \(r.id) — \(r.title): \(r.description)" + (params.isEmpty ? "" : " [params: \(params)]")
        }
        return "Ready-made automations for this request (run_recipe id — what it does):\n" + lines.joined(separator: "\n")
    }

    /// Run a recipe by id from inside the loop: card → AppleScript → chip → audit. No messages committed.
    func performRecipe(id: String, params: [String: Any], conversation: Conversation, autoApprove: Bool = false, auditLabel: String? = nil) async -> (content: String, isError: Bool, declined: Bool) {
        guard let recipe = RecipeStore.shared.recipes.first(where: { $0.id == id }) else {
            return ("No recipe with id \"\(id)\". Use one of the ids listed for this request, or another tool.", true, false)
        }
        let script = recipe.resolve(recipe.body, with: params)
        let title = recipe.resolve(recipe.confirmTemplate, with: params)
        let argsJSON = (try? JSONSerialization.data(withJSONObject: ["recipe": recipe.id, "params": params])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let approved = autoApprove ? true : await awaitConfirmation(in: conversation, title: "\(title)?", rows: [("Recipe", recipe.title), ("Script", script)],
                                                                  label: "recipe:\(recipe.id)", destructive: recipe.id == "empty-trash")
        if Task.isCancelled { return ("", true, false) }
        guard approved else {
            Task { await AuditLog.shared.record(tool: "recipe:\(recipe.id)", argsJSON: argsJSON, outcome: "declined", summary: "declined by user", confirmed: true) }
            return ("The user declined this action.", false, true)
        }
        do {
            let output = try AppleScriptTool.shared.runScript(script)
            Task { await AuditLog.shared.record(tool: auditLabel.map { "\($0) › recipe:\(recipe.id)" } ?? "recipe:\(recipe.id)", argsJSON: argsJSON, outcome: "ok", summary: recipe.title, confirmed: !autoApprove) }
            let chipJSON = (try? JSONSerialization.data(withJSONObject: ["purpose": recipe.title])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            conversation.addToolChip(name: "run_applescript", inputJSON: chipJSON, content: output.isEmpty ? recipe.title : output, isError: false, displaySummary: recipe.title)
            return (output.isEmpty ? "Done — \(recipe.title.lowercased())." : output, false, false)
        } catch {
            Task { await AuditLog.shared.record(tool: "recipe:\(recipe.id)", argsJSON: argsJSON, outcome: "error", summary: error.localizedDescription, confirmed: true) }
            return ("That didn't work — \(error.localizedDescription)", true, false)
        }
    }
}
