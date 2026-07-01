#!/usr/bin/env bash
#
# Build (if needed) and run the LocalAITest CLI.
#
# Usage:
#   ./run.sh <image-path> "<prompt>"
#
# Why this script exists:
#   `swift build` does NOT compile MLX's Metal shaders. We MUST use
#   `xcodebuild` so the `mlx-swift_Cmlx.bundle/Contents/Resources/
#   default.metallib` is produced and co-located with the binary.
#   This is documented in mlx-swift's README ("SwiftPM (command line)
#   cannot build the Metal shaders so the ultimate build has to be
#   done via Xcode").
#
#   First-time setup also requires:
#     xcodebuild -downloadComponent MetalToolchain
#   (Xcode 26+ split the Metal toolchain into a downloadable component.)

set -euo pipefail

cd "$(dirname "$0")"

BIN="./xcbuild/Build/Products/Release/LocalAITest"

# Build only if the binary doesn't exist or the source is newer.
if [[ ! -x "$BIN" ]] || [[ "Sources/LocalAITest/main.swift" -nt "$BIN" ]]; then
    echo "→ Building via xcodebuild (Metal shaders need it)…"
    xcodebuild \
        -scheme LocalAITest \
        -derivedDataPath ./xcbuild \
        -configuration Release \
        -destination 'platform=macOS' \
        build \
        | tail -3
fi

echo
"$BIN" "$@"
