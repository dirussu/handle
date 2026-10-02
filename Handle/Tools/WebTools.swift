import Foundation

/// The web, inside the loop. `fetch_url` works with any
/// provider: a plain GET, HTML stripped to readable text, capped. Search is the
/// provider's server-side tool (Anthropic), behind a Settings toggle — see
/// `WebSettings` and the loop.
@MainActor
enum WebTools {
    static var tools: [Tool] { [fetchURLTool] }

    static let fetchURLTool = Tool(
        name: "fetch_url",
        description: "Fetch a web page (or a text/JSON file) by URL and return its readable text — HTML stripped, long pages truncated. Use it for a page the user named or a link you found.",
        inputSchema: ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]],
        confirmation: .auto)

    static let maxBytes = 3_000_000
    static let maxChars = 12_000

    static func fetch(_ raw: String) async throws -> String {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { throw WebToolError.badURL(raw) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Handle/1.0 (Mac; +https://handle.app)", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,text/plain,application/json;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebToolError.http(http.statusCode)
        }
        let body = data.count > maxBytes ? data.prefix(maxBytes) : data
        let mime = (response.mimeType ?? "").lowercased()
        let text: String
        if mime.contains("html") || mime.isEmpty {
            let raw = String(decoding: body, as: UTF8.self)
            text = await Task.detached(priority: .userInitiated) { textFromHTML(raw) }.value   // regex passes off the main actor
        } else if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") {
            text = String(decoding: body, as: UTF8.self)
        } else {
            return "(\(mime.isEmpty ? "binary" : mime), \(data.count) bytes — not text)"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(no readable text at \(url.absoluteString))" }
        return trimmed.count > maxChars ? String(trimmed.prefix(maxChars)) + "\n…(truncated)" : trimmed
    }

    /// HTML → readable text: title first, scripts/styles dropped, block tags become
    /// newlines, entities decoded, whitespace collapsed. Pure (self-tested).
    nonisolated static func textFromHTML(_ html: String) -> String {
        func replace(_ pattern: String, with repl: String, in s: String) -> String {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return s }
            return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: repl)
        }
        var title = ""
        if let m = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let r = Range(m.range(at: 1), in: html) {
            title = decodeEntities(String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var s = html
        s = replace("<(script|style|noscript|svg|head)[^>]*>.*?</\\1>", with: " ", in: s)
        s = replace("<!--.*?-->", with: " ", in: s)
        s = replace("<br\\s*/?>|</(p|div|li|tr|h[1-6]|section|article|header|footer|blockquote|pre|table)>", with: "\n", in: s)
        s = replace("<[^>]+>", with: " ", in: s)
        s = decodeEntities(s)
        s = replace("[ \\t\\r\\f]+", with: " ", in: s)
        s = replace(" *\\n *", with: "\n", in: s)
        s = replace("\\n{3,}", with: "\n\n", in: s)
        let body = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? body : "Title: \(title)\n\n\(body)"
    }

    nonisolated private static let titleRegex = try! NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    nonisolated private static let entities: [(String, String)] = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&#160;", " ")]
    nonisolated static func decodeEntities(_ s: String) -> String {
        entities.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

enum WebToolError: LocalizedError {
    case badURL(String), http(Int)
    var errorDescription: String? {
        switch self {
        case .badURL(let u): return "Not a fetchable http(s) URL: \(u)"
        case .http(let c): return "The server answered HTTP \(c)."
        }
    }
}

struct FetchURLInput: Decodable { let url: String }

/// Web search is the provider's server-side tool; off until the user turns it on.
nonisolated enum WebSettings {
    static let searchKey = "handle.web.searchEnabled"
    static var searchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: searchKey) }
        set { UserDefaults.standard.set(newValue, forKey: searchKey) }
    }
    /// The Anthropic server tool, as a spec the adapter recognises by `__server_type`.
    static let anthropicSearchSpec = AIToolSpec(name: "web_search", description: "Search the web (server-side).",
                                                inputSchema: ["max_uses": 5], serverType: "web_search_20260209")
}
