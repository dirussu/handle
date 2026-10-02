import SwiftUI
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// An optional chord for capturing the screen, as an alternative to double-tapping ⌥.
    static let triggerCapture = Self("triggerCapture")
}

/// A settings section header — a small icon tile + title, replacing the weak
/// default grouped-form header so the page is scannable at a glance. White-only
/// (DESIGN.md): the hierarchy comes from the tile + type, never colour.
struct SettingsHeader: View {
    let icon: String
    let title: String
    var body: some View {
        HStack(spacing: HandleSpacing.s) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, alignment: .center)
            Text(title)
                .font(.handleSection)
                .foregroundStyle(.white)
                .textCase(nil)
        }
        .padding(.bottom, 2)
    }
}

/// A small centered empty-state — dimmed icon + title + hint — matching the
/// Chats page hero, scaled for a Form section. Replaces the bare gray "No X yet"
/// lines so an empty section reads as designed, not unfinished.
struct SettingsEmptyState: View {
    let icon: String
    let title: String
    let hint: String
    var body: some View {
        VStack(spacing: HandleSpacing.s) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white.opacity(0.22))
            Text(title)
                .font(.handleSection)
                .foregroundStyle(.white.opacity(0.9))
            Text(hint)
                .font(.handleCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HandleSpacing.l)
    }
}

/// The settings content (the Form), with no window/panel chrome — so it can
/// render as a page inside the notch. The notch page wraps it with a header.
/// Section order is a deliberate narrative: how you drive it → what it does on
/// its own → what it knows / can touch → privacy + data → advanced.
struct SettingsBody: View {
    var body: some View {
        Form {
            AISection()
            SentSection()
            SeeSection()
            TasksSection()

            Section {
                LabeledContent("Capture") {
                    Text("Double-tap ⌥")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Talk") {
                    Text("Hold ⌥")
                        .foregroundStyle(.secondary)
                }
                KeyboardShortcuts.Recorder("Capture screen (chord):", name: .triggerCapture)
            } header: {
                SettingsHeader(icon: "keyboard", title: "Hotkeys")
            } footer: {
                Text("Speech is transcribed on-device — nothing audible leaves your Mac. Holding ⌥ cancels the instant you press another key, so ⌥-shortcuts keep working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AutomationsSection()
            ActivitySection()
            MemorySection()
            WorkspaceSection()
            PermissionsSection()
            StorageSection()
            CustomizeSection()
            ToolTrustSection()
            PowerUserSection()
            IntegrationsSection()   // advanced territory (a deliberate choice) — lives with Power User
            AboutSection()
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)   // kill the thick AppKit scroller — uniform with the rest
    }
}
