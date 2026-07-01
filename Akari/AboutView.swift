import SwiftUI
import AppKit

/// About content with no window chrome, so it renders as a page inside the
/// notch. `onDone` returns to the chat page; Quit always terminates.
struct AboutBody: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: AkariSpacing.l) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 88, height: 88)
            }

            VStack(spacing: AkariSpacing.xs) {
                // Hero — `Akari` is the only display-sized text on this screen.
                Text("Akari")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Lights up what you point at.")
                    .font(.akariBody)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 2) {
                Text("Version \(Self.versionString)")
                    .font(.akariCaption)
                    .foregroundStyle(.secondary)
                Text(Self.copyrightString)
                    .font(.akariCaption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: AkariSpacing.m) {
                Button("Quit Akari") { NSApp.terminate(nil) }
                    .buttonStyle(.akariSolid)

                Button("Done", action: onDone)
                    .buttonStyle(.akariSolidProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AkariSpacing.l)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "0.1"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        return short == build ? short : "\(short) (\(build))"
    }

    private static var copyrightString: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Dmitrii Russu"
    }
}
