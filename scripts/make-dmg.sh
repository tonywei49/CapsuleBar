#!/bin/zsh
# Packages build/CapsuleBar.app (universal) into build/CapsuleBar-<version>.dmg with an
# Applications shortcut for drag-to-install.
#
# Release signing + notarization happen automatically when available:
#   - a "Developer ID Application" identity in the keychain (or $DEVELOPER_ID_SIGN_ID)
#   - notarytool credentials stored under $NOTARY_PROFILE (default "capsulebar-notary"):
#       xcrun notarytool store-credentials capsulebar-notary --apple-id <id> --team-id <team>
# Without them the DMG is still built, signed with whatever identity build-app.sh used,
# and not notarized.
#
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
NOTARY_PROFILE="${NOTARY_PROFILE:-capsulebar-notary}"

DEV_ID="${DEVELOPER_ID_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ && !f {print $2; f=1}')}"

[[ -d "$STAGE" ]] && trash "$STAGE"
[[ -f "$DMG" ]] && trash "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/CapsuleBar.app"

if [[ -n "$DEV_ID" ]]; then
  echo "Signing with: $DEV_ID"
  codesign --force --options runtime --timestamp --sign "$DEV_ID" "$STAGE/CapsuleBar.app"
  SIGN_ID="$DEV_ID"
else
  echo "No Developer ID Application identity found: the DMG will not be notarizable."
  SIGN_ID="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !f {print $2; f=1}')"
fi
codesign --verify --strict "$STAGE/CapsuleBar.app"

ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "CapsuleBar $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
trash "$STAGE"

if [[ -n "$SIGN_ID" ]]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
fi

NOTARIZED=no
if [[ -n "$DEV_ID" ]]; then
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Submitting to Apple notary service (profile: $NOTARY_PROFILE)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -vv "$DMG"
    NOTARIZED=yes
  else
    echo "No notarytool credentials under profile '$NOTARY_PROFILE': skipping notarization."
  fi
fi

echo "Built $DMG ($(du -h "$DMG" | cut -f1), archs: $(lipo -archs "$APP/Contents/MacOS/CapsuleBar"), notarized: $NOTARIZED)"
