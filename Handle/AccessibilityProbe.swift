import AppKit
import ApplicationServices

/// One UI element extracted from the macOS Accessibility tree.
/// `frame` is in *display top-left coords* (matching captureRect's space).
struct AXElement {
    let role: String          // "AXButton", "AXTextField", …
    let label: String         // Visible label or description
    let frame: CGRect         // top-left display coords, in points (snapshot at capture)
    let value: String?        // For text fields: their current value
    /// Live handle to the element so its CURRENT frame can be re-read at draw time —
    /// the snapshot `frame` goes stale if the window reflows/moves during the
    /// seconds of local inference between capture and highlight.
    var elementRef: AXUIElement? = nil
}

@MainActor
enum AccessibilityProbe {

    /// How a press was delivered — recorded in the audit log so a click is traceable
    /// to its mechanism (semantic AXPress vs synthetic mouse event).
    enum PressResult {
        case axPress            // the element performed its own AXPress action
        case mouseClick         // synthetic click at the element's live center
        case failed(String)

        var label: String {
            switch self {
            case .axPress:          return "AXPress"
            case .mouseClick:       return "synthetic click"
            case .failed(let why):  return "failed: \(why)"
            }
        }
        var succeeded: Bool { if case .failed = self { return false }; return true }
    }

    /// Press an element: prefer its semantic AXPress action (no cursor movement, no
    /// focus games); fall back to a synthetic left-click at the LIVE frame's center
    /// for elements that don't implement AXPress (some Electron/custom controls).
    /// Both spaces are display top-left coords, which is CGEvent's space too.
    static func press(_ el: AXElement) -> PressResult {
        if let ref = el.elementRef {
            var names: CFArray?
            if AXUIElementCopyActionNames(ref, &names) == .success,
               let actions = names as? [String], actions.contains(kAXPressAction as String),
               AXUIElementPerformAction(ref, kAXPressAction as CFString) == .success {
                return .axPress
            }
        }
        let frame = liveFrame(of: el) ?? el.frame
        guard frame.width > 0, frame.height > 0 else { return .failed("element has no frame") }
        let pt = CGPoint(x: frame.midX, y: frame.midY)
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
              let up   = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,   mouseCursorPosition: pt, mouseButton: .left) else {
            return .failed("could not create mouse event")
        }
        down.post(tap: .cghidEventTap)
        usleep(30_000)   // realistic press duration; some apps ignore instant up
        up.post(tap: .cghidEventTap)
        return .mouseClick
    }

    /// Enumerate interactive elements inside the given rect (display top-left coords).
    /// Targets the running app with `bundleID`; falls back to frontmost.
    static func elements(
        in regionRect: CGRect,
        of bundleID: String?,
        limit: Int = 25
    ) -> [AXElement] {
        guard AXIsProcessTrusted() else { return [] }

        let app: NSRunningApplication?
        if let bundleID,
           let match = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app = match
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let pid = app?.processIdentifier else { return [] }

        let appElement = AXUIElementCreateApplication(pid)

        // Coax Chromium/Electron apps (Claude desktop, Slack, VS Code, Discord, …)
        // into exposing their accessibility tree — they keep it OFF until an AT
        // sets this. Native apps ignore it (no side effect). NOTE: Chromium builds
        // the tree lazily, so the FIRST probe right after enabling can still be
        // sparse; a re-capture a moment later picks up the full tree.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused)
        guard status == .success, let raw = focused else { return [] }
        let windowElement = unsafeBitCast(raw, to: AXUIElement.self)

        // Collect generously (well past `limit`) so controls deeper in the tree
        // aren't cut off by tree-order before we've even seen them.
        var collected: [AXElement] = []
        traverse(
            element: windowElement,
            regionRect: regionRect,
            depth: 0,
            maxDepth: 24,   // Electron/Chromium buries real content ~16–18 levels deep (AXWindow → many AXGroups → AXWebArea → …); 14 cut it ALL off → only 2–3 coarse candidates
            collected: &collected,
            limit: max(limit * 4, 80)
        )
        return rankAndDedup(collected, limit: limit)
    }

    /// Dedup (role+label+position), then rank actionable controls ahead of static
    /// text, capped at `limit`. Pure + accessible so the in-app self-test can
    /// exercise it with synthetic elements (no live AX tree needed).
    static func rankAndDedup(_ elements: [AXElement], limit: Int) -> [AXElement] {
        // Finder & co. repeat items (icon + label, multiple columns/views) — dedup
        // by role+label+position so duplicates don't eat candidate slots.
        var seen = Set<String>()
        let deduped = elements.filter {
            seen.insert("\($0.role)|\($0.label)|\(Int($0.frame.minX)),\(Int($0.frame.minY))").inserted
        }
        // Rank actionable controls (buttons, fields, links…) ahead of static text,
        // so a capped list never drops a button in favor of file-name labels.
        // Stable within each tier (preserves reading order).
        let ranked = deduped.enumerated().sorted {
            let pa = pointingPriority($0.element.role), pb = pointingPriority($1.element.role)
            return pa == pb ? $0.offset < $1.offset : pa < pb
        }.map(\.element)
        return Array(ranked.prefix(limit))
    }

    /// Lower = more likely a pointing target. Actionable controls beat static text
    /// so a capped candidate list always keeps the buttons.
    private static func pointingPriority(_ role: String) -> Int {
        switch role {
        case "AXButton", "AXToolbarButton", "AXPopUpButton", "AXMenuButton",
             "AXLink", "AXCheckBox", "AXRadioButton", "AXSwitch",
             "AXTextField", "AXSearchField", "AXSecureTextField", "AXTextArea",
             "AXComboBox", "AXTab", "AXSlider", "AXStepper", "AXDisclosureTriangle":
            return 0
        case "AXStaticText":
            return 2
        default:
            return 1
        }
    }

    /// Force-enable Chromium/Electron accessibility for the app with `pid` (no-op
    /// for native apps). Called proactively on app activation so the tree is BUILT
    /// by the time we capture or hit-test — which is what removes the warm-up.
    static func primeChromiumAccessibility(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                                     "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// The deepest accessible element directly under a screen point, across ANY
    /// app, via a system-wide AX hit-test. This is the precision primitive for
    /// "vision points, AX pins": the model only needs to point roughly INSIDE the
    /// target; this returns its EXACT frame. Returns nil when nothing accessible
    /// is there (custom-drawn UI, some web content) — the vision-box fallback
    /// handles those. `point` is in display top-left coords (AX space).
    static func element(atTopLeftPoint point: CGPoint) -> AXElement? {
        guard AXIsProcessTrusted() else { return nil }
        let sys = AXUIElementCreateSystemWide()
        var elRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(point.x), Float(point.y), &elRef) == .success,
              let el = elRef
        else { return nil }

        // Prime Chromium/Electron a11y on the owning app. The tree builds lazily,
        // so the FIRST hit here usually still returns the coarse web-area box; a
        // SECOND ⌘⌥P (once the tree exists) can reach the real element — IF the app
        // honors this at all. If it never does, that app is vision-fallback.
        var pid: pid_t = 0
        if AXUIElementGetPid(el, &pid) == .success {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                                         "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        guard let frame = frameAttr(el), frame.width > 0, frame.height > 0 else { return nil }
        let role = stringAttr(el, kAXRoleAttribute) ?? ""
        let label = [stringAttr(el, kAXTitleAttribute), stringAttr(el, kAXDescriptionAttribute),
                     stringAttr(el, kAXValueAttribute), stringAttr(el, kAXHelpAttribute)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        return AXElement(role: role, label: label, frame: frame, value: nil, elementRef: el)
    }

    /// The element's CURRENT frame, re-read live (vs the snapshot in `AXElement.frame`).
    /// Use at draw time so a highlight lands where the element is NOW, not where it
    /// was at capture — windows reflow during the seconds of local inference.
    static func liveFrame(of axEl: AXElement) -> CGRect? {
        guard let ref = axEl.elementRef, let f = frameAttr(ref), f.width > 0, f.height > 0 else { return nil }
        return f
    }

    /// DEBUG: the RAW AX tree of `bundleID`'s focused window (or frontmost) — NO
    /// interesting-role / non-empty-label filter — so we can see what an app (esp.
    /// Electron/Chromium) actually exposes. Returns indented "role label frame" lines.
    static func rawTree(of bundleID: String?, maxDepth: Int = 22, limit: Int = 250) -> [String] {
        guard AXIsProcessTrusted() else { return ["(accessibility not trusted)"] }
        let app: NSRunningApplication?
        if let bundleID, let m = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app = m
        } else { app = NSWorkspace.shared.frontmostApplication }
        guard let pid = app?.processIdentifier else { return ["(no pid)"] }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let raw = focused else { return ["(no focused window)"] }
        let window = unsafeBitCast(raw, to: AXUIElement.self)
        var lines: [String] = []
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard lines.count < limit, depth <= maxDepth else { return }
            let role = stringAttr(el, kAXRoleAttribute) ?? "?"
            let label = [stringAttr(el, kAXTitleAttribute), stringAttr(el, kAXDescriptionAttribute),
                         stringAttr(el, kAXValueAttribute)].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
            let fs = frameAttr(el).map { "(\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))×\(Int($0.height)))" } ?? "(no frame)"
            lines.append(String(repeating: "· ", count: depth) + "\(role) \"\(label.prefix(44))\" \(fs)")
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                for k in arr { walk(k, depth + 1) }
            }
        }
        walk(window, 0)
        return lines
    }

    /// Convenience: the accessible element under the current mouse cursor.
    static func elementUnderCursor() -> AXElement? {
        let mouse = NSEvent.mouseLocation                          // global, bottom-left
        guard let primaryH = NSScreen.screens.first?.frame.height else { return nil }
        return element(atTopLeftPoint: CGPoint(x: mouse.x, y: primaryH - mouse.y))   // → top-left (AX space)
    }

    // MARK: - Traversal

    private static func traverse(
        element: AXUIElement,
        regionRect: CGRect,
        depth: Int,
        maxDepth: Int,
        collected: inout [AXElement],
        limit: Int
    ) {
        guard collected.count < limit, depth <= maxDepth else { return }

        if let info = describe(element: element),
           regionRect.intersects(info.frame),
           isInteresting(role: info.role) {
            collected.append(info)
            if collected.count >= limit { return }
        }

        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let array = childrenValue as? [AXUIElement] {
            for child in array {
                if collected.count >= limit { return }
                traverse(
                    element: child,
                    regionRect: regionRect,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    collected: &collected,
                    limit: limit
                )
            }
        }
    }

    /// The frontmost app's focused-window title — the windowMatches trigger's
    /// 5s poll. One AX read; (app, nil) when the window has no title.
    static func frontmostWindowTitle() -> (app: String?, title: String?) {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let raw = focused else { return (app.localizedName, nil) }
        let window = unsafeBitCast(raw, to: AXUIElement.self)
        return (app.localizedName, stringAttr(window, kAXTitleAttribute))
    }

    private static func describe(element: AXUIElement) -> AXElement? {
        let role = stringAttr(element, kAXRoleAttribute) ?? ""
        let title = stringAttr(element, kAXTitleAttribute)
        let description = stringAttr(element, kAXDescriptionAttribute)
        let value = stringAttr(element, kAXValueAttribute)
        let placeholder = stringAttr(element, kAXPlaceholderValueAttribute)
        let help = stringAttr(element, kAXHelpAttribute)

        // Best label we can find. Order matters: title > description > placeholder > value > help.
        let label = [title, description, placeholder, value, help]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""

        guard !label.isEmpty else { return nil }
        guard let frame = frameAttr(element), frame.width > 0, frame.height > 0 else { return nil }
        return AXElement(role: role, label: label, frame: frame, value: value, elementRef: element)
    }

    private static func isInteresting(role: String) -> Bool {
        let interactive: Set<String> = [
            "AXButton", "AXLink", "AXMenuButton", "AXMenuItem",
            "AXCheckBox", "AXRadioButton", "AXPopUpButton",
            "AXSlider", "AXStepper", "AXSwitch",
            "AXTextField", "AXSearchField", "AXSecureTextField", "AXTextArea", "AXComboBox",
            "AXTab", "AXDisclosureTriangle",
            "AXToolbar", "AXToolbarButton",
            "AXIncrementor", "AXLevelIndicator", "AXProgressIndicator",
            "AXStaticText",   // useful for labels and headings near interactive elements
        ]
        return interactive.contains(role)
    }

    // MARK: - Attribute helpers

    private static func stringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    private static func frameAttr(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        let posAX = unsafeBitCast(positionValue!, to: AXValue.self)
        let sizeAX = unsafeBitCast(sizeValue!, to: AXValue.self)

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size)
        else { return nil }

        return CGRect(origin: position, size: size)
    }
}
