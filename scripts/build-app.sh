#!/bin/zsh
# Build CapsuleBar.app into ./build
# Usage: scripts/build-app.sh [debug|release]   (default: release)
# Signing: uses $CAPSULE_SIGN_ID if set, otherwise a "Developer ID Application" or
# "Apple Development" identity from the keychain (a stable identity keeps the
# Accessibility grant across rebuilds), otherwise ad-hoc.
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG="${1:-release}"
APP="$ROOT/build/CapsuleBar.app"

cd "$ROOT"
# Universal binary (Apple silicon + Intel) by default; CAPSULE_ARCHS="arm64" for a faster local build.
ARCH_FLAGS=()
for arch in ${=CAPSULE_ARCHS:-arm64 x86_64}; do ARCH_FLAGS+=(--arch "$arch"); done
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/CapsuleBar"

if [[ -d "$APP" ]]; then
  trash "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CapsuleBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Prefer Developer ID (same identity as releases, so permissions survive updates), then
# Apple Development, then ad-hoc.
SIGN_ID="${CAPSULE_SIGN_ID:-}"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
for kind in "Developer ID Application" "Apple Development"; do
  [[ -n "$SIGN_ID" ]] && break
  SIGN_ID="$(print -r -- "$IDENTITIES" | awk -F'"' -v k="$kind" 'index($0, k) && !f {print $2; f=1}')"
done
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="-"
fi
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
echo "Built $APP (signed with: $SIGN_ID)"
