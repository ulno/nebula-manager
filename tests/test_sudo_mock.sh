#!/usr/bin/env bash
# Test: sudo is invoked ONLY for genuinely privileged target directories.
# The mocked sudo (see helpers.sh) records every invocation in $SUDO_LOG.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="granular sudo via elevate()"
harness_init

if is_root; then echo "SKIP: cannot test non-root behaviour as root"; exit 77; fi

# --- elevate() delegates to sudo for a normal command ---
before="$(sudo_count)"
elevate mkdir -p "$SANDBOX/anything"
assert_eq "elevate() invokes sudo once" "$(( $(sudo_count) - before ))" "1"
assert_contains "sudo recorded the command" "$(cat "$SUDO_LOG")" "mkdir -p $SANDBOX/anything"

# --- elevate() propagates failure with a clear return code ---
SUDO_FAIL=1 elevate true
assert_eq "elevate() surfaces sudo failure" "$?" "1"
unset SUDO_FAIL

# --- ensure_dir() in a user-owned location must NOT use sudo ---
before="$(sudo_count)"
ensure_dir "$SANDBOX/owned/nested"
assert_dir "user-owned dir created" "$SANDBOX/owned/nested"
assert_eq "no sudo for user-owned dir" "$(( $(sudo_count) - before ))" "0"

# --- path_requires_root() classification ---
ro="$SANDBOX/ro"
mkdir -p "$ro"
chmod 500 "$ro"
if path_requires_root "$ro/keys"; then _ok "read-only parent classified as privileged"; else _bad "read-only parent classified as privileged"; fi
if path_requires_root "$SANDBOX/owned/nested"; then _bad "writable path classified as unprivileged"; else _ok "writable path classified as unprivileged"; fi

# --- ensure_dir() for a privileged target DOES use sudo ---
before="$(sudo_count)"
ensure_dir "$ro/keys"
assert_eq "sudo used for privileged dir" "$(( $(sudo_count) - before ))" "1"
assert_contains "recorded privileged mkdir" "$(cat "$SUDO_LOG")" "mkdir -p $ro/keys"

# --- PKI workspace under a privileged parent triggers sudo, not a hard failure ---
before="$(sudo_count)"
CERT_DIR_OVERRIDE="$ro/keys" ensure_cert_dir >/dev/null
assert_eq "privileged cert workspace elevates" "$(( $(sudo_count) - before ))" "1"

harness_summary
