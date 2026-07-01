//
// LocalAITest — proof-of-life and quality eval harness for Akari's
// local AI pipeline.
//
// Two modes:
//
//   Vision: `LocalAITest <image-path> "<prompt>"`
//           Loads Qwen 2.5 VL 7B (4-bit MLX), describes a screenshot.
//
//   Code:   `LocalAITest --code "<prompt>"`              (just write)
//           `LocalAITest --code --run "<prompt>"`        (write + execute)
//           Loads Qwen 2.5 Coder 14B (4-bit MLX), generates AppleScript,
//           optionally executes it via `osascript` and reports
//           success/failure.
//
// This is throwaway eval code, not production. Once we know each piece
// works, we lift the same MLX packages and architecture into the Akari
// app itself.
//

import CoreGraphics
import CoreImage
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

// MARK: - Constants

/// Vision-language model. Qwen 2.5 VL 7B 4-bit (~5 GB on disk).
///
/// We use 2.5 VL instead of the newer 3 VL because Qwen3VL.swift in
/// mlx-swift-examples 2.29.1 has an incomplete tied-embedding handler
/// that crashes when loading the official 3 VL weights. Will swap to
/// 3 VL when MLX support stabilizes.
let visionModelID = "mlx-community/Qwen2.5-VL-7B-Instruct-4bit"

/// Code-generation model: Qwen 2.5 Coder 7B Instruct (4-bit MLX), ~4.5 GB.
///
/// The earlier Coder-variant segfault was actually the `.system()` chat-
/// template bug in mlx-swift-examples 2.29.1, not a Coder-specific issue.
/// With the merged-user-prompt workaround now in place, Coder should
/// load and run cleanly. Coder is materially better than the generic
/// 7B Instruct at producing language-specific code on demand — critical
/// here because the generic 7B ignores explicit AppleScript instructions
/// and emits Python instead.
let codeModelID = "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"

/// Generation parameters tuned for each mode.
let visionGeneration = GenerateParameters(maxTokens: 512, temperature: 0.6, topP: 0.9)

// Lower temperature for code — we want deterministic, syntactically
// correct AppleScript, not creative variations.
let codeGeneration = GenerateParameters(maxTokens: 1024, temperature: 0.2, topP: 0.9)

/// Image-edge cap in pixels. Image attention is O(n²) in token count, so
/// uncapped Retina screenshots can take 2+ minutes on a base M-Air for
/// a single response. 1568 matches Anthropic's API default. Disable
/// with 0.
let maxImageEdge: CGFloat = 1568

/// Maximum number of generate → run → retry cycles when in --run mode.
/// First attempt + up to 2 retries = 3 generations total. Empirically
/// most fixable syntax errors are caught on the first retry.
let maxRetryAttempts = 2

/// How long to let an osascript invocation run before killing it. A
/// correct-but-slow script (unbounded Calendar `whose` query) or one
/// blocked on a permission dialog must NOT hang the tool — or, in the
/// real app, the assistant. Timing out is itself useful signal.
///
/// MUST be declared up here, BEFORE the top-level `switch mode` dispatch.
/// Swift initializes top-level `let`s in source order; a config constant
/// declared after the dispatch reads as its zero value inside any
/// function the dispatch calls. (This exact trap already bit us once
/// with appleScriptSystemPrompt — keeping ALL runtime config constants
/// above the dispatch from now on.)
let osascriptTimeout: TimeInterval = 20

/// Prompt biases the coder toward emitting compilable AppleScript
/// wrapped in a fenced code block. Uses one-shot example because
/// AppleScript is under-represented in open training data, so models
/// default to Python or shell unless we firmly anchor to AppleScript.
///
/// MUST be declared BEFORE the top-level `switch mode` dispatch — Swift
/// initializes top-level lets in source order, and the switch invokes
/// runCodeMode which reads this string. If declared after the switch,
/// it reads as empty at runtime.
let appleScriptSystemPrompt = """
You are an expert macOS AppleScript developer. The user will describe
an automation task they want done on their Mac. You ALWAYS respond with
AppleScript — never Python, never shell, never JavaScript, never any
other language. AppleScript is the ONLY acceptable output language.

Output format requirements:
1. Output ONLY a fenced AppleScript code block: ```applescript ... ```
2. NO prose before or after the code block
3. NO alternative implementations
4. NO comments outside the code block
5. The code MUST compile and run on modern macOS

Defensive coding — ALWAYS guard against empty/missing state. Many apps
error with "-1728 Can't get X" when the thing doesn't currently exist
(no track playing, no window open, no selection). Before accessing such
things, check existence and handle the empty case gracefully:
- `if exists current track then … else display notification "Nothing playing"`
- `if (count of Finder windows) > 0 then … else display notification "No Finder window open"`
- `if (count of windows) is 0 then return`
A script that handles the empty case and exits cleanly is CORRECT; one
that crashes on empty state is WRONG.

Reference idioms (use these exact patterns — they are correct):

• Dates: AppleScript has NO date literal. Build dates by mutating
  properties. `time` is seconds-since-midnight, so 9am = 9 * hours:
      set theDate to (current date) + 1 * days
      set time of theDate to 9 * hours
  Never write `time 9:00 am` or `+ time 9 * hours` — invalid.

• Mail: there is no mailbox named "INBOX". Use the built-in `inbox`:
      tell application "Mail"
          set theSubject to subject of (item 1 of (messages of inbox))
      end tell

• Calendar: do NOT hardcode a calendar name. Iterate `calendars`. The
  event title property is `summary`, NOT `title`. Filter by start date:
      tell application "Calendar"
          set soonest to missing value
          repeat with cal in calendars
              repeat with e in (every event of cal whose start date > (current date))
                  if soonest is missing value or (start date of e) < (start date of soonest) then
                      set soonest to contents of e
                  end if
              end repeat
          end repeat
          if soonest is not missing value then display notification (summary of soonest)
      end tell

Example 1:

User task: show a notification that says "Build complete"

Your response (and ONLY this):

```applescript
display notification "Build complete"
```

Example 2:

User task: create a reminder titled "Call mom" due today at 6pm

Your response (and ONLY this):

```applescript
set dueDate to (current date)
set time of dueDate to 18 * hours
tell application "Reminders"
    make new reminder with properties {name:"Call mom", due date:dueDate}
end tell
```

Now write AppleScript for the user's task below.
"""

/// JXA (JavaScript for Automation) prompt. JXA speaks the same Apple
/// Events as AppleScript but in JavaScript — a language the model knows
/// far better, so syntax/idiom errors should drop. The key JXA-specific
/// facts: properties are accessed as FUNCTION CALLS (`track.name()` not
/// `track.name`), and notifications require `includeStandardAdditions`.
let jxaSystemPrompt = """
You are an expert in JXA (JavaScript for Automation) on macOS. The user
will describe an automation task. You ALWAYS respond with JXA JavaScript
— never AppleScript, never Python, never shell. JXA is the ONLY
acceptable output.

Output format requirements:
1. Output ONLY a fenced JavaScript code block: ```javascript ... ```
2. NO prose before or after the code block
3. NO alternative implementations
4. The code MUST run via `osascript -l JavaScript`

Critical JXA facts:
- Get an app:  const app = Application('Music')
- Properties are FUNCTION CALLS: app.currentTrack.name()  (NOT .name)
- Notifications need standard additions:
      const app = Application.currentApplication()
      app.includeStandardAdditions = true
      app.displayNotification("Hello")
- Dates use normal JavaScript Date objects.

Defensive coding — ALWAYS guard against empty/missing state. Apps throw
when something doesn't exist (no track playing, no window open). Wrap
risky access in try/catch or check existence first, and handle the empty
case gracefully (e.g. show a "nothing playing" notification). A script
that handles the empty case and exits cleanly is CORRECT.

Example 1:

User task: show a notification that says "Build complete"

Your response (and ONLY this):

```javascript
const app = Application.currentApplication()
app.includeStandardAdditions = true
app.displayNotification("Build complete")
```

Example 2:

User task: show the name of the current Safari tab as a notification

Your response (and ONLY this):

```javascript
const app = Application.currentApplication()
app.includeStandardAdditions = true
const safari = Application('Safari')
if (safari.windows.length > 0) {
  app.displayNotification(safari.windows[0].currentTab.name())
} else {
  app.displayNotification("No Safari window open")
}
```

Now write JXA for the user's task below.
"""

// MARK: - Mode parsing

/// Which scripting language the code mode targets.
enum ScriptLanguage {
    case appleScript
    case jxa

    var systemPrompt: String {
        switch self {
        case .appleScript: return appleScriptSystemPrompt
        case .jxa:         return jxaSystemPrompt
        }
    }

    /// The fenced-block tag the model is told to use.
    var fenceTag: String {
        switch self {
        case .appleScript: return "applescript"
        case .jxa:         return "javascript"
        }
    }

    /// osascript arguments to run a script string in this language.
    func osascriptArguments(script: String) -> [String] {
        switch self {
        case .appleScript: return ["-e", script]
        case .jxa:         return ["-l", "JavaScript", "-e", script]
        }
    }

    /// Regex to pull the first targeted app name from a script, for
    /// .sdef dictionary lookup.
    var appNameRegex: String {
        switch self {
        case .appleScript: return #"tell application "([^"]+)""#
        case .jxa:         return #"Application\(['"]([^'"]+)['"]\)"#
        }
    }

    var label: String {
        switch self {
        case .appleScript: return "AppleScript"
        case .jxa:         return "JXA"
        }
    }
}

enum Mode {
    case vision(imagePath: String, prompt: String)
    case code(prompt: String, execute: Bool, language: ScriptLanguage)
}

func parseMode(_ args: [String]) -> Mode? {
    // Drop the binary path.
    let argv = Array(args.dropFirst())

    // `--code` → AppleScript, `--jxa` → JavaScript for Automation.
    // Both accept an optional `--run` to execute the generated script.
    if argv.first == "--code" || argv.first == "--jxa" {
        let language: ScriptLanguage = (argv.first == "--jxa") ? .jxa : .appleScript
        var rest = Array(argv.dropFirst())
        var execute = false
        if rest.first == "--run" {
            execute = true
            rest = Array(rest.dropFirst())
        }
        guard !rest.isEmpty else { return nil }
        return .code(prompt: rest.joined(separator: " "), execute: execute, language: language)
    }

    // Vision mode: <image-path> <prompt...>
    guard argv.count >= 2 else { return nil }
    return .vision(imagePath: argv[0], prompt: argv[1...].joined(separator: " "))
}

func printUsage() {
    print("""

    LocalAITest — Akari local-AI eval harness

    Vision mode (Qwen 2.5 VL 7B):
        LocalAITest <image-path> "<prompt>"

    Code mode (Qwen 2.5 Coder 7B):
        LocalAITest --code "<automation>"          AppleScript, generate only
        LocalAITest --code --run "<automation>"    AppleScript, generate + run
        LocalAITest --jxa  "<automation>"          JXA (JavaScript), generate only
        LocalAITest --jxa  --run "<automation>"    JXA, generate + run

    First-run downloads (one-time, into ~/Documents/huggingface/):
        Vision model:  ~5 GB (Qwen 2.5 VL 7B)
        Code model:    ~4.5 GB (Qwen 2.5 Coder 7B)

    """)
}

guard let mode = parseMode(CommandLine.arguments) else {
    printUsage()
    exit(1)
}

// MARK: - Shared infrastructure

/// Cap MLX's GPU cache so the process plays nice with other apps.
MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

/// Mutable state shared with the streaming callback. Class type to
/// sidestep strict-concurrency actor isolation rules on top-level vars.
final class StreamState: @unchecked Sendable {
    var printedSoFar: String = ""
    var generatedTokenCount: Int = 0
}

/// Download + load a model from HuggingFace via the appropriate factory,
/// showing a progress bar in stderr.
func loadContainer<Factory: ModelFactory>(
    _ factory: Factory,
    id: String
) async throws -> ModelContainer {
    let configuration = ModelConfiguration(id: id)
    return try await factory.loadContainer(hub: HubApi(), configuration: configuration) { progress in
        let pct = Int(progress.fractionCompleted * 100)
        let bar = String(repeating: "█", count: pct / 5)
            + String(repeating: "░", count: 20 - pct / 5)
        fputs("\r  [\(bar)] \(pct)%", stderr)
    }
}

// MARK: - Mode dispatch

switch mode {
case .vision(let imagePath, let prompt):
    try await runVisionMode(imagePath: imagePath, prompt: prompt)
case .code(let prompt, let execute, let language):
    try await runCodeMode(prompt: prompt, execute: execute, language: language)
}

// MARK: - Vision mode

func runVisionMode(imagePath: String, prompt: String) async throws {
    // Resolve the image path.
    let imageURL: URL = {
        let path = (imagePath as NSString).expandingTildeInPath
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
    }()

    guard FileManager.default.fileExists(atPath: imageURL.path) else {
        print("✗ Image not found: \(imageURL.path)")
        exit(1)
    }

    printHeader(model: visionModelID, mode: "vision", subject: imageURL.lastPathComponent, prompt: prompt)
    print("Loading vision model… (first run: downloading ~5 GB)\n")

    let loadStart = Date()
    let modelContainer = try await loadContainer(VLMModelFactory.shared, id: visionModelID)
    let loadSeconds = Date().timeIntervalSince(loadStart)
    print("\n\n✓ Model loaded in \(String(format: "%.1f", loadSeconds))s")

    // Load + optionally downscale the input image.
    guard let originalImage = CIImage(contentsOf: imageURL) else {
        print("✗ Could not load image at \(imageURL.path)")
        exit(1)
    }
    let imageToSend: UserInput.Image
    if maxImageEdge > 0 {
        let w = originalImage.extent.width
        let h = originalImage.extent.height
        let longestEdge = max(w, h)
        if longestEdge > maxImageEdge {
            let scale = maxImageEdge / longestEdge
            let scaled = originalImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            fputs("[info] Downscaled image \(Int(w))×\(Int(h)) → \(Int(scaled.extent.width))×\(Int(scaled.extent.height)) (\(String(format: "%.2f", scale))× scale)\n", stderr)
            imageToSend = .ciImage(scaled)
        } else {
            fputs("[info] Image \(Int(w))×\(Int(h)) within \(Int(maxImageEdge))px cap, no scaling\n", stderr)
            imageToSend = .ciImage(originalImage)
        }
    } else {
        imageToSend = .url(imageURL)
    }

    // Build chat input. We use init(chat:) explicitly to sidestep the
    // didSet-not-fired-during-init bug in mlx-swift-examples 2.29.1's
    // init(prompt:String,images:) — which silently drops the image.
    let userInput = UserInput(chat: [.user(prompt, images: [imageToSend])])
    print("\n──── Response ────\n")

    let inferenceStart = Date()
    let streamState = StreamState()

    let result = try await modelContainer.perform { context in
        let input = try await context.processor.prepare(input: userInput)
        return try MLXLMCommon.generate(
            input: input,
            parameters: visionGeneration,
            context: context
        ) { tokens in
            let fullText = context.tokenizer.decode(tokens: tokens)
            if fullText.count > streamState.printedSoFar.count {
                let delta = fullText.dropFirst(streamState.printedSoFar.count)
                print(delta, terminator: "")
                fflush(stdout)
                streamState.printedSoFar = fullText
            }
            return .more
        }
    }

    printStats(tokens: result.tokens.count, seconds: Date().timeIntervalSince(inferenceStart))
}

// MARK: - Code mode

/// Outcome of one osascript execution attempt.
struct ExecutionResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let seconds: TimeInterval
}

func runCodeMode(prompt: String, execute: Bool, language: ScriptLanguage) async throws {
    let modeLabel = "\(language.label.lowercased())\(execute ? "+run" : "")"
    printHeader(model: codeModelID, mode: modeLabel, subject: "(no image)", prompt: prompt)
    print("Loading code model… (first run: downloading ~4.5 GB)\n")

    let loadStart = Date()
    let modelContainer = try await loadContainer(LLMModelFactory.shared, id: codeModelID)
    let loadSeconds = Date().timeIntervalSince(loadStart)
    print("\n\n✓ Model loaded in \(String(format: "%.1f", loadSeconds))s")

    // Generation 1 → optionally execute → optionally regenerate with the
    // error message in context up to `maxRetryAttempts` more times. Each
    // attempt uses a fresh KV cache; we don't try to share KV state across
    // attempts because each prompt differs and the share would be lossy.
    var previousScript: String? = nil
    var previousStderr: String? = nil
    var injectedDictionary: String? = nil
    let totalAttempts = execute ? (1 + maxRetryAttempts) : 1

    for attempt in 1...totalAttempts {
        let attemptPrompt = buildCodePrompt(
            language: language,
            taskPrompt: prompt,
            previousScript: previousScript,
            previousError: previousStderr,
            appDictionary: injectedDictionary
        )

        // Escalate temperature on retries. Attempt 1 stays near-
        // deterministic (0.2) for the cleanest first shot; retries warm
        // up so the model actually explores alternatives instead of
        // regenerating the identical failing script.
        let attemptTemperature: Float = attempt == 1 ? 0.2 : (0.2 + 0.3 * Float(attempt - 1))

        print("\n──── Attempt \(attempt) of \(totalAttempts) — \(language.label) output (temp \(String(format: "%.1f", attemptTemperature))) ────\n")
        let generationStart = Date()
        let (fullResponse, generatedTokens) = try await generateScript(
            modelContainer: modelContainer,
            combinedPrompt: attemptPrompt,
            temperature: attemptTemperature
        )
        printStats(tokens: generatedTokens, seconds: Date().timeIntervalSince(generationStart))

        // Extract the code block from the model's response.
        guard let script = extractScript(from: fullResponse, language: language) else {
            print("\n✗ Could not extract a fenced ```\(language.fenceTag) ... ``` block.")
            if attempt == totalAttempts { exit(2) }
            previousScript = nil
            previousStderr = "The previous response did not contain a fenced \(language.fenceTag) code block. Output ONLY the code block, nothing else."
            continue
        }
        print("\n──── Extracted script ────")
        print(script)
        print("──────────────────────────")

        if !execute {
            print("\n(skipping execution; pass --run to pipe the script through osascript)")
            return
        }

        // Execute and check.
        let result = try executeScript(script, language: language)
        printExecutionResult(result)

        if result.exitCode == 0 {
            print("\n✓ Succeeded on attempt \(attempt) of \(totalAttempts).")
            return
        }
        if attempt == totalAttempts {
            print("\n✗ Failed after all \(totalAttempts) attempts. Final exit code: \(result.exitCode).")
            return
        }
        // Retry with the error context.
        previousScript = script
        previousStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        // .sdef INJECTION: figure out which app the failing script
        // targeted, pull that app's real dictionary, and inject it into
        // the next attempt. The dictionary is language-agnostic (same
        // Apple Events vocabulary), so it helps both AppleScript and JXA.
        if injectedDictionary == nil, let appName = firstAppName(in: script, language: language) {
            print("↻ Fetching \(appName)'s scripting dictionary for the retry…")
            if let dict = condensedDictionary(forApp: appName) {
                injectedDictionary = dict
                print("  ✓ Injected \(dict.count) chars of \(appName) dictionary vocabulary")
            } else {
                print("  (no scriptable dictionary found for \(appName))")
            }
        }
        print("↻ Retrying with error context…")
    }
}

// MARK: - .sdef dictionary injection

/// Extract the first targeted app name from a script, using the
/// language-appropriate pattern (`tell application "X"` for AppleScript,
/// `Application('X')` for JXA).
func firstAppName(in script: String, language: ScriptLanguage) -> String? {
    guard let range = script.range(
        of: language.appNameRegex,
        options: .regularExpression
    ) else { return nil }
    let match = String(script[range])
    // Pull the quoted name out of the match (handles both " and ').
    let quotes: Set<Character> = ["\"", "'"]
    guard let q1 = match.firstIndex(where: { quotes.contains($0) }),
          let q2 = match.lastIndex(where: { quotes.contains($0) }), q1 != q2 else { return nil }
    return String(match[match.index(after: q1)..<q2])
}

/// Resolve an app name to a condensed form of its AppleScript dictionary:
/// the class names with their property names+types, plus command names.
/// This is the authoritative vocabulary the model needs — far more
/// scalable than hand-writing per-app snippets, and works for ANY
/// scriptable app including ones we never anticipated.
///
/// Returns nil if the app can't be found or has no scripting dictionary.
func condensedDictionary(forApp appName: String) -> String? {
    // 1. Resolve the app's path. Use AppleScript itself — robust across
    //    /Applications, /System/Applications, and user locations.
    let pathProcess = Process()
    pathProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    pathProcess.arguments = ["-e", "POSIX path of (path to application \"\(appName)\")"]
    let pathPipe = Pipe()
    pathProcess.standardOutput = pathPipe
    pathProcess.standardError = Pipe()
    guard (try? pathProcess.run()) != nil else { return nil }
    pathProcess.waitUntilExit()
    guard pathProcess.terminationStatus == 0 else { return nil }
    let pathData = pathPipe.fileHandleForReading.readDataToEndOfFile()
    let appPath = (String(data: pathData, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !appPath.isEmpty else { return nil }

    // 2. Run `sdef <path>` to get the dictionary XML.
    let sdefProcess = Process()
    sdefProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sdef")
    sdefProcess.arguments = [appPath]
    let sdefPipe = Pipe()
    sdefProcess.standardOutput = sdefPipe
    sdefProcess.standardError = Pipe()
    guard (try? sdefProcess.run()) != nil else { return nil }
    let sdefData = sdefPipe.fileHandleForReading.readDataToEndOfFile()
    sdefProcess.waitUntilExit()
    guard sdefProcess.terminationStatus == 0,
          let xml = String(data: sdefData, encoding: .utf8), !xml.isEmpty
    else { return nil }

    // 3. Condense the XML to class→properties and command names.
    return condenseSdefXML(xml, appName: appName)
}

/// Reduce verbose sdef XML to a compact vocabulary reference the model
/// can actually use: each class with its properties (name + type), and
/// the list of command names. Strips descriptions, codes, synonyms, etc.
func condenseSdefXML(_ xml: String, appName: String) -> String {
    var classes: [(name: String, properties: [String])] = []
    var commands: [String] = []

    // Walk the XML line by line tracking the current <class> context.
    var currentClass: String? = nil
    var currentProps: [String] = []

    func flushClass() {
        if let c = currentClass {
            classes.append((c, currentProps))
        }
        currentClass = nil
        currentProps = []
    }

    for rawLine in xml.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)

        if line.hasPrefix("<class ") {
            flushClass()
            currentClass = attributeValue("name", in: line)
        } else if line.hasPrefix("</class>") {
            flushClass()
        } else if line.hasPrefix("<property "), currentClass != nil {
            if let name = attributeValue("name", in: line) {
                let type = attributeValue("type", in: line) ?? "?"
                currentProps.append("\(name) (\(type))")
            }
        } else if line.hasPrefix("<command ") {
            if let name = attributeValue("name", in: line) {
                commands.append(name)
            }
        }
    }
    flushClass()

    var out = "AppleScript dictionary for \(appName) (authoritative vocabulary — use these exact names):\n\n"
    for c in classes where !c.properties.isEmpty {
        out += "class \(c.name): " + c.properties.joined(separator: ", ") + "\n"
    }
    if !commands.isEmpty {
        out += "\ncommands: " + Array(Set(commands)).sorted().joined(separator: ", ") + "\n"
    }

    // Cap length — some dictionaries (Mail, Finder) are huge and would
    // blow the 7B's context. 6000 chars keeps the most important
    // (earliest-declared) classes.
    if out.count > 6000 {
        out = String(out.prefix(6000)) + "\n…(dictionary truncated)\n"
    }
    return out
}

/// Pull the value of an XML attribute from a single element line, e.g.
/// `attributeValue("name", in: "<class name=\"event\" code=\"...\">")` → "event".
func attributeValue(_ attr: String, in line: String) -> String? {
    guard let range = line.range(
        of: "\(attr)=\"([^\"]*)\"",
        options: .regularExpression
    ) else { return nil }
    let match = String(line[range])
    guard let q1 = match.firstIndex(of: "\""),
          let q2 = match.lastIndex(of: "\""), q1 != q2 else { return nil }
    return String(match[match.index(after: q1)..<q2])
}

/// Build the user-message prompt. First attempt is the base system+task
/// prompt. Retry attempts append the injected app dictionary (if any),
/// the previous failing script, and the stderr from osascript, asking
/// the model to repair the error.
func buildCodePrompt(
    language: ScriptLanguage,
    taskPrompt: String,
    previousScript: String?,
    previousError: String?,
    appDictionary: String?
) -> String {
    var out = language.systemPrompt

    // Inject the app's authoritative dictionary BEFORE the task, so the
    // model treats it as reference vocabulary rather than an afterthought.
    if let appDictionary {
        out += "\n\n" + appDictionary
    }

    out += "\n\nTask: " + taskPrompt

    if let previousScript, let previousError {
        out += """


        Your previous attempt failed with this osascript error:

        \(previousError)

        The script that failed:

        ```\(language.fenceTag)
        \(previousScript)
        ```

        Write a CORRECTED version of the script that fixes the specific error
        above, using the authoritative dictionary vocabulary provided. Output
        ONLY the corrected \(language.label) in a fenced code block. Do not
        explain the fix; just write the corrected code.
        """
    }
    return out
}

/// Run one generation pass: stream tokens to stdout, return the full
/// response text and the number of generated tokens.
func generateScript(
    modelContainer: ModelContainer,
    combinedPrompt: String,
    temperature: Float
) async throws -> (response: String, tokens: Int) {
    let params = GenerateParameters(maxTokens: 1024, temperature: temperature, topP: 0.9)
    let userInput = UserInput(chat: [.user(combinedPrompt)])
    let streamState = StreamState()
    try await modelContainer.perform { context in
        let input = try await context.processor.prepare(input: userInput)
        let cache = context.model.newCache(parameters: params)
        let stream = try MLXLMCommon.generate(
            input: input,
            cache: cache,
            parameters: params,
            context: context
        )
        for await generation in stream {
            switch generation {
            case .chunk(let text):
                streamState.printedSoFar += text
                print(text, terminator: "")
                fflush(stdout)
            case .info(let info):
                streamState.generatedTokenCount = info.generationTokenCount
            case .toolCall:
                break
            }
        }
    }
    return (streamState.printedSoFar, streamState.generatedTokenCount)
}

func printExecutionResult(_ result: ExecutionResult) {
    print("\n──── Running via osascript ────")
    print("Exit status: \(result.exitCode)")
    print("Wall time:   \(String(format: "%.2f", result.seconds))s")
    if !result.stdout.isEmpty { print("stdout:\n\(result.stdout)") }
    if !result.stderr.isEmpty { print("stderr:\n\(result.stderr)") }
    if result.exitCode == 0 {
        print("✓ Script executed without error")
    } else {
        print("✗ Script failed (non-zero exit)")
    }
    print("───────────────────────────────")
}

/// Extract the first code block from a (possibly noisy) model response.
/// Looks for a block tagged with the language's fence tag, then any
/// fenced block, then falls back to the whole response.
func extractScript(from response: String, language: ScriptLanguage) -> String? {
    let tag = language.fenceTag
    // Tagged block: ```<tag> ... ```
    if let range = response.range(of: "```\(tag)\\s*\\n([\\s\\S]*?)```", options: .regularExpression) {
        let inner = String(response[range])
            .replacingOccurrences(of: "```\(tag)", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !inner.isEmpty { return inner }
    }
    // Untagged block: ``` ... ```
    if let range = response.range(of: #"```\s*\n([\s\S]*?)```"#, options: .regularExpression) {
        let inner = String(response[range])
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !inner.isEmpty { return inner }
    }
    // No fences — last resort, the whole response.
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Run the script via /usr/bin/osascript (in the given language) and
/// return the result. Enforces `osascriptTimeout`: if the process runs
/// longer, it's killed (SIGTERM, then SIGKILL) and reported as a timeout
/// (exit code 124, matching the `timeout(1)` convention).
func executeScript(_ script: String, language: ScriptLanguage) throws -> ExecutionResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = language.osascriptArguments(script: script)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let start = Date()
    try process.run()

    // Watchdog: kill the process if it exceeds the timeout. Runs on a
    // background queue so we don't block the main thread on it.
    let timedOut = TimeoutFlag()
    let watchdog = DispatchWorkItem {
        if process.isRunning {
            timedOut.value = true
            process.terminate()                 // SIGTERM
            // Give it a moment, then hard-kill if still alive.
            usleep(500_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + osascriptTimeout, execute: watchdog)

    process.waitUntilExit()
    watchdog.cancel()
    let seconds = Date().timeIntervalSince(start)

    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: outData, encoding: .utf8) ?? ""
    var err = String(data: errData, encoding: .utf8) ?? ""

    if timedOut.value {
        err = "TIMED OUT after \(Int(osascriptTimeout))s — script is correct-but-slow or blocked on a permission dialog.\n" + err
        return ExecutionResult(exitCode: 124, stdout: out, stderr: err, seconds: seconds)
    }

    return ExecutionResult(
        exitCode: process.terminationStatus,
        stdout: out,
        stderr: err,
        seconds: seconds
    )
}

/// Tiny thread-safe-enough flag for the watchdog. The watchdog writes,
/// the main thread reads after join; the waitUntilExit barrier between
/// them is sufficient for this single-purpose use.
final class TimeoutFlag: @unchecked Sendable {
    var value: Bool = false
}

// MARK: - Output helpers

func printHeader(model: String, mode: String, subject: String, prompt: String) {
    print("┌──────────────────────────────────────────────────────────────")
    print("│ LocalAITest — \(mode)")
    print("├──────────────────────────────────────────────────────────────")
    print("│ Model:  \(model)")
    print("│ Subject: \(subject)")
    print("│ Prompt: \(prompt)")
    print("└──────────────────────────────────────────────────────────────\n")
}

func printStats(tokens: Int, seconds: TimeInterval) {
    let tps = Double(tokens) / seconds
    print("\n\n──── Stats ────")
    print("Tokens generated: \(tokens)")
    print("Inference time:   \(String(format: "%.2f", seconds))s")
    print("Throughput:       \(String(format: "%.1f", tps)) tokens/sec")
    print("──────────────────")
}
