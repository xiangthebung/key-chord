#!/bin/zsh
# Runs the KeyChordCore test suite (Swift Testing).
# With only the Command Line Tools installed, the Testing framework is not on the
# default search paths, so add them explicitly. With full Xcode this is harmless.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=$(xcode-select -p)
if [[ -d "$DEV/Library/Developer/Frameworks" ]]; then
  F="$DEV/Library/Developer/Frameworks"          # Command Line Tools layout
  L="$DEV/Library/Developer/usr/lib"
else
  F="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"   # Xcode layout
  L="$DEV/Platforms/MacOSX.platform/Developer/usr/lib"
fi

exec swift test \
  -Xswiftc -F -Xswiftc "$F" \
  -Xlinker -F -Xlinker "$F" \
  -Xlinker -rpath -Xlinker "$F" \
  -Xlinker -rpath -Xlinker "$L" \
  "$@"
