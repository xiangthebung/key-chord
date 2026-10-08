#!/bin/zsh
# Native onboarding regression checks: isolated defaults, hidden windows, local events only.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product KeyChord
KEYCHORD_ONBOARDING_BIN_DIR=$(swift build --show-bin-path)
KEYCHORD_ONBOARDING_TEMP_DIR=$(mktemp -d /tmp/keychord-onboarding-checks.XXXXXX)
trap 'rm -rf "$KEYCHORD_ONBOARDING_TEMP_DIR"' EXIT
KEYCHORD_ONBOARDING_SOURCES=(Sources/KeyChord/*.swift)
KEYCHORD_ONBOARDING_SOURCES=(${KEYCHORD_ONBOARDING_SOURCES:#Sources/KeyChord/main.swift})
swiftc -I "$KEYCHORD_ONBOARDING_BIN_DIR/Modules" "$KEYCHORD_ONBOARDING_BIN_DIR"/KeyChordCore.build/*.o \
  "${KEYCHORD_ONBOARDING_SOURCES[@]}" Tests/KeyChordOnboardingChecks/main.swift \
  -framework AppKit -framework Carbon -framework ApplicationServices -framework WebKit -framework AVFoundation \
  -o "$KEYCHORD_ONBOARDING_TEMP_DIR/checks"
"$KEYCHORD_ONBOARDING_TEMP_DIR/checks"
