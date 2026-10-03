import AppKit
import OSLog

/// Reads a tool call out of plain text, for model servers that cannot return one natively.
enum ToolCallParser {
    /// Pull a tool-call JSON object out of the reply, however the model wrapped it
    /// — `<tool_call>` tags, a ```json fence, or bare JSON. Local models are
    /// inconsistent about the wrapper, so we ignore it entirely and scan for the
    /// JSON object itself.
    static func parse(_ text: String) -> (name: String, args: [String: Any])? {
        for json in ToolCallParser.jsonObjectCandidates(in: text) {
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["name"] as? String else { continue }
            return (name, (obj["arguments"] as? [String: Any]) ?? [:])
        }
        return parseFunctionCall(text)   // a small model sometimes emits name(k="v", …) instead of JSON
    }

    /// Fallback for the Python-function-call syntax a small local model sometimes emits
    /// instead of JSON — `create_reminder(title="Call mom", priority="high")`.
    /// Anchored on KNOWN tool names (earliest occurrence wins) so free prose can't
    /// false-match; the paren scan is string-aware (quoted commas/parens are safe).
    private static func parseFunctionCall(_ text: String) -> (name: String, args: [String: Any])? {
        // Require the response to BE the call (start with a known name( after any
        // opening code fence) — so prose that merely mentions "open_url(...)" can't misfire.
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```"), let nl = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let known = ToolRegistry.names + ["point_at", "recapture_screen"]
        guard let name = known.first(where: { t.hasPrefix($0 + "(") }) else { return nil }
        let start = t.index(t.startIndex, offsetBy: name.count + 1)
        var depth = 1, inString = false, escaped = false, quote: Character = "\""
        var body = ""
        for c in t[start...] {
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == quote { inString = false }
                body.append(c); continue
            }
            if c == "\"" || c == "'" { inString = true; quote = c; body.append(c); continue }
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1; if depth == 0 { break } }
            body.append(c)
        }
        return (name, parseKeyValueArgs(body))
    }

    /// `key="value", key2=123, key3=true` → dict, respecting quoted commas and
    /// coercing bare numbers/bools. Quoted values stay strings (unescaped).
    private static func parseKeyValueArgs(_ s: String) -> [String: Any] {
        var parts: [String] = [], cur = ""
        var inString = false, escaped = false, quote: Character = "\""
        for c in s {
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == quote { inString = false }
                cur.append(c); continue
            }
            if c == "\"" || c == "'" { inString = true; quote = c; cur.append(c); continue }
            if c == "," { parts.append(cur); cur = ""; continue }
            cur.append(c)
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur) }

        var args: [String: Any] = [:]
        for part in parts {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces)
            let val = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !val.isEmpty else { continue }
            if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")), val.count >= 2 {
                args[key] = String(val.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
            } else if val == "true" || val == "false" { args[key] = (val == "true") }
            else if let i = Int(val) { args[key] = i }
            else if let d = Double(val) { args[key] = d }
            else { args[key] = val }
        }
        return args
    }

    /// Every balanced `{…}` substring, longest first — so the outermost object
    /// (the one carrying name+arguments) is tried before any nested object. Good
    /// enough for tool calls; doesn't special-case braces inside string values.
    static func jsonObjectCandidates(in text: String) -> [String] {
        let chars = Array(text)
        var results: [String] = []
        var stack: [Int] = []
        var inString = false, escaped = false
        for (i, c) in chars.enumerated() {
            if inString {                       // ignore braces/quotes inside a JSON string value
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": stack.append(i)
            case "}": if let start = stack.popLast() { results.append(String(chars[start...i])) }
            default: break
            }
        }
        return results.sorted { $0.count > $1.count }
    }

    /// Coerce a tool-call argument to Int. Local models are inconsistent about JSON
    /// types — it sometimes emits a number as a string (`"index": "16"`), which a
    /// plain `as? NSNumber` would silently drop. Accept number, string, or a
    /// stray-whitespace string.
    static func intArg(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
