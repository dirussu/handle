#!/bin/zsh
# Build + run the cloud adapter probe with Xcode's swiftc (needs Swift 6.2+ for
# `nonisolated` types). See tools/cloudprobe/main.swift.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/akari-cloudprobe"
SWIFTC="${SWIFTC:-$(xcrun -f swiftc)}"
SDK="${SDK:-$(xcrun --show-sdk-path --sdk macosx)}"
"$SWIFTC" -O -sdk "$SDK" -target arm64-apple-macos14.0 -o "$OUT" \
  "$HERE"/Akari/AI/AIProvider.swift "$HERE"/Akari/AI/SSE.swift \
  "$HERE"/Akari/AI/AnthropicProvider.swift "$HERE"/Akari/AI/OpenAIProvider.swift "$HERE"/Akari/AI/SecretStore.swift \
  "$HERE"/tools/cloudprobe/main.swift
exec "$OUT" "$@"
