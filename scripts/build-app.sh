#!/bin/zsh
# Builds KeyChord.app (menu-bar app, no Dock icon) into ./build and signs it.
#
# macOS ties Accessibility / Input Monitoring grants to the app's CODE SIGNATURE
# identity (its cdhash-derived designated requirement), not to the bundle ID or path.
# An ad-hoc signature (`--sign -`) changes on every build, so every rebuild looks like
# a brand-new app to TCC and your previously granted permission silently stops working
# (the toggle still shows "enabled" but points at the old, dead signature).
#
# Fix: sign with a STABLE identity so the signature is identical across rebuilds.
#   - Set KEYCHORD_SIGN_IDENTITY to a Keychain code-signing identity, e.g.
#       export KEYCHORD_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"
#     or a self-signed "Code Signing" cert you created in Keychain Access, e.g.
#       export KEYCHORD_SIGN_IDENTITY="KeyChord Self Signed"
#   - If unset, this falls back to ad-hoc (`-`), and you WILL have to re-grant each build.
#
# With ad-hoc signing this script resets KeyChord's Accessibility record after each build,
# because the old grant can only point at the previous build. Launch the new app and
# click "Open Accessibility Settings": KeyChord is added to the list, switch it on.
# KeyChord only needs Accessibility (Input Monitoring is not required).
# Set KEYCHORD_KEEP_TCC=1 to skip the reset.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
SIGN_IDENTITY=${KEYCHORD_SIGN_IDENTITY:--}
BUNDLE_ID=dev.keychord.KeyChord

swift build -c "$CONFIG" --product KeyChord
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)

# A running copy keeps the old signature, so a grant given now would not apply to the new build.
if pgrep -x KeyChord >/dev/null; then
  echo "Quitting the running KeyChord…"
  pkill -x KeyChord || true
  sleep 0.5
fi

APP=build/KeyChord.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/KeyChord" "$APP/Contents/MacOS/KeyChord"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --options runtime --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" "$APP"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Built $APP (AD-HOC signed)."
  if [[ "${KEYCHORD_KEEP_TCC:-0}" != "1" ]]; then
    # The previous grant belongs to the previous cdhash; clear it so macOS asks again cleanly.
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
