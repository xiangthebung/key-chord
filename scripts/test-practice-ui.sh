#!/bin/zsh
# Regression checks for the actual AppKit typing-practice progress and chord edits.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product KeyChord
KEYCHORD_UI_BIN_DIR=$(swift build --show-bin-path)
KEYCHORD_UI_TEMP_DIR=$(mktemp -d /tmp/keychord-ui-checks.XXXXXX)
trap 'rm -rf "$KEYCHORD_UI_TEMP_DIR"' EXIT
KEYCHORD_UI_SOURCES=(Sources/KeyChord/*.swift)
KEYCHORD_UI_SOURCES=(${KEYCHORD_UI_SOURCES:#Sources/KeyChord/main.swift})
swiftc -I "$KEYCHORD_UI_BIN_DIR/Modules" "$KEYCHORD_UI_BIN_DIR"/KeyChordCore.build/*.o \
  "${KEYCHORD_UI_SOURCES[@]}" Tests/KeyChordUIChecks/main.swift \
  -framework AppKit -framework Carbon -framework ApplicationServices -framework WebKit -framework AVFoundation \
  -o "$KEYCHORD_UI_TEMP_DIR/checks"
"$KEYCHORD_UI_TEMP_DIR/checks"
