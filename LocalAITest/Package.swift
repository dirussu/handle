// swift-tools-version: 6.0
//
// LocalAITest — a tiny Swift command-line tool that runs a local
// vision-language model on a Mac via Apple's MLX framework, used to
// validate Akari's local-AI architecture before committing to a
// production app.
//
// Build:        swift build -c release
// Run:          .build/release/LocalAITest <image-path> "<prompt>"
// Run dev:      swift run LocalAITest <image-path> "<prompt>"
//
// First run will download ~5 GB of model weights into
// `~/Documents/huggingface` (mlx-swift-examples default).

import PackageDescription

let package = Package(
    name: "LocalAITest",
    platforms: [
        // macOS 14+ required for MLX-Swift's Metal-Performance-Shaders
        // Graph features.
        .macOS(.v14),
    ],
    products: [
        .executable(name: "LocalAITest", targets: ["LocalAITest"]),
    ],
    dependencies: [
        // The high-level Swift packages for running local LLMs and VLMs
        // via Apple's MLX framework. This single repo exposes
        // `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `StableDiffusion`, and
        // `MLXEmbedders` products.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-examples",
            from: "2.21.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "LocalAITest",
            dependencies: [
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "MLXVLM", package: "mlx-swift-examples"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
            ]
        ),
    ]
)
