import AppKit

enum AppleScriptToolError: LocalizedError {
    case compileFailed(String)
    case decodeFailed(String)
    case runtimeFailed(String)

    var errorDescription: String? {
        switch self {
        case .compileFailed(let s): return "Couldn't compile script: \(s)"
        case .decodeFailed(let s):  return "Tool input invalid: \(s)"
        case .runtimeFailed(let s): return "AppleScript runtime error: \(s)"
        }
    }
}

struct RunAppleScriptInput: Decodable {
    let script: String
    let purpose: String?  // optional human-friendly summary
}

@MainActor
final class AppleScriptTool {
    static let shared = AppleScriptTool()
    private init() {}

    static var tools: [Tool] { [runScriptTool] }

    static let runScriptTool = Tool(
        name: "run_applescript",
        description: """
        Run an AppleScript on the user's Mac to interact with any app via macOS automation. \
        Used for cross-app actions Akari doesn't have a dedicated tool for.

        The script is shown to the user verbatim and they confirm before each run. First-time use \
        of a target app triggers macOS Automation permission. Each failure-then-retry burns a turn — \
        prefer the patterns below that are known to work, and don't fall back to slow alternatives.

        ===== RELIABLE PATTERNS =====

        Microsoft Word — create + populate a new document:
            tell application "Microsoft Word"
                activate
                set newDoc to make new document
                set content of text object of newDoc to "your text here"
            end tell

        Apple Notes — create a new note:
            tell application "Notes"
                make new note with properties {name:"Title", body:"Body text"}
            end tell

        Apple Pages — create a new document with body:
            tell application "Pages"
                set newDoc to make new document
                set body text of newDoc to "your text here"
            end tell

        Apple Mail — compose a draft:
            tell application "Mail"
                make new outgoing message with properties {subject:"Subject", content:"Body"}
            end tell

        Apple Calendar — list today's events:
            tell application "Calendar" to get summary of every event of every calendar whose start date >= (current date)

        Open an app to the foreground:
            tell application "AppName" to activate

        ===== INSERTING LONG TEXT =====

        For apps that DON'T expose a `content` / `body text` property, use clipboard + ⌘V — fast and clean:
            set the clipboard to "long text here"
            delay 0.2
            tell application "System Events" to keystroke "v" using {command down}

        DO NOT use `tell application "System Events" to keystroke "long text"` — it physically types every \
        character one at a time, visibly, slowly, and often loses characters. Always use the clipboard \
        approach for any text longer than a few words.

        ===== ESCAPING =====

        AppleScript strings: escape double quotes as \\" and use `& return &` for line breaks instead of \\n.

        Use `purpose` to tell the user what the script does in one sentence.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "script": [
                    "type": "string",
                    "description": "The AppleScript source. Multi-line is fine."
                ],
                "purpose": [
                    "type": "string",
                    "description": "Optional one-sentence description shown to the user (e.g. 'Create a new Word document with this body')."
                ]
            ],
            "required": ["script"]
        ],
        confirmation: .confirm
    )

    func decode(_ json: String) throws -> RunAppleScriptInput {
        guard let data = json.data(using: .utf8) else {
            throw AppleScriptToolError.decodeFailed("not UTF-8")
        }
        return try JSONDecoder().decode(RunAppleScriptInput.self, from: data)
    }

    /// Execute the script via NSAppleScript. Returns output string on success.
    func runScript(_ source: String) throws -> String {
        guard let appleScript = NSAppleScript(source: source) else {
            throw AppleScriptToolError.compileFailed("invalid syntax")
        }
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            let message = (errorDict[NSAppleScript.errorMessage] as? String)
                ?? (errorDict.description)
            throw AppleScriptToolError.runtimeFailed(message)
        }
        return result.stringValue ?? ""
    }
}
