import Foundation
import SQLite3

/// A conversation reduced to its persistable TEXT — what the store reads/writes.
/// Captures/PDF bytes are deliberately absent: persisted history is text-only
/// (PRODUCT.md "See": if we ever persist chat history — store the *text*, not
/// the raw screenshots).
struct ConversationSnapshot: Sendable {
    let id: String
    let title: String
    let appName: String
    let createdAt: Date
    let updatedAt: Date
    let messages: [SavedMessage]
}

/// One persisted turn. `role` is "user" | "assistant" | "tool" — a tool row is
/// the transcript chip (what ran + its summary), not a raw result envelope.
struct SavedMessage: Sendable {
    let role: String
    let text: String
    let toolName: String?
    let toolSummary: String?
}

/// Row for the History list — no message bodies.
struct ConversationSummary: Sendable, Identifiable {
    let id: String
    let title: String
    let appName: String
    let updatedAt: Date
    let messageCount: Int
}

/// SQLite-backed conversation history at
/// `~/Library/Application Support/Akari/conversations.db`. An actor so writes
/// serialize off the main thread (same shape as AuditLog). LOCAL only.
///
/// Saves are whole-snapshot upserts inside one transaction — at chat scale
/// (tens of turns) replace-all is simpler and plenty fast, and it makes the
/// operation idempotent: the tool loop can persist on every exit path.
actor ConversationStore {
    static let shared = ConversationStore()

    private let dbURL: URL
    private var db: OpaquePointer?

    /// `SQLITE_TRANSIENT` — tells sqlite to copy bound strings immediately.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(filename: String = "conversations.db") {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Akari", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dbURL = base.appendingPathComponent(filename)
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: - Public API

    func save(_ snap: ConversationSnapshot) {
        guard open(), !snap.messages.isEmpty else { return }
        exec("BEGIN")
        run("""
            INSERT INTO conversations (id, title, app_name, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(id) DO UPDATE SET title = ?2, app_name = ?3, updated_at = ?5
            """,
            binds: [.text(snap.id), .text(snap.title), .text(snap.appName),
                    .real(snap.createdAt.timeIntervalSince1970),
                    .real(snap.updatedAt.timeIntervalSince1970)])
        run("DELETE FROM messages WHERE conversation_id = ?1", binds: [.text(snap.id)])
        for (i, m) in snap.messages.enumerated() {
            run("""
                INSERT INTO messages (conversation_id, idx, role, text, tool_name, tool_summary)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """,
                binds: [.text(snap.id), .int(i), .text(m.role), .text(m.text),
                        m.toolName.map(Bind.text) ?? .null,
                        m.toolSummary.map(Bind.text) ?? .null])
        }
        exec("COMMIT")
    }

    /// Newest-first summaries for the History list.
    func list(limit: Int = 30) -> [ConversationSummary] {
        guard open() else { return [] }
        var out: [ConversationSummary] = []
        let sql = """
            SELECT c.id, c.title, c.app_name, c.updated_at,
                   (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id)
            FROM conversations c ORDER BY c.updated_at DESC LIMIT ?1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(ConversationSummary(
                id: column(stmt, 0),
                title: column(stmt, 1),
                appName: column(stmt, 2),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                messageCount: Int(sqlite3_column_int(stmt, 4))
            ))
        }
        return out
    }

    func load(id: String) -> ConversationSnapshot? {
        guard open() else { return nil }
        var head: (title: String, app: String, created: Date, updated: Date)?
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT title, app_name, created_at, updated_at FROM conversations WHERE id = ?1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, id, -1, transient)
            if sqlite3_step(stmt) == SQLITE_ROW {
                head = (column(stmt, 0), column(stmt, 1),
                        Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                        Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)))
            }
            sqlite3_finalize(stmt)
        }
        guard let head else { return nil }

        var messages: [SavedMessage] = []
        if sqlite3_prepare_v2(db, "SELECT role, text, tool_name, tool_summary FROM messages WHERE conversation_id = ?1 ORDER BY idx", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, id, -1, transient)
            while sqlite3_step(stmt) == SQLITE_ROW {
                messages.append(SavedMessage(
                    role: column(stmt, 0),
                    text: column(stmt, 1),
                    toolName: columnOrNil(stmt, 2),
                    toolSummary: columnOrNil(stmt, 3)
                ))
            }
            sqlite3_finalize(stmt)
        }
        return ConversationSnapshot(id: id, title: head.title, appName: head.app,
                                    createdAt: head.created, updatedAt: head.updated,
                                    messages: messages)
    }

    func delete(id: String) {
        guard open() else { return }
        exec("BEGIN")
        run("DELETE FROM messages WHERE conversation_id = ?1", binds: [.text(id)])
        run("DELETE FROM conversations WHERE id = ?1", binds: [.text(id)])
        exec("COMMIT")
    }

    func deleteAll() {
        guard open() else { return }
        exec("BEGIN")
        exec("DELETE FROM messages")
        exec("DELETE FROM conversations")
        exec("COMMIT")
    }

    // MARK: - Private

    private func open() -> Bool {
        if db != nil { return true }
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            print("[Akari] ConversationStore: can't open \(dbURL.path)")
            if let db { sqlite3_close(db) }
            db = nil
            return false
        }
        exec("PRAGMA journal_mode = WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                app_name TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS messages (
                conversation_id TEXT NOT NULL,
                idx INTEGER NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                tool_name TEXT,
                tool_summary TEXT,
                PRIMARY KEY (conversation_id, idx)
            )
            """)
        return true
    }

    private enum Bind {
        case text(String)
        case int(Int)
        case real(Double)
        case null
    }

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("[Akari] ConversationStore exec failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func run(_ sql: String, binds: [Bind]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[Akari] ConversationStore prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            let pos = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(stmt, pos, s, -1, transient)
            case .int(let v):  sqlite3_bind_int64(stmt, pos, Int64(v))
            case .real(let v): sqlite3_bind_double(stmt, pos, v)
            case .null:        sqlite3_bind_null(stmt, pos)
            }
        }
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("[Akari] ConversationStore step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func column(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }

    private func columnOrNil(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
}
