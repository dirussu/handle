import XCTest
import AppKit
@testable import Handle

@MainActor
final class ConnectorTests: XCTestCase {
    func testAddAConnectorPasteBox() {
        XCTAssertEqual(MCPConfig.parseSnippet(#"{"mcpServers":{"w":{"command":"npx","args":["-y","w"]}}}"#).keys.sorted(), ["w"], "mcp snippet full form")
        XCTAssertEqual(MCPConfig.parseSnippet(#"{"w":{"command":"npx"},"x":{"command":"uvx"}}"#).keys.sorted(), ["w", "x"], "mcp snippet bare form")
        XCTAssertTrue(MCPConfig.parseSnippet("paste your json here").isEmpty, "mcp snippet junk → empty")
        XCTAssertTrue(MCPConfig.parseSnippet(#"{"w":{"args":["-y"]}}"#).isEmpty, "mcp snippet no-command → empty")
        let mcpTmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp_selftest.json")
        try? FileManager.default.removeItem(at: mcpTmp)
        XCTAssertEqual(MCPConfig.addServers(fromSnippet: #"{"a":{"command":"npx","env":{"K":"v"}}}"#, to: mcpTmp), ["a"], "mcp add creates file")
        XCTAssertEqual(MCPConfig.addServers(fromSnippet: #"{"mcpServers":{"b":{"command":"uvx"}}}"#, to: mcpTmp), ["b"], "mcp add merges")
        let mcpRead = (try? Data(contentsOf: mcpTmp)).map(MCPConfig.parse) ?? []
        XCTAssertEqual(mcpRead.map(\.name), ["a", "b"], "mcp add round-trip")
        XCTAssertEqual(mcpRead.first?.env, ["K": "v"], "mcp add round-trip")
        MCPConfig.removeServer(named: "a", from: mcpTmp)
        XCTAssertEqual(((try? Data(contentsOf: mcpTmp)).map(MCPConfig.parse) ?? []).map(\.name), ["b"], "mcp remove")
        try? FileManager.default.removeItem(at: mcpTmp)
    }

    func testTypewriterDrain() {
        XCTAssertEqual(Conversation.drainAmount(backlog: 10), 2, "drain amount floor")
        XCTAssertEqual(Conversation.drainAmount(backlog: 300), 20, "drain amount scales")
        let typeConvo = Conversation(chatWithApp: "")
        typeConvo.addUserMessage("q")
        let streamIdx = typeConvo.startAssistantStream()
        typeConvo.appendChunk(at: streamIdx, "Hello, ")
        typeConvo.appendChunk(at: streamIdx, "world! 🌍 Done.")
        typeConvo.finishAssistantStream(at: streamIdx)
        for _ in 0..<40 { typeConvo.drainOnce() }
        // emoji stripped, nothing lost
        XCTAssertEqual(typeConvo.messages[streamIdx].text, "Hello, world! Done.", "drain full text lands")
        XCTAssertFalse(typeConvo.messages[streamIdx].isStreaming, "drain finalizes stream")
        XCTAssertFalse(typeConvo.isAwaitingResponse, "drain finalizes stream")
        let stopConvo = Conversation(chatWithApp: "")
        stopConvo.addUserMessage("q")
        let stopIdx = stopConvo.startAssistantStream()
        stopConvo.appendChunk(at: stopIdx, "partial answer that was still buffering")
        stopConvo.stopStreaming()
        XCTAssertEqual(stopConvo.messages[stopIdx].text, "partial answer that was still buffering", "stop flushes buffer")
    }

    func testMCPKeychainRefs() {
        XCTAssertEqual(MCPKeychain.reference(in: "keychain:API_KEY"), "API_KEY", "keychain ref parse")
        XCTAssertEqual(MCPKeychain.reference(in: "keychain: MY_TOKEN "), "MY_TOKEN", "keychain ref trims")
        XCTAssertNil(MCPKeychain.reference(in: "sk-abc123"), "keychain ref plain → nil")
        XCTAssertNil(MCPKeychain.reference(in: "keychain:"), "keychain ref empty name → nil")
        XCTAssertNil(MCPKeychain.reference(in: "x keychain:Y"), "keychain ref mid-string → nil")
    }

    func testGUIAppPATHAugmentation() {
        XCTAssertEqual(MCPConfig.augmentedPATH(base: "/usr/bin:/bin", extras: ["/opt/homebrew/bin"]), "/usr/bin:/bin:/opt/homebrew/bin", "path augment appends")
        XCTAssertEqual(MCPConfig.augmentedPATH(base: "/usr/bin:/opt/homebrew/bin", extras: ["/opt/homebrew/bin", "/x"]), "/usr/bin:/opt/homebrew/bin:/x", "path augment dedups")
        XCTAssertTrue(MCPConfig.standardExtraDirs().contains("/opt/homebrew/bin"), "path extras have homebrew")
        // Only meaningful on a Mac that has Node installed through nvm.
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.nvm/versions/node") {
            XCTAssertTrue(MCPConfig.standardExtraDirs().contains { $0.contains("/.nvm/versions/node/") && $0.hasSuffix("/bin") }, "path extras find nvm node")
        }
    }
}
