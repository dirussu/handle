import Foundation

/// App identity + open-source attributions, surfaced in Settings → About.
/// (The standalone About page was removed — its Quit duplicated the ⋯ menu and
/// the brand hero didn't need its own route. The two things worth keeping —
/// the support-relevant version and the license notices the MIT/Apache
/// dependencies legally require Akari to ship — now live in Settings.)
enum AppInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "0.1"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        return short == build ? short : "\(short) (\(build))"
    }

    static var copyrightString: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Dmitrii Russu"
    }

    struct Acknowledgement: Identifiable {
        let id = UUID()
        let name: String
        let license: String
        let url: URL
        init(_ name: String, _ license: String, _ url: String) {
            self.name = name
            self.license = license
            self.url = URL(string: url)!
        }
    }

    /// The bundled open-source libraries, with their license + source. Tapping a
    /// row opens the repo, where the full license text lives. (Bundling the full
    /// texts is the final pre-distribution compliance step.)
    static let acknowledgements: [Acknowledgement] = [
        .init("WhisperKit",          "MIT",        "https://github.com/argmaxinc/WhisperKit"),
        .init("KeyboardShortcuts",   "MIT",        "https://github.com/sindresorhus/KeyboardShortcuts"),
        .init("swift-markdown-ui",   "MIT",        "https://github.com/gonzalezreal/swift-markdown-ui"),
        .init("NetworkImage",        "MIT",        "https://github.com/gonzalezreal/NetworkImage"),
        .init("swift-collections",   "Apache-2.0", "https://github.com/apple/swift-collections"),
    ]
}
