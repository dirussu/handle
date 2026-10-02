#!/bin/zsh
# Build the downloadable Handle.app and package it as a disk image.
#
#   tools/make_release.sh            → build/Handle-<version>.dmg
#
# The app is signed ad hoc (no Apple Developer account involved), so it is NOT
# notarized: macOS will refuse the first launch until the user allows it in
# System Settings → Privacy & Security (see README → Download).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build
DD="$OUT/DerivedData"
rm -rf "$OUT/Handle.app" "$OUT/dmg" "$DD"
mkdir -p "$OUT"

xcodebuild -project Handle.xcodeproj -scheme Handle -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  build | grep -E "error:|BUILD" || true

APP="$DD/Build/Products/Release/Handle.app"
[ -d "$APP" ] || { echo "build failed: $APP not found" >&2; exit 1; }
cp -R "$APP" "$OUT/Handle.app"
APP="$OUT/Handle.app"

# Re-sign with exactly the app's own entitlements (the build injects a debugging
# entitlement that must not ship), hardened runtime on.
codesign --force --sign - --options runtime --entitlements Handle/Handle.entitlements "$APP"
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$OUT/Handle-$VERSION.dmg"
mkdir -p "$OUT/dmg"
cp -R "$APP" "$OUT/dmg/Handle.app"
ln -s /Applications "$OUT/dmg/Applications"
rm -f "$DMG"
hdiutil create -volname "Handle" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$OUT/dmg"

echo "app:      $APP ($(lipo -archs "$APP/Contents/MacOS/Handle"))"
echo "dmg:      $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "sha256:   $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
