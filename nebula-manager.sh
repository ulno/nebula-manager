#!/usr/bin/env bash
#
# nebula-manager.sh - backwards-compatibility entrypoint.
# =======================================================
# The monolithic script was refactored into the extension-less `nebula-manager`
# entrypoint plus the modules under lib/ (ui.sh, pki.sh, bench.sh, system.sh).
#
# This shim keeps the historical filename working when run from a checkout of
# the repository. It re-execs the real entrypoint, which itself resolves its
# modules relative to its own location.
#
# NOTE: the modular tool needs lib/ next to the entrypoint. For a standalone
# install, fetch BOTH `nebula-manager` and the `lib/` directory (see README.md)
# or reuse the in-app "Install Script to System" maintenance action.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

if [[ -x "$here/nebula-manager" ]]; then
    exec "$here/nebula-manager" "$@"
fi

echo "nebula-manager.sh: cannot find the 'nebula-manager' entrypoint in $here" >&2
echo "This script was split into 'nebula-manager' + lib/*.sh - see README.md." >&2
exit 1
