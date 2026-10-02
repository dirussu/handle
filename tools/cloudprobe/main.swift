import Foundation
import CoreGraphics
import ImageIO

// Dev probe for the cloud adapters (PROVIDERS.md phase 0). Streams one turn
// straight through AnthropicProvider — no app, no GUI. Run via tools/cloudprobe.sh.
//   cloudprobe "say hi in three words"
//   cloudprobe --image /tmp/shot.png "what app is this?"
//   cloudprobe --tools "point at the back button"     (phase 1: tool-call streaming)
//   cloudprobe --provider openai --base http://localhost:1234/v1 --model qwen2.5 "hi"   (phase 4)
// Key: $ANTHROPIC_API_KEY / $OPENAI_API_KEY, else the Keychain item the app uses
// (service com.dimarussu.Handle.providers, account anthropic|openai). Local servers need none.

var args = Array(CommandLine.arguments.dropFirst())
var imagePath: String?
var withTools = false
var providerName = "anthropic"
var baseURL: String? = nil
var model: String? = ProcessInfo.processInfo.environment["HANDLE_MODEL"]
while let flag = args.first, flag.hasPrefix("--") {
    args.removeFirst()
    switch flag {
    case "--image": imagePath = args.isEmpty ? nil : args.removeFirst()
    case "--tools": withTools = true
    case "--model": model = args.isEmpty ? model : args.removeFirst()
    case "--provider": providerName = args.isEmpty ? providerName : args.removeFirst()
    case "--base": baseURL = args.isEmpty ? nil : args.removeFirst()
    default: FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8)); exit(2)
    }
}
let prompt = args.joined(separator: " ")
guard !prompt.isEmpty else {
    FileHandle.standardError.write(Data("usage: cloudprobe [--image PATH] [--tools] [--model ID] PROMPT\n".utf8)); exit(2)
}
let envKey = providerName == "openai" ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY"
let key = ProcessInfo.processInfo.environment[envKey] ?? SecretStore.providers.get(providerName) ?? ""
let base = baseURL.flatMap(OpenAIProvider.normalizeBaseURL)
if key.isEmpty && !(providerName == "openai" && base != nil) {
    FileHandle.standardError.write(Data("no key: set \(envKey) or add the Keychain item (see PROVIDERS.md); local servers need --base\n".utf8)); exit(1)
}

var parts: [AIMessage.Part] = []
if let imagePath {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let jpeg = AIImage.jpegData(cg) else {
        FileHandle.standardError.write(Data("could not read image \(imagePath)\n".utf8)); exit(1)
    }
    parts.append(.image(jpeg, mime: "image/jpeg"))
    FileHandle.standardError.write(Data("image: \(cg.width)x\(cg.height) → \(jpeg.count / 1024) KB jpeg\n".utf8))
}
parts.append(.text(prompt))

var tools: [AIToolSpec] = []
if withTools {
    tools = [AIToolSpec(name: "point_at", description: "Point the cursor at one on-screen element by its index in the numbered list.",
                        inputSchema: ["type": "object", "properties": ["index": ["type": "integer"]],
                                      "required": ["index"], "additionalProperties": false])]
}

let provider: AIProvider = providerName == "openai"
    ? OpenAIProvider(apiKey: key, baseURL: base, defaultModel: model ?? "gpt-5")
    : AnthropicProvider(apiKey: key, defaultModel: model ?? "claude-sonnet-5")
let request = AIRequest(messages: [AIMessage(role: .user, parts: parts)], tools: tools, model: model)
let t0 = Date()
var usageIn = 0, usageOut = 0
do {
    for try await ev in provider.stream(request) {
        switch ev {
        case .textDelta(let t): FileHandle.standardOutput.write(Data(t.utf8))
        case .toolCall(let id, let name, let json): print("\n[tool_call \(name) \(id)] \(json)")
        case .usage(let i, let o, let cr, _): if let i { usageIn = i }; if let o { usageOut = o }; if let cr, cr > 0 { print("[cache read \(cr)]") }
        case .done(let r): print("\n[done stop=\(r ?? "-")]")
        }
    }
} catch {
    print("\n[error] \(error.localizedDescription)"); exit(1)
}
print(String(format: "[usage in=%d out=%d  %.1fs  model=%@]", usageIn, usageOut, Date().timeIntervalSince(t0), model ?? provider.defaultModel))
