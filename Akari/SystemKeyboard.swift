import AppKit

/// Save / set / restore the user's clipboard around a paste so we don't
/// permanently trample whatever they had copied.
@MainActor
enum ClipboardScratch {
    /// Returns the previous string contents (if any) so a caller can restore.
    @discardableResult
    static func setString(_ s: String) -> String? {
        let pb = NSPasteboard.general
        let prior = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(s, forType: .string)
        return prior
    }

    static func restore(_ value: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let value { pb.setString(value, forType: .string) }
    }
}
