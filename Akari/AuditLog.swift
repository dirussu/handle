import Foundation

/// Persistent, append-only audit trail of every tool Akari runs — the product's
/// headline privacy/safety differentiator (PRODUCT.md §"Audit log & preview-diff":
/// "No consumer Mac AI assistant currently ships this"). One JSON object per line at
/// `~/Library/Application Support/Akari/audit.jsonl`. LOCAL only — like every capture,
/// it never leaves the Mac. An `actor` so file appends serialize off the main thread.
///
/// Each entry: `{ts, tool, args, outcome, summary, confirmed}` where outcome is
/// "ok" | "error" | "declined" and `confirmed` records whether the user approved a
/// card. Read back via `recent(_:)` (for a future Settings inspector).
actor AuditLog {
    static let shared = AuditLog()

    private let url: URL
    private let iso: ISO8601DateFormatter

    private init() {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Akari", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("audit.jsonl")
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        iso = f
    }

    /// Record one tool invocation. `argsJSON` is the raw tool arguments as a JSON
    /// string (Sendable — avoids passing `[String: Any]` across the actor boundary);
    /// it's re-embedded as a nested object so the log stays structured.
    func record(tool: String, argsJSON: String, outcome: String, summary: String, confirmed: Bool) {
        var entry: [String: Any] = [
            "ts": iso.string(from: Date()),
            "tool": tool,
            "outcome": outcome,
            "summary": summary,
            "confirmed": confirmed,
        ]
        if let d = argsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) {
            entry["args"] = obj
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let json = String(data: data, encoding: .utf8) else { return }
        append(json + "\n")
    }

    /// One parsed line (pure).
    nonisolated static func parseLine(_ line: String) -> (ts: String, tool: String, outcome: String, summary: String)? {
        guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tool = o["tool"] as? String else { return nil }
        return (o["ts"] as? String ?? "", tool, o["outcome"] as? String ?? "", o["summary"] as? String ?? "")
    }

    /// The newest finished record per label (one file pass). "started" lines are
    /// skipped so an in-flight run doesn't masquerade as the last result.
    func lastRuns(for labels: Set<String>) -> [String: (ts: String, outcome: String, summary: String)] {
        var out: [String: (ts: String, outcome: String, summary: String)] = [:]
        for line in recent(600).reversed() {
            guard let r = Self.parseLine(line), labels.contains(r.tool), r.outcome != "started", out[r.tool] == nil else { continue }
            out[r.tool] = (r.ts, r.outcome, r.summary)
            if out.count == labels.count { break }
        }
        return out
    }

    /// "09:12" in the user's time zone from an audit `ts`. Pure.
    nonisolated static func localTime(fromISO ts: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: ts) else { return String(ts.dropFirst(11).prefix(5)) }
        return d.formatted(date: .omitted, time: .shortened)
    }

    /// The most recent `limit` raw JSONL lines (newest last).
    func recent(_ limit: Int = 50) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").suffix(limit).map(String.init)
    }

    var fileURL: URL { url }

    // MARK: - Private

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)   // first write — file doesn't exist yet
        }
    }
}
