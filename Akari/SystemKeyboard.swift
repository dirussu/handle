import AppKit

/// Helpers for synthesizing keystrokes into the foreground app.
@MainActor
enum SystemKeyboard {
    /// Send ⌘V to the frontmost app via System Events (AppleScript).
    /// Requires Automation permission for System Events on first use; macOS prompts.
    /// Returns true on success, false on failure (and prints the error).
    @discardableResult
    static func sendCommandV() -> Bool {
        let script = """
        tell application "System Events"
            keystroke "v" using {command down}
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            print("[Akari] SystemKeyboard: failed to compile AppleScript")
            return false
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            print("[Akari] SystemKeyboard ⌘V error: \(error)")
            return false
        }
        return true
    }
}

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
