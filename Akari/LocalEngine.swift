import Foundation
import Combine
import CoreGraphics
import CoreImage
import MLX
import MLXLMCommon
import MLXVLM
import Hub
import Tokenizers
import OSLog

private let log = Logger(subsystem: "com.dimarussu.Akari", category: "LocalEngine")

/// Akari's on-device AI engine. Loads local MLX models once and keeps
/// them resident for the lifetime of the app (unlike the eval CLI, which
/// reloaded per invocation). Replaces the former cloud ClaudeClient —
/// nothing this engine does leaves the user's Mac.
///
/// v1.5 / M1 scope: the **vision path only** — image + prompt → streamed
/// text ("explain my screen"). No tool-use / agent loop yet; that's M3,
/// where the local model's tool-calling is designed deliberately.
///
/// Proven against `LocalAITest`. Carries the workarounds we discovered
/// for mlx-swift-examples 2.29.1:
///   • build chat input via `UserInput(chat:)`, never the
///     `init(prompt:images:)` convenience init (which silently drops the
///     image because Swift `didSet` doesn't fire during `init`)
///   • downscale images ≤ `maxImageEdge` (attention is O(n²) in image
///     tokens; uncapped Retina shots are ~5× slower)
///   • the VLM closure-based `generate(...)` works (it's the plain-LLM
///     path that needs the AsyncStream variant — relevant in M3)
@MainActor
final class LocalEngine: ObservableObject {
    static let shared = LocalEngine()
    private init() {}

    // MARK: - Configuration

    /// Vision-language model. Qwen 2.5 VL 7B 4-bit (~5 GB on disk).
    /// Stable MLX support; swap to Qwen 3 VL when its upstream
    /// tied-embedding crash is fixed.
    private let visionModelID = "mlx-community/Qwen2.5-VL-7B-Instruct-4bit"

    /// Cap the longest image edge before inference. 1568 matches
    /// Anthropic's API default and is the accuracy/speed knee we'll tune.
    private let maxImageEdge: CGFloat = 1568

    private let generation = GenerateParameters(maxTokens: 512, temperature: 0.6, topP: 0.9)

    // MARK: - Load state (observable, for onboarding / status UI)

    enum LoadState: Equatable {
        case notLoaded
        case downloading(Double)   // 0...1
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var visionState: LoadState = .notLoaded

    /// The resident vision model. Loaded lazily on first use, then kept.
    private var visionContainer: ModelContainer?
    /// Guards against two concurrent loads racing.
    private var visionLoadTask: Task<ModelContainer, Error>?

    // MARK: - Model loading

    /// Ensure the vision model is downloaded and loaded, returning the
    /// resident container. Idempotent and concurrency-safe: simultaneous
    /// callers await the same in-flight load.
    func ensureVisionModel() async throws -> ModelContainer {
        if let container = visionContainer { return container }
        if let task = visionLoadTask { return try await task.value }

        // Keep MLX's GPU cache modest so we share memory politely with
        // the rest of the user's Mac.
        MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)

        let task = Task { () throws -> ModelContainer in
            self.visionState = .downloading(0)
            log.info("Loading vision model \(self.visionModelID, privacy: .public)…")

            let configuration = ModelConfiguration(id: visionModelID)
            let container = try await VLMModelFactory.shared.loadContainer(
                hub: HubApi(),
                configuration: configuration
            ) { progress in
                Task { @MainActor in
                    self.visionState = .downloading(progress.fractionCompleted)
                }
            }

            self.visionState = .ready
            self.visionContainer = container
            log.info("Vision model ready.")
            return container
        }
        visionLoadTask = task

        do {
            return try await task.value
        } catch {
            visionState = .failed(error.localizedDescription)
            visionLoadTask = nil
            log.error("Vision model load failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Generation

    /// A prior turn for the text chat path.
    struct ChatTurn {
        enum Role { case user, assistant }
        let role: Role
        let text: String
    }

    /// **See** — stream a description/answer about an image. Yields text
    /// deltas as the model generates; the image is downscaled first.
    func explain(image: CGImage, prompt: String) -> AsyncThrowingStream<String, Error> {
        // Build via init(chat:) — the convenience init(prompt:images:)
        // drops the image (didSet trap in mlx-swift-examples 2.29.1).
        let input = UserInput(chat: [.user(prompt, images: [downscaledImage(image)])])
        return generateStream(input)
    }

    /// **Ask** — stream a reply to a text-only conversation, routed through
    /// the *same* resident VL model (no extra model loaded; Ask stays in the
    /// same engine as See). Carries prior turns so it reads as a real
    /// conversation, not isolated one-shots.
    func chat(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let turns: [Chat.Message] = history.map { turn in
            switch turn.role {
            case .user:      return .user(turn.text)
            case .assistant: return .assistant(turn.text)
            }
        }
        return generateStream(UserInput(chat: turns))
    }

    /// Shared streaming generate for both See and Ask. Yields only the new
    /// suffix each tick (whole-string redraw breaks on multi-line text).
    private func generateStream(_ userInput: UserInput) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let container = try await ensureVisionModel()
                    let printed = StreamAccumulator()

                    _ = try await container.perform { context in
                        let input = try await context.processor.prepare(input: userInput)
                        return try MLXLMCommon.generate(
                            input: input,
                            parameters: self.generation,
                            context: context
                        ) { tokens in
                            let full = context.tokenizer.decode(tokens: tokens)
                            if full.count > printed.value.count {
                                let delta = String(full.dropFirst(printed.value.count))
                                printed.value = full
                                continuation.yield(delta)
                            }
                            return .more
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Image preprocessing

    /// Downscale so the longest edge ≤ `maxImageEdge`. Returns a
    /// `UserInput.Image` ready to attach to a chat message.
    private func downscaledImage(_ image: CGImage) -> UserInput.Image {
        let ci = CIImage(cgImage: image)
        let longest = max(ci.extent.width, ci.extent.height)
        guard maxImageEdge > 0, longest > maxImageEdge else {
            return .ciImage(ci)
        }
        let scale = maxImageEdge / longest
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        log.debug("Downscaled image \(Int(ci.extent.width))×\(Int(ci.extent.height)) → \(Int(scaled.extent.width))×\(Int(scaled.extent.height))")
        return .ciImage(scaled)
    }
}

/// Reference box for the streaming callback's accumulated text. The
/// callback runs off the main actor (MLX picks the thread), so we keep
/// the mutable string here rather than capturing a `var`.
private final class StreamAccumulator: @unchecked Sendable {
    var value: String = ""
}
