#!/bin/zsh
# Updates the single ./build/KeyChord.app (menu-bar app, no Dock icon), signs and opens it.
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
# Ad-hoc builds reset this app's Accessibility grant so the new code can ask again.
# Certificate-signed builds preserve grants by default. KEYCHORD_RESET_TCC=1 forces
# a reset with either signing identity; KEYCHORD_RESET_TCC=0 preserves grants.
# Set KEYCHORD_LAUNCH=0 to build without opening the app (for packaging or checks).
# KeyChord only needs Accessibility (Input Monitoring is not required).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
SIGN_IDENTITY=${KEYCHORD_SIGN_IDENTITY:--}
RESET_TCC=${KEYCHORD_RESET_TCC:-auto}
LAUNCH=${KEYCHORD_LAUNCH:-1}
case "$RESET_TCC" in
  auto|0|1) ;;
  *) echo "KEYCHORD_RESET_TCC must be auto, 0, or 1." >&2; exit 1 ;;
esac
case "$LAUNCH" in
  0|1) ;;
  *) echo "KEYCHORD_LAUNCH must be 0 or 1." >&2; exit 1 ;;
esac
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)
# Keep the same path and bundle directory. Preview or dated app copies do not belong here.
readonly APP="$PWD/build/KeyChord.app"

swift build -c "$CONFIG" --product KeyChord
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)

# A running copy keeps the old signature, so a grant given now would not apply to the new build.
if pgrep -x KeyChord >/dev/null; then
  echo "Quitting the running KeyChord…"
  pkill -x KeyChord
  for attempt in {1..50}; do
    if ! pgrep -x KeyChord >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -x KeyChord >/dev/null; then
    echo "KeyChord did not quit. Quit it before rebuilding." >&2
    exit 1
  fi
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/KeyChord" "$APP/Contents/MacOS/KeyChord"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/WordLists"
cp Resources/WordLists/README.md Resources/WordLists/COPYING "$APP/Contents/Resources/WordLists/"

codesign --force --options runtime --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Built $APP (AD-HOC signed)."
  echo "To keep grants across builds, set KEYCHORD_SIGN_IDENTITY (see header comment)."
else
  echo "Built $APP (signed with: $SIGN_IDENTITY)"
fi

if [[ "$RESET_TCC" == "1" || ( "$RESET_TCC" == "auto" && "$SIGN_IDENTITY" == "-" ) ]]; then
  if ! tccutil reset Accessibility "$BUNDLE_ID"; then
    echo "Could not reset Accessibility for $BUNDLE_ID. The app was built, but permission renewal failed." >&2
    echo "Run this script from Terminal, or remove KeyChord in System Settings → Privacy & Security → Accessibility and reopen it." >&2
    exit 1
  fi
  echo "Reset Accessibility for $BUNDLE_ID. Allow KeyChord again when prompted."
fi

# Show the resulting designated requirement so you can verify it's stable across builds.
codesign -dr - "$APP" 2>&1

if [[ "$LAUNCH" == "1" ]]; then
  open "$APP"
else
  echo "Launch with: open \"$APP\""
fi
