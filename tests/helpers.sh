#!/usr/bin/env bash
# shellcheck shell=bash
#
# tests/helpers.sh - tiny, dependency-free test harness + mocks
# -------------------------------------------------------------
# Provides: sandbox setup, a mocked `sudo` that records every invocation,
# assertion helpers and a per-file summary. Sourced by tests/test_*.sh.
#
# The mocked sudo is what lets us prove least-privilege behaviour: tests
# assert that $SUDO_LOG is empty for unprivileged work and non-empty only
# when a genuinely privileged directory is targeted.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

PASS=0
FAIL=0

# ---- assertion helpers -----------------------------------------------------
_ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
_bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; }

assert_eq()       { local d="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] && _ok "$d" || _bad "$d" "expected [$w] got [$g]"; }
assert_ne()       { local d="$1" g="$2" w="$3"; [[ "$g" != "$w" ]] && _ok "$d" || _bad "$d" "did not expect [$w]"; }
assert_contains() { local d="$1" hay="$2" needle="$3"; [[ "$hay" == *"$needle"* ]] && _ok "$d" || _bad "$d" "expected to contain [$needle]; got [$hay]"; }
assert_not_contains() { local d="$1" hay="$2" needle="$3"; [[ "$hay" != *"$needle"* ]] && _ok "$d" || _bad "$d" "did not expect [$needle]"; }
assert_file()     { local d="$1" f="$2"; [[ -f "$f" ]] && _ok "$d" || _bad "$d" "missing file: $f"; }
assert_dir()      { local d="$1" f="$2"; [[ -d "$f" ]] && _ok "$d" || _bad "$d" "missing dir: $f"; }
assert_no_file()  { local d="$1" f="$2"; [[ ! -e "$f" ]] && _ok "$d" || _bad "$d" "unexpected path: $f"; }
assert_empty_file()    { local d="$1" f="$2"; [[ ! -s "$f" ]] && _ok "$d" || _bad "$d" "expected empty: $f"; }
assert_nonempty_file() { local d="$1" f="$2"; [[ -s "$f" ]] && _ok "$d" || _bad "$d" "expected non-empty: $f"; }

# ---- environment -----------------------------------------------------------
harness_init() {
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export HOME="$SANDBOX/home"
    export XDG_DATA_HOME="$SANDBOX/xdg-data"
    export XDG_CONFIG_HOME="$SANDBOX/xdg-config"
    mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$SANDBOX/bin"

    # Mocked sudo: records invocations, never performs real privileged work.
    export SUDO_LOG="$SANDBOX/sudo.log"
    : > "$SUDO_LOG"
    cat > "$SANDBOX/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
# Pretend there are no cached credentials for -n probes, so elevate() prints its
# reason/command notice; don't record probes as real invocations.
if [[ "${1:-}" == "-n" ]]; then exit 1; fi
printf 'sudo %s\n' "$*" >> "${SUDO_LOG:?SUDO_LOG not set}"
if [[ "${SUDO_FAIL:-0}" == "1" ]]; then
    echo "sudo: mock failure" >&2
    exit 1
fi
exit 0
MOCK
    chmod +x "$SANDBOX/bin/sudo"
    export PATH="$SANDBOX/bin:$PATH"

    # Clean slate for directory-resolution tests.
    unset CERT_DIR_OVERRIDE NEBULA_KEYS_DIR CERT_DIR_SELECTED NEBULA_DIR NEBULA_CERT_FOLDER 2>/dev/null || true

    # Quiet, deterministic, non-interactive UI.
    export USE_COLOR=false USE_ICONS=false NEBULA_UI=plain

    # Point NEBULA_BIN_PATH at a real nebula-cert if we can find one.
    local cert_bin
    cert_bin="$(command -v nebula-cert 2>/dev/null || true)"
    [[ -n "$cert_bin" ]] && export NEBULA_BIN_PATH="$(dirname "$cert_bin")"

    # Load the modules under test (same shell so we can call functions).
    # MANAGER_LIB_DIR simulates the installed layout so template/config helpers work.
    export MANAGER_LIB_DIR="$REPO_ROOT/lib"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/ui.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/system.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/pki.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/bench.sh"

    trap 'rm -rf "$SANDBOX"' EXIT
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "SKIP: required command '$1' not found"; exit 77; }
}

# number of recorded sudo invocations
sudo_count() { [[ -s "$SUDO_LOG" ]] && wc -l < "$SUDO_LOG" | tr -d ' ' || echo 0; }

harness_summary() {
    printf '\n%s: %d passed, %d failed\n' "${TEST_LABEL:-$(basename "${BASH_SOURCE[1]}")}" "$PASS" "$FAIL"
    [[ "$FAIL" -eq 0 ]]
}
