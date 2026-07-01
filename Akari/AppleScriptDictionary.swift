import Foundation

/// Fetches a scriptable app's AppleScript dictionary (via the `sdef` CLI) and condenses
/// it to the vocabulary the local 7B needs — class names with their property names+types,
/// plus command names. Injected into the retry prompt after a `run_applescript` failure so
/// the model repairs its script with the app's REAL vocabulary. Proven in the eval harness
/// to fix vocabulary errors, and scalable to ANY scriptable app (no hand-written per-app
/// snippets). Ported from `LocalAITest`.
///
/// Runs `osascript` + `sdef` subprocesses, so the resolving call is BLOCKING — invoke it
/// off the main actor (`Task.detached`). Degrades to nil (no injection) if the app can't be
/// resolved, isn't scriptable, or subprocesses are unavailable — the retry still proceeds.
enum AppleScriptDictionary {

    /// The first `tell application "X"` target in an AppleScript source, or nil.
    static func appName(in script: String) -> String? {
        guard let range = script.range(of: "application\\s+\"[^\"]+\"", options: .regularExpression) else { return nil }
        return quoted(in: String(script[range]))
    }

    /// Condensed dictionary for `appName`, or nil. BLOCKING — call via `Task.detached`.
    static func condensed(forApp appName: String) -> String? {
        guard let appPath = runProcess("/usr/bin/osascript",
                                       ["-e", "POSIX path of (path to application \"\(appName)\")"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !appPath.isEmpty else { return nil }
        guard let xml = runProcess("/usr/bin/sdef", [appPath]), !xml.isEmpty else { return nil }
        return condense(xml, appName: appName)
    }

    // MARK: - Private

    private static func runProcess(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reduce verbose sdef XML to `class name: prop (type), …` lines + a command list.
    /// Capped at 6000 chars — Mail/Finder dictionaries would otherwise blow the 7B's context.
    static func condense(_ xml: String, appName: String) -> String {
        var classes: [(name: String, properties: [String])] = []
        var commands: [String] = []
        var currentClass: String?
        var currentProps: [String] = []
        func flush() {
            if let c = currentClass { classes.append((c, currentProps)) }
            currentClass = nil; currentProps = []
        }
        for rawLine in xml.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("<class ") { flush(); currentClass = attr("name", line) }
            else if line.hasPrefix("</class>") { flush() }
            else if line.hasPrefix("<property "), currentClass != nil {
                if let name = attr("name", line) { currentProps.append("\(name) (\(attr("type", line) ?? "?"))") }
            } else if line.hasPrefix("<command ") {
                if let name = attr("name", line) { commands.append(name) }
            }
        }
        flush()
        var out = "AppleScript dictionary for \(appName) (use these EXACT names):\n\n"
        for c in classes where !c.properties.isEmpty {
            out += "class \(c.name): " + c.properties.joined(separator: ", ") + "\n"
        }
        if !commands.isEmpty {
            out += "\ncommands: " + Array(Set(commands)).sorted().joined(separator: ", ") + "\n"
        }
        if out.count > 6000 { out = String(out.prefix(6000)) + "\n…(truncated)\n" }
        return out
    }

    /// Value of an XML attribute on a single element line: attr("name", `<class name="event" …>`) → "event".
    private static func attr(_ name: String, _ line: String) -> String? {
        guard let range = line.range(of: "\(name)=\"[^\"]*\"", options: .regularExpression) else { return nil }
        return quoted(in: String(line[range]))
    }

    /// The substring between the first and last double-quote.
    private static func quoted(in s: String) -> String? {
        guard let q1 = s.firstIndex(of: "\""), let q2 = s.lastIndex(of: "\""), q1 != q2 else { return nil }
        return String(s[s.index(after: q1)..<q2])
    }
}
