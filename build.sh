#!/usr/bin/env bash
# Builds MacMeet with SwiftPM and wraps it in a signed .app bundle.
# Usage: ./build.sh [--open]
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MacMeet"
APP="build/${APP_NAME}.app"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Version: YYYY-MM-DD.NNN, where NNN counts the builds made that day (2026-11-19.005 is the fifth
# build on November 19, 2026). .build-number holds the date and count of the last build. macOS
# expects CFBundleVersion to be numeric, so it gets the same version as 20261119.5.
TODAY="$(date +%Y-%m-%d)"
BUILD_NUMBER=1
if [[ -f .build-number ]]; then
  read -r LAST_DATE LAST_NUMBER < .build-number
  if [[ "$LAST_DATE" == "$TODAY" ]]; then
    BUILD_NUMBER=$((10#$LAST_NUMBER + 1))
  fi
fi
echo "$TODAY $BUILD_NUMBER" > .build-number
VERSION="$(printf '%s.%03d' "$TODAY" "$BUILD_NUMBER")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${TODAY//-/}.$BUILD_NUMBER" "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# Sign with the hardened runtime; the entitlements let it use the camera and mic. The local
# certificate (scripts/make-signing-cert.sh) keeps the signature stable across builds, so macOS
# keeps the app's camera, microphone, and Screen Recording permissions. Without it, fall back to
# an ad-hoc signature, which macOS treats as a new app after every build.
SIGNING_IDENTITY="MacMeet Local Signing"
SIGNING_KEYCHAIN="$PWD/.signing/MacMeet.keychain-db"
SIGN_ARGS=()
if [[ -f "$SIGNING_KEYCHAIN" ]]; then
  security unlock-keychain -p macmeet "$SIGNING_KEYCHAIN"
  # codesign only finds identities in keychains on the search list, so add the project keychain
  # just for the signing step and restore the original list afterward.
  ORIGINAL_KEYCHAINS=()
  while IFS= read -r keychain; do
    ORIGINAL_KEYCHAINS+=("$(echo "$keychain" | xargs)")
  done < <(security list-keychains -d user)
  trap 'security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"' EXIT
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$SIGNING_KEYCHAIN"
  SIGN_WITH="$SIGNING_IDENTITY"
  SIGN_ARGS=(--keychain "$SIGNING_KEYCHAIN")
else
  echo "warning: $SIGNING_KEYCHAIN not found; signing ad-hoc. Run scripts/make-signing-cert.sh." >&2
  SIGN_WITH="-"
fi
codesign --force --sign "$SIGN_WITH" "${SIGN_ARGS[@]}" --options runtime \
  --entitlements Resources/MacMeet.entitlements "$APP"

echo "Built $APP $VERSION (signed with: $SIGN_WITH)"

if [[ "${1:-}" == "--open" ]]; then
  open "$APP"
fi
