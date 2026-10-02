#!/bin/zsh
# Build + run the cloud adapter probe with Xcode's swiftc (needs Swift 6.2+ for
# `nonisolated` types). See tools/cloudprobe/main.swift.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/handle-cloudprobe"
SWIFTC="${SWIFTC:-$(xcrun -f swiftc)}"
SDK="${SDK:-$(xcrun --show-sdk-path --sdk macosx)}"
"$SWIFTC" -O -sdk "$SDK" -target arm64-apple-macos14.0 -o "$OUT" \
  "$HERE"/Handle/AI/AIProvider.swift "$HERE"/Handle/AI/SSE.swift \
  "$HERE"/Handle/AI/AnthropicProvider.swift "$HERE"/Handle/AI/OpenAIProvider.swift "$HERE"/Handle/AI/SecretStore.swift \
  "$HERE"/tools/cloudprobe/main.swift
exec "$OUT" "$@"
