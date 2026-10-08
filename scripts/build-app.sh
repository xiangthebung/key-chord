#!/bin/zsh
# Updates the single ./build/KeyChord.app (menu-bar app, no Dock icon) and signs it.
#
# macOS checks the app's code-signing requirement when applying Accessibility grants.
# Changed ad-hoc signed code may require the existing app's grant to be renewed.
#
# A stable signing identity gives rebuilds a consistent signing requirement:
#   - Set KEYCHORD_SIGN_IDENTITY to a Keychain code-signing identity, e.g.
#       export KEYCHORD_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"
#     or a self-signed "Code Signing" cert you created in Keychain Access, e.g.
#       export KEYCHORD_SIGN_IDENTITY="KeyChord Self Signed"
#   - If unset, this falls back to ad-hoc (`-`).
#
# This script preserves existing permissions. If the existing Accessibility grant
# needs repair, run explicitly with KEYCHORD_RESET_TCC=1, then grant it again.
# KeyChord only needs Accessibility (Input Monitoring is not required).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
SIGN_IDENTITY=${KEYCHORD_SIGN_IDENTITY:--}
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)
# Keep the same path and bundle directory. Preview or dated app copies do not belong here.
readonly APP="$PWD/build/KeyChord.app"

swift build -c "$CONFIG" --product KeyChord
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)

# A running copy keeps the old signature, so a grant given now would not apply to the new build.
if pgrep -x KeyChord >/dev/null; then
  echo "Quitting the running KeyChord…"
  pkill -x KeyChord || true
  sleep 0.5
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/KeyChord" "$APP/Contents/MacOS/KeyChord"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/WordLists"
cp Resources/WordLists/README.md Resources/WordLists/COPYING "$APP/Contents/Resources/WordLists/"

codesign --force --options runtime --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" "$APP"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Built $APP (AD-HOC signed)."
  if [[ "${KEYCHORD_RESET_TCC:-0}" == "1" ]]; then
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "Reset the Accessibility grant for $BUNDLE_ID. Launch the app and grant it again:"
    echo "  open $APP"
  fi
  echo "To keep grants across builds, set KEYCHORD_SIGN_IDENTITY (see header comment)."
else
  echo "Built $APP (signed with: $SIGN_IDENTITY)"
fi

# Show the resulting designated requirement so you can verify it's stable across builds.
codesign -dr - "$APP" 2>/dev/null || true
