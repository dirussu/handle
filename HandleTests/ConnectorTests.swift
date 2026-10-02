import XCTest
import AppKit
@testable import Handle

final class ConnectorTests: AppTestCase {
    func testAddAConnectorPasteBox() {
        check("mcp snippet full form", MCPConfig.parseSnippet(#"{"mcpServers":{"w":{"command":"npx","args":["-y","w"]}}}"#).keys.sorted() == ["w"])
        check("mcp snippet bare form", MCPConfig.parseSnippet(#"{"w":{"command":"npx"},"x":{"command":"uvx"}}"#).keys.sorted() == ["w", "x"])
        check("mcp snippet junk → empty", MCPConfig.parseSnippet("paste your json here").isEmpty)
        check("mcp snippet no-command → empty", MCPConfig.parseSnippet(#"{"w":{"args":["-y"]}}"#).isEmpty)
        let mcpTmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp_selftest.json")
        try? FileManager.default.removeItem(at: mcpTmp)
        check("mcp add creates file", MCPConfig.addServers(fromSnippet: #"{"a":{"command":"npx","env":{"K":"v"}}}"#, to: mcpTmp) == ["a"])
        check("mcp add merges", MCPConfig.addServers(fromSnippet: #"{"mcpServers":{"b":{"command":"uvx"}}}"#, to: mcpTmp) == ["b"])
        let mcpRead = (try? Data(contentsOf: mcpTmp)).map(MCPConfig.parse) ?? []
        check("mcp add round-trip", mcpRead.map(\.name) == ["a", "b"] && mcpRead.first?.env == ["K": "v"])
        MCPConfig.removeServer(named: "a", from: mcpTmp)
        check("mcp remove", ((try? Data(contentsOf: mcpTmp)).map(MCPConfig.parse) ?? []).map(\.name) == ["b"])
        try? FileManager.default.removeItem(at: mcpTmp)
    }

    func testTypewriterDrain() {
        check("drain amount floor", Conversation.drainAmount(backlog: 10) == 2)
        check("drain amount scales", Conversation.drainAmount(backlog: 300) == 20)
        let typeConvo = Conversation(chatWithApp: "")
        typeConvo.addUserMessage("q")
        let streamIdx = typeConvo.startAssistantStream()
        typeConvo.appendChunk(at: streamIdx, "Hello, ")
        typeConvo.appendChunk(at: streamIdx, "world! 🌍 Done.")
        typeConvo.finishAssistantStream(at: streamIdx)
        for _ in 0..<40 { typeConvo.drainOnce() }
        check("drain full text lands", typeConvo.messages[streamIdx].text == "Hello, world! Done.")   // emoji stripped, nothing lost
        check("drain finalizes stream", typeConvo.messages[streamIdx].isStreaming == false && typeConvo.isAwaitingResponse == false)
        let stopConvo = Conversation(chatWithApp: "")
        stopConvo.addUserMessage("q")
        let stopIdx = stopConvo.startAssistantStream()
        stopConvo.appendChunk(at: stopIdx, "partial answer that was still buffering")
        stopConvo.stopStreaming()
        check("stop flushes buffer", stopConvo.messages[stopIdx].text == "partial answer that was still buffering")
    }

    func testMCPKeychainRefs() {
        check("keychain ref parse", MCPKeychain.reference(in: "keychain:API_KEY") == "API_KEY")
        check("keychain ref trims", MCPKeychain.reference(in: "keychain: MY_TOKEN ") == "MY_TOKEN")
        check("keychain ref plain → nil", MCPKeychain.reference(in: "sk-abc123") == nil)
        check("keychain ref empty name → nil", MCPKeychain.reference(in: "keychain:") == nil)
        check("keychain ref mid-string → nil", MCPKeychain.reference(in: "x keychain:Y") == nil)
    }

    func testGUIAppPATHAugmentation() {
        check("path augment appends", MCPConfig.augmentedPATH(base: "/usr/bin:/bin", extras: ["/opt/homebrew/bin"]) == "/usr/bin:/bin:/opt/homebrew/bin")
        check("path augment dedups", MCPConfig.augmentedPATH(base: "/usr/bin:/opt/homebrew/bin", extras: ["/opt/homebrew/bin", "/x"]) == "/usr/bin:/opt/homebrew/bin:/x")
        check("path extras have homebrew", MCPConfig.standardExtraDirs().contains("/opt/homebrew/bin"))
        // Only meaningful on a Mac that has Node installed through nvm.
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.nvm/versions/node") {
            check("path extras find nvm node", MCPConfig.standardExtraDirs().contains { $0.contains("/.nvm/versions/node/") && $0.hasSuffix("/bin") })
        }
    }
}
