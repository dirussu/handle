import XCTest
import AppKit
@testable import Handle

final class ConversationTests: AppTestCase {
    func testConversationSnapshots() {
        let emptyConvo = Conversation(chatWithApp: "Test")
        check("snapshot empty → nil", emptyConvo.snapshot() == nil)
        let convo = Conversation(chatWithApp: "Test")
        convo.addUserMessage("What's on my calendar today?\nsecond line")
        convo.commitAssistantMessage("Three events.")
        convo.addToolChip(name: "read_calendar_events", inputJSON: "{}", content: "3 events", isError: false, displaySummary: "3 event(s)")
        let snap = convo.snapshot()
        check("snapshot exists", snap != nil)
        check("snapshot title = first user line", snap?.title == "What's on my calendar today?")
        check("snapshot keeps 3 rows", snap?.messages.count == 3)
        check("snapshot chip → tool row", snap?.messages.last?.toolName == "read_calendar_events")
        check("snapshot id stable", snap?.id == convo.persistentID)
        if let snap {
            let restored = Conversation.restore(from: snap)
            check("restore keeps id", restored.persistentID == convo.persistentID)
            check("restore keeps turns", restored.snapshot()?.messages.count == 3)
            check("restore visible count", restored.visibleMessages.count == convo.visibleMessages.count)
        }
        let longConvo = Conversation(chatWithApp: "")
        longConvo.addUserMessage(String(repeating: "x", count: 200))
        longConvo.commitAssistantMessage("ok")
        check("snapshot title capped 60", longConvo.snapshot()?.title.count == 60)
    }

    func testMemory() {
        check("remember that → fact", app.parseRememberCommand("remember that Mary's email is mary@acme.com") == "Mary's email is mary@acme.com")
        check("remember my → fact", app.parseRememberCommand("remember my wifi is CasaDima") == "my wifi is CasaDima")
        check("remember to → nil (reminder!)", app.parseRememberCommand("remember to buy milk tomorrow") == nil)
        check("plain prompt → nil", app.parseRememberCommand("what's on my calendar") == nil)
        check("forget about → phrase", app.parseForgetCommand("forget about my wifi") == "my wifi")
        check("forget that → phrase", app.parseForgetCommand("forget that Mary thing") == "Mary thing")
        check("forget it → nil", app.parseForgetCommand("forget it") == nil)
        check("mem tokens keep names", MemoryStore.tokens("Mary's email is mary@acme.com").contains("mary"))
        check("mem tokens drop stopwords", !MemoryStore.tokens("remember that this is for you").contains("remember"))
        check("mem tokens drop short", !MemoryStore.tokens("go to it").contains("go"))
        check("mem preamble empty", MemoryStore.preamble(for: []).isEmpty)
        check("mem preamble bullets", MemoryStore.preamble(for: [MemoryFact(id: "1", content: "likes tea", createdAt: Date())]).contains("- likes tea"))
    }

    func testModelStorage() {
        let storedBase = UserDefaults.standard.string(forKey: "handle.models.base")
        UserDefaults.standard.removeObject(forKey: "handle.models.base")
        check("storage default = Documents/huggingface", ModelStorage.base.path.hasSuffix("Documents/huggingface"))
        UserDefaults.standard.set("/Volumes/Ext/huggingface", forKey: "handle.models.base")
        check("storage override honored", ModelStorage.base.path == "/Volumes/Ext/huggingface")
        if let storedBase { UserDefaults.standard.set(storedBase, forKey: "handle.models.base") }
        else { UserDefaults.standard.removeObject(forKey: "handle.models.base") }
        // The size is only reported once a speech model has been downloaded.
        if FileManager.default.fileExists(atPath: ModelStorage.base.path) {
            check("storage size readable", !ModelStorage.sizeDescription().isEmpty)
        }
    }

    func testVoice() {
        check("stt clean brackets", SpeechService.clean("[BLANK_AUDIO] set the volume to 20 (silence)") == "set the volume to 20")
        check("stt clean tags", SpeechService.clean("<|startoftranscript|> click the send button") == "click the send button")
        check("stt clean plain", SpeechService.clean("  empty the trash  ") == "empty the trash")
    }

    func testEmojiStrip() {
        check("emoji strip smiley", Conversation.withoutEmoji("Good morning! 🌞") == "Good morning!")
        check("emoji strip mid-text", Conversation.withoutEmoji("welcome 🫶 back") == "welcome back")
        check("emoji strip zwj seq", Conversation.withoutEmoji("hi 👩‍💻 there") == "hi there")
        check("emoji keeps digits", Conversation.withoutEmoji("call 911 at 9:30") == "call 911 at 9:30")
        check("emoji keeps arrows", Conversation.withoutEmoji("A → B") == "A → B")
        check("emoji passthrough", Conversation.withoutEmoji("plain text") == "plain text")
    }

    func testChatTitles() {
        check("title strips quotes/period", Conversation.sanitizedTitle("\"Dentist appointment.\"") == "Dentist appointment")
        check("title strips emoji", Conversation.sanitizedTitle("Volume change 🔊") == "Volume change")
        check("title rejects sentence", Conversation.sanitizedTitle("This chat was about scheduling a dentist appointment next week") == nil)
        check("title rejects empty", Conversation.sanitizedTitle("  \"\" ") == nil)
        check("title caps 40", Conversation.sanitizedTitle("Extraordinarily comprehensive calendarreview")!.count <= 40)
        let titledConvo = Conversation(chatWithApp: "")
        titledConvo.addUserMessage("whats in my calendar?")
        titledConvo.commitAssistantMessage("Nothing today.")
        titledConvo.generatedTitle = "Calendar check"
        check("snapshot prefers generated title", titledConvo.snapshot()?.title == "Calendar check")
        titledConvo.generatedTitle = ""   // in-flight claim must never persist
        check("snapshot ignores claim marker", titledConvo.snapshot()?.title == "whats in my calendar?")
        titledConvo.generatedTitle = "Calendar check"
        if let snap = titledConvo.snapshot() {
            let back = Conversation.restore(from: snap)
            check("restore keeps title through re-save", back.snapshot()?.title == "Calendar check")
        }
    }

    func testPersonalContextInjection() {
        check("ctx gate calendar", app.promptAsksPersonalContext("whats on my calendar?"))
        check("ctx gate due", app.promptAsksPersonalContext("anything due this week?"))
        check("ctx gate tomorrow", app.promptAsksPersonalContext("what am I doing tomorrow"))
        check("ctx gate haiku → false", !app.promptAsksPersonalContext("write a haiku about cats"))
        check("ctx digest both nil → empty", AppDelegate.formatPersonalDigest(events: nil, reminders: nil).isEmpty)
        check("ctx digest unauthorized omitted", !AppDelegate.formatPersonalDigest(events: [], reminders: nil).contains("Reminders"))
        check("ctx digest empty says none", AppDelegate.formatPersonalDigest(events: [], reminders: []).contains("Events: none"))
        let ctxDigest = AppDelegate.formatPersonalDigest(events: [(title: "Standup", start: Date().addingTimeInterval(3600))], reminders: ["water plants"])
        check("ctx digest renders event", ctxDigest.contains("today") && ctxDigest.contains("Standup"))
        check("ctx digest renders reminder", ctxDigest.contains("water plants"))
        check("ctx digest write guidance", ctxDigest.contains("still use the tools"))
    }
}
