#!/bin/zsh
# Build CapsuleBar.app into ./build
# Usage: scripts/build-app.sh [debug|release]   (default: release)
# Signing: uses $CAPSULE_SIGN_ID if set, otherwise the first "Apple Development"
# identity in the keychain (a stable identity keeps the Accessibility grant
# across rebuilds), otherwise ad-hoc.
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG="${1:-release}"
APP="$ROOT/build/CapsuleBar.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CapsuleBar"

if [[ -d "$APP" ]]; then
  trash "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CapsuleBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

SIGN_ID="${CAPSULE_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="-"
fi
codesign --force --options runtime --sign "$SIGN_ID" "$APP"
echo "Built $APP (signed with: $SIGN_ID)"
