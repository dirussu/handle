import Foundation

/// Server-sent events (the streaming format both Anthropic and OpenAI use).
/// Pure line-fed parser (self-tested) + an async wrapper over URLSession bytes.
nonisolated struct SSEEvent: Equatable, Sendable {
    var event: String?
    var data: String
}

nonisolated struct SSEParser {
    private var event: String?
    private var dataLines: [String] = []

    /// Feed one line (without its trailing newline). Returns a completed event
    /// when the line is the blank separator, else nil.
    mutating func feed(line rawLine: String) -> SSEEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { event = nil; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return SSEEvent(event: event, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }                      // comment / keep-alive
        let (field, value): (String, String)
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            var v = line[line.index(after: colon)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            value = String(v)
        } else {
            field = line; value = ""
        }
        switch field {
        case "event": event = value
        case "data": dataLines.append(value)
        default: break                                              // id / retry: unused
        }
        return nil
    }

    /// Flush a trailing event that had no blank line after it (EOF).
    mutating func finish() -> SSEEvent? { feed(line: "") }

    /// Convenience for tests: parse a whole payload. Splits on the LF *byte* —
    /// Swift treats "\r\n" as one Character, so a Character split misses CRLF.
    static func parse(_ text: String) -> [SSEEvent] {
        var p = SSEParser(); var out: [SSEEvent] = []
        for line in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            if let e = p.feed(line: String(decoding: line, as: UTF8.self)) { out.append(e) }
        }
        if let e = p.finish() { out.append(e) }
        return out
    }
}

nonisolated extension SSEParser {
    /// Events from a live byte stream. Cancelling the consumer cancels the read.
    /// Lines are split on LF bytes by hand: `AsyncBytes.lines` also breaks on
    /// U+2028/U+2029/NEL, which can legally appear raw inside JSON `data:`
    /// payloads and would split an event mid-JSON.
    static func events(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                var buffer: [UInt8] = []
                do {
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte == UInt8(ascii: "\n") {
                            if let e = parser.feed(line: String(decoding: buffer, as: UTF8.self)) { continuation.yield(e) }
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty, let e = parser.feed(line: String(decoding: buffer, as: UTF8.self)) { continuation.yield(e) }
                    if let e = parser.finish() { continuation.yield(e) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
