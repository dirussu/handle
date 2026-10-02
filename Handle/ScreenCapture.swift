import AppKit
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case noDisplay
    case noWindow

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No matching SCDisplay for the target NSScreen."
        case .noWindow:  return "The target window is no longer available to capture."
        }
    }
}

/// Lightweight description of one open window — app + title + which display,
/// no pixels. Built from `SCShareableContent`, so it costs a cheap system
/// query, not a screenshot. This is how Handle knows *what's open everywhere*
/// (the "window manifest") without paying a vision turn per window.
struct WindowInfo: Identifiable, Sendable {
    let id: CGWindowID
    let appName: String
    let title: String
    let displayIndex: Int?   // 1-based; nil when there's only one display
}

/// Thin wrapper around ScreenCaptureKit's SCScreenshotManager for one-shot region grabs.
enum ScreenCapture {

    /// Captures a region of `screen` defined in points (top-left origin within the display).
    /// Returns a CGImage at native pixel resolution (Retina-aware).
    static func captureRegion(_ rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let display = content.displays.first { $0.displayID == screenID } ?? content.displays.first

        guard let display else { throw ScreenCaptureError.noDisplay }

        // Never capture Handle's own UI (the notch panel, settings, etc.) —
        // exclude our windows so the shot is the apps *behind* the notch.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == myPID }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        let scale = screen.backingScaleFactor
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.scalesToFit = false
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    /// Enumerate the normal app windows currently open across all displays —
    /// including ones **occluded behind others** (they still have a live
    /// surface). Excludes Handle's own windows, the desktop, menu-bar items,
    /// and tiny utility panels. Minimized windows and windows on inactive
    /// Spaces have no surface, so macOS doesn't list them here (and they
    /// can't be captured without bringing them forward).
    ///
    /// Returns at most `maxCount`, largest-first (a rough "more important"
    /// proxy), so a busy desktop doesn't flood the model's context.
    static func windowManifest(maxCount: Int = 15) async -> [WindowInfo] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        ) else { return [] }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let displays = content.displays

        func displayIndex(for window: SCWindow) -> Int? {
            guard displays.count > 1 else { return nil }
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            return displays.firstIndex { $0.frame.contains(center) }.map { $0 + 1 }
        }

        return content.windows
            .filter { $0.owningApplication?.processID != myPID }   // never Handle itself
            .filter { $0.windowLayer == 0 }                        // normal app windows only
            .filter { ($0.title?.isEmpty == false) }               // skip untitled chrome
            .filter { $0.frame.width > 80 && $0.frame.height > 80 } // skip tiny utility panels
            .sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
            .prefix(maxCount)
            .map {
                WindowInfo(
                    id: $0.windowID,
                    appName: $0.owningApplication?.applicationName ?? "Unknown",
                    title: $0.title ?? "",
                    displayIndex: displayIndex(for: $0)
                )
            }
    }

    /// Capture ONE window by its id — even if it's fully behind other windows
    /// or on an inactive display. Uses `desktopIndependentWindow`, which
    /// renders the window's own surface rather than the screen composite, so
    /// occlusion doesn't matter. Returns a native-resolution CGImage.
    static func captureWindow(id: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw ScreenCaptureError.noWindow
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.scalesToFit = false
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true   // tight crop, no drop shadow

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }
}
