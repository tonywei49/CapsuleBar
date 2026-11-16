#!/bin/zsh
# Packages build/CapsuleBar.app (universal) into build/CapsuleBar-<version>.dmg with an
# Applications shortcut for drag-to-install.
# Usage: scripts/make-dmg.sh            (builds the app first)
#        SKIP_BUILD=1 scripts/make-dmg.sh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

if [[ -z "${SKIP_BUILD:-}" ]]; then
  scripts/build-app.sh release
fi

APP="$ROOT/build/CapsuleBar.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/CapsuleBar-$VERSION.dmg"
STAGE="$ROOT/build/dmg-stage"

[[ -d "$STAGE" ]] && trash "$STAGE"
[[ -f "$DMG" ]] && trash "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/CapsuleBar.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "CapsuleBar $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
trash "$STAGE"

# Sign the image with the same identity as the app when one is available.
SIGN_ID="${CAPSULE_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')}"
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --sign "$SIGN_ID" "$DMG"
fi

echo "Built $DMG ($(du -h "$DMG" | cut -f1), archs: $(lipo -archs "$APP/Contents/MacOS/CapsuleBar"))"
