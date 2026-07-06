import Foundation
import SQLite3

/// One remembered user fact.
struct MemoryFact: Sendable, Identifiable {
    let id: String
    let content: String
    let createdAt: Date
}

/// User-fact memory at `~/Library/Application Support/Akari/memory.db`
/// (PRODUCT.md "Memory layer"). Facts enter EXPLICITLY — "remember that …" in
/// chat, or typed into Settings → Memory — never by silent model extraction:
/// deterministic in, deterministic out, and the user can read the whole store.
/// Per turn, `relevant(to:)` keyword-scores facts against the prompt (the same
/// prefilter idea the recipe engine uses) and the top few are folded into the
/// prompt — the 4B's context is too small to inject everything, always.
/// LOCAL only, like every store in Akari.
actor MemoryStore {
    static let shared = MemoryStore()

    private let dbURL: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(filename: String = "memory.db") {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Akari", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dbURL = base.appendingPathComponent(filename)
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: - Public API

    /// Store one fact. Near-duplicates (case-insensitive exact content) are
    /// refreshed instead of duplicated.
    func remember(_ content: String) -> MemoryFact? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, open() else { return nil }
        if let existing = all().first(where: { $0.content.lowercased() == trimmed.lowercased() }) {
            return existing
        }
        let fact = MemoryFact(id: UUID().uuidString, content: trimmed, createdAt: Date())
        run("INSERT INTO facts (id, content, created_at) VALUES (?1, ?2, ?3)",
            binds: [.text(fact.id), .text(fact.content), .real(fact.createdAt.timeIntervalSince1970)])
        return fact
    }

    func delete(id: String) {
        guard open() else { return }
        run("DELETE FROM facts WHERE id = ?1", binds: [.text(id)])
    }

    func wipe() {
        guard open() else { return }
        if sqlite3_exec(db, "DELETE FROM facts", nil, nil, nil) != SQLITE_OK {
            print("[Akari] MemoryStore wipe failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Every fact, newest first (Settings inspector).
    func all() -> [MemoryFact] {
        guard open() else { return [] }
        var out: [MemoryFact] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, content, created_at FROM facts ORDER BY created_at DESC", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(MemoryFact(
                id: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
                content: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            ))
        }
        return out
    }

    /// The facts worth injecting for this prompt — keyword-overlap scored,
    /// top `limit`, empty when nothing meaningfully matches.
    func relevant(to prompt: String, limit: Int = 5) -> [MemoryFact] {
        let promptTokens = Self.tokens(prompt)
        guard !promptTokens.isEmpty else { return [] }
        return all()
            .map { (fact: $0, score: Self.tokens($0.content).intersection(promptTokens).count) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.fact)
    }

    /// Deleting by content match ("forget my wifi password"): all facts whose
    /// tokens overlap the phrase, best first — caller decides what to do when
    /// it's ambiguous.
    func matching(_ phrase: String) -> [MemoryFact] {
        relevant(to: phrase, limit: 10)
    }

    // MARK: - Scoring (nonisolated + static so self-tests can hit it directly)

    /// Lowercased word set minus stopwords — the same prefilter shape the
    /// recipe engine uses. Words shorter than 3 chars are noise for scoring.
    nonisolated static func tokens(_ s: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "for", "that", "this", "with", "what", "when",
                                 "where", "who", "how", "you", "your", "his", "her", "its",
                                 "are", "was", "is", "my", "me", "to", "of", "in", "on", "at",
                                 "a", "an", "it", "i", "do", "does", "did", "not", "remember",
                                 "forget", "about", "please", "can", "could"]
        return Set(
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && !stop.contains($0) }
        )
    }

    /// Render facts as the prompt block ("" when empty). Wording is
    /// when-X-do-Y concrete — the 4B ignores abstract "use if relevant" asks.
    nonisolated static func preamble(for facts: [MemoryFact]) -> String {
        guard !facts.isEmpty else { return "" }
        return "The user PREVIOUSLY TOLD YOU these facts:\n"
            + facts.map { "- \($0.content)" }.joined(separator: "\n")
            + "\nWhen the request involves one of these facts, answer directly FROM the fact — no tool call, and never say you can't access it."
    }

    // MARK: - Private

    private func open() -> Bool {
        if db != nil { return true }
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            print("[Akari] MemoryStore: can't open \(dbURL.path)")
            if let db { sqlite3_close(db) }
            db = nil
            return false
        }
        _ = sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        _ = sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS facts (
                id TEXT PRIMARY KEY,
                content TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """, nil, nil, nil)
        return true
    }

    private enum Bind {
        case text(String)
        case real(Double)
    }

    private func run(_ sql: String, binds: [Bind]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[Akari] MemoryStore prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            let pos = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(stmt, pos, s, -1, transient)
            case .real(let v): sqlite3_bind_double(stmt, pos, v)
            }
        }
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("[Akari] MemoryStore step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
}
