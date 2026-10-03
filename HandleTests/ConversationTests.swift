import XCTest
import AppKit
@testable import Handle

final class ConversationTests: AppTestCase {
    func testConversationSnapshots() {
        let emptyConvo = Conversation(chatWithApp: "Test")
        XCTAssertNil(emptyConvo.snapshot(), "snapshot empty → nil")
        let convo = Conversation(chatWithApp: "Test")
        convo.addUserMessage("What's on my calendar today?\nsecond line")
        convo.commitAssistantMessage("Three events.")
        convo.addToolChip(name: "read_calendar_events", inputJSON: "{}", content: "3 events", isError: false, displaySummary: "3 event(s)")
        let snap = convo.snapshot()
        XCTAssertNotNil(snap, "snapshot exists")
        XCTAssertEqual(snap?.title, "What's on my calendar today?", "snapshot title = first user line")
        XCTAssertEqual(snap?.messages.count, 3, "snapshot keeps 3 rows")
        XCTAssertEqual(snap?.messages.last?.toolName, "read_calendar_events", "snapshot chip → tool row")
        XCTAssertEqual(snap?.id, convo.persistentID, "snapshot id stable")
        if let snap {
            let restored = Conversation.restore(from: snap)
            XCTAssertEqual(restored.persistentID, convo.persistentID, "restore keeps id")
            XCTAssertEqual(restored.snapshot()?.messages.count, 3, "restore keeps turns")
            XCTAssertEqual(restored.visibleMessages.count, convo.visibleMessages.count, "restore visible count")
        }
        let longConvo = Conversation(chatWithApp: "")
        longConvo.addUserMessage(String(repeating: "x", count: 200))
        longConvo.commitAssistantMessage("ok")
        XCTAssertEqual(longConvo.snapshot()?.title.count, 60, "snapshot title capped 60")
    }

    func testMemory() {
        XCTAssertEqual(Intent.rememberCommand("remember that Mary's email is mary@acme.com"), "Mary's email is mary@acme.com", "remember that → fact")
        XCTAssertEqual(Intent.rememberCommand("remember my wifi is CasaDima"), "my wifi is CasaDima", "remember my → fact")
        XCTAssertNil(Intent.rememberCommand("remember to buy milk tomorrow"), "remember to → nil (reminder!)")
        XCTAssertNil(Intent.rememberCommand("what's on my calendar"), "plain prompt → nil")
        XCTAssertEqual(Intent.forgetCommand("forget about my wifi"), "my wifi", "forget about → phrase")
        XCTAssertEqual(Intent.forgetCommand("forget that Mary thing"), "Mary thing", "forget that → phrase")
        XCTAssertNil(Intent.forgetCommand("forget it"), "forget it → nil")
        XCTAssertTrue(MemoryStore.tokens("Mary's email is mary@acme.com").contains("mary"), "mem tokens keep names")
        XCTAssertFalse(MemoryStore.tokens("remember that this is for you").contains("remember"), "mem tokens drop stopwords")
        XCTAssertFalse(MemoryStore.tokens("go to it").contains("go"), "mem tokens drop short")
        XCTAssertTrue(MemoryStore.preamble(for: []).isEmpty, "mem preamble empty")
        XCTAssertTrue(MemoryStore.preamble(for: [MemoryFact(id: "1", content: "likes tea", createdAt: Date())]).contains("- likes tea"), "mem preamble bullets")
    }

    func testModelStorage() {
        let storedBase = UserDefaults.standard.string(forKey: "handle.models.base")
        UserDefaults.standard.removeObject(forKey: "handle.models.base")
        XCTAssertTrue(ModelStorage.base.path.hasSuffix("Documents/huggingface"), "storage default = Documents/huggingface")
        UserDefaults.standard.set("/Volumes/Ext/huggingface", forKey: "handle.models.base")
        XCTAssertEqual(ModelStorage.base.path, "/Volumes/Ext/huggingface", "storage override honored")
        if let storedBase { UserDefaults.standard.set(storedBase, forKey: "handle.models.base") }
        else { UserDefaults.standard.removeObject(forKey: "handle.models.base") }
        // The size is only reported once a speech model has been downloaded.
        if FileManager.default.fileExists(atPath: ModelStorage.base.path) {
            XCTAssertFalse(ModelStorage.sizeDescription().isEmpty, "storage size readable")
        }
    }

    func testVoice() {
        XCTAssertEqual(SpeechService.clean("[BLANK_AUDIO] set the volume to 20 (silence)"), "set the volume to 20", "stt clean brackets")
        XCTAssertEqual(SpeechService.clean("<|startoftranscript|> click the send button"), "click the send button", "stt clean tags")
        XCTAssertEqual(SpeechService.clean("  empty the trash  "), "empty the trash", "stt clean plain")
    }

    func testEmojiStrip() {
        XCTAssertEqual(Conversation.withoutEmoji("Good morning! 🌞"), "Good morning!", "emoji strip smiley")
        XCTAssertEqual(Conversation.withoutEmoji("welcome 🫶 back"), "welcome back", "emoji strip mid-text")
        XCTAssertEqual(Conversation.withoutEmoji("hi 👩‍💻 there"), "hi there", "emoji strip zwj seq")
        XCTAssertEqual(Conversation.withoutEmoji("call 911 at 9:30"), "call 911 at 9:30", "emoji keeps digits")
        XCTAssertEqual(Conversation.withoutEmoji("A → B"), "A → B", "emoji keeps arrows")
        XCTAssertEqual(Conversation.withoutEmoji("plain text"), "plain text", "emoji passthrough")
    }

    func testChatTitles() {
        XCTAssertEqual(Conversation.sanitizedTitle("\"Dentist appointment.\""), "Dentist appointment", "title strips quotes/period")
        XCTAssertEqual(Conversation.sanitizedTitle("Volume change 🔊"), "Volume change", "title strips emoji")
        XCTAssertNil(Conversation.sanitizedTitle("This chat was about scheduling a dentist appointment next week"), "title rejects sentence")
        XCTAssertNil(Conversation.sanitizedTitle("  \"\" "), "title rejects empty")
        XCTAssertTrue(Conversation.sanitizedTitle("Extraordinarily comprehensive calendarreview")!.count <= 40, "title caps 40")
        let titledConvo = Conversation(chatWithApp: "")
        titledConvo.addUserMessage("whats in my calendar?")
        titledConvo.commitAssistantMessage("Nothing today.")
        titledConvo.generatedTitle = "Calendar check"
        XCTAssertEqual(titledConvo.snapshot()?.title, "Calendar check", "snapshot prefers generated title")
        titledConvo.generatedTitle = ""   // in-flight claim must never persist
        XCTAssertEqual(titledConvo.snapshot()?.title, "whats in my calendar?", "snapshot ignores claim marker")
        titledConvo.generatedTitle = "Calendar check"
        if let snap = titledConvo.snapshot() {
            let back = Conversation.restore(from: snap)
            XCTAssertEqual(back.snapshot()?.title, "Calendar check", "restore keeps title through re-save")
        }
    }

    func testPersonalContextInjection() {
        XCTAssertTrue(app.promptAsksPersonalContext("whats on my calendar?"), "ctx gate calendar")
        XCTAssertTrue(app.promptAsksPersonalContext("anything due this week?"), "ctx gate due")
        XCTAssertTrue(app.promptAsksPersonalContext("what am I doing tomorrow"), "ctx gate tomorrow")
        XCTAssertFalse(app.promptAsksPersonalContext("write a haiku about cats"), "ctx gate haiku → false")
        XCTAssertTrue(AppDelegate.formatPersonalDigest(events: nil, reminders: nil).isEmpty, "ctx digest both nil → empty")
        XCTAssertFalse(AppDelegate.formatPersonalDigest(events: [], reminders: nil).contains("Reminders"), "ctx digest unauthorized omitted")
        XCTAssertTrue(AppDelegate.formatPersonalDigest(events: [], reminders: []).contains("Events: none"), "ctx digest empty says none")
        let ctxDigest = AppDelegate.formatPersonalDigest(events: [(title: "Standup", start: Date().addingTimeInterval(3600))], reminders: ["water plants"])
        XCTAssertTrue(ctxDigest.contains("today"), "ctx digest renders event")
        XCTAssertTrue(ctxDigest.contains("Standup"), "ctx digest renders event")
        XCTAssertTrue(ctxDigest.contains("water plants"), "ctx digest renders reminder")
        XCTAssertTrue(ctxDigest.contains("still use the tools"), "ctx digest write guidance")
    }
}
