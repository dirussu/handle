import Foundation

/// Where on-device models live — since phase 5 that is only the WhisperKit voice
/// model (`SpeechService`). Relocatable from Settings → Voice model storage.
enum ModelStorage {
    private static let baseKey = "handle.models.base"

    /// Where downloads have always landed (swift-transformers' default).
    static var defaultBase: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
         ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    /// The active base — the user's relocated choice, or the default.
    static var base: URL {
        if let path = UserDefaults.standard.string(forKey: baseKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultBase
    }

    /// Human-readable size of everything under the base ("" while empty).
    static func sizeDescription() -> String {
        guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey]) else { return "" }
        var bytes: Int64 = 0
        for case let url as URL in files {
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Move the whole model folder to `destination/huggingface` and switch the
    /// loaders there. Throws with a readable message; on failure nothing is
    /// switched. A LOADED model keeps running from memory — the new location
    /// takes effect on next load (caller says so in the UI).
    static func relocate(toFolder destination: URL) throws {
        let target = destination.appendingPathComponent("huggingface", isDirectory: true)
        let source = base
        guard target.path != source.path else { return }
        if FileManager.default.fileExists(atPath: target.path) {
            throw NSError(domain: "Handle", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(target.path) already exists — pick an empty destination."])
        }
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: target)
        } else {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        UserDefaults.standard.set(target.path, forKey: baseKey)
    }
}
