#!/usr/bin/env bash
# Assembles build/Gallery.app from the SwiftPM build so the sandboxed app can be produced and
# launched without Xcode (xcodebuild is blocked until `sudo xcode-select -s` is run).
# Rebuilds after this should be done through Gallery.xcodeproj so the code-signing identity, and
# therefore the TCC folder-access grant, stays stable across builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/Gallery.app"

# A malformed Info.plist makes codesign fall back to the executable name as the code-signing
# identifier; the app then traps in _libsecinit_appsandbox at launch with no useful stderr, so
# check the plists before signing anything.
plutil -lint "$ROOT/App/Info.plist" "$ROOT/App/Gallery.entitlements" >/dev/null

BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"
swift build --package-path "$ROOT" -c "$CONFIG" --product Gallery

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Gallery" "$APP/Contents/MacOS/Gallery"
chmod +x "$APP/Contents/MacOS/Gallery"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
# The Finder service's port name is the app's own name. Keeping it as a literal would silently break the
# service the day the bundle is renamed, so the build fills it in from CFBundleName.
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP/Contents/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :NSServices:0:NSPortName $APP_NAME" "$APP/Contents/Info.plist"
cp "$ROOT/App/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign the binary first, then the bundle, both with the same entitlements.
#
# Identity matters more than it looks: the sandbox stores a folder grant inside a security-scoped bookmark,
# and macOS ties that bookmark to the app's signing identity. An ad-hoc signature (`-`) is a *new* identity
# on every build, so every rebuild silently revokes access to every folder the user picked until they pick
# it again. A real certificate's designated requirement survives rebuilds, so prefer one when the machine
# has it and fall back to ad-hoc only when there is nothing to sign with.
IDENTITY="${GALLERY_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -v CSSMERR \
    | awk '/Apple Development/ {print $2; exit}')"
  IDENTITY="${IDENTITY:--}"
fi
echo "signing with $IDENTITY"
codesign --force --sign "$IDENTITY" \
  --entitlements "$ROOT/App/Gallery.entitlements" \
  --timestamp=none \
  "$APP/Contents/MacOS/Gallery"
codesign --force --sign "$IDENTITY" \
  --entitlements "$ROOT/App/Gallery.entitlements" \
  --timestamp=none \
  "$APP"

# Make Finder's Open With and Services see this build immediately instead of waiting for a launch.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "built  $APP"
echo "sandbox entitlement present:"
codesign -d --entitlements - "$APP" 2>&1 | grep -c "app-sandbox" || true
