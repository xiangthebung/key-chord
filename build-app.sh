#!/bin/zsh
# Repository-root entry point; keep the build implementation in scripts/.
set -euo pipefail
exec "${0:A:h}/scripts/build-app.sh" "$@"
