#!/bin/zsh
# Native local-input regression checks: isolated defaults, hidden windows, local events only.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product KeyChord
KEYCHORD_INPUT_BIN_DIR=$(swift build --show-bin-path)
KEYCHORD_INPUT_TEMP_DIR=$(mktemp -d /tmp/keychord-input-checks.XXXXXX)
trap 'rm -rf "$KEYCHORD_INPUT_TEMP_DIR"' EXIT
KEYCHORD_INPUT_SOURCES=(Sources/KeyChord/*.swift)
KEYCHORD_INPUT_SOURCES=(${KEYCHORD_INPUT_SOURCES:#Sources/KeyChord/main.swift})
swiftc -I "$KEYCHORD_INPUT_BIN_DIR/Modules" "$KEYCHORD_INPUT_BIN_DIR"/KeyChordCore.build/*.o \
  "${KEYCHORD_INPUT_SOURCES[@]}" Tests/KeyChordInputChecks/main.swift \
  -framework AppKit -framework Carbon -framework ApplicationServices -framework WebKit -framework AVFoundation \
  -o "$KEYCHORD_INPUT_TEMP_DIR/checks"
"$KEYCHORD_INPUT_TEMP_DIR/checks"
