#!/usr/bin/env bash
# Test: the certificate-workspace selector.
# Regression: a path typed at the numbered menu used to be silently rejected
# (only a menu number worked), so users could not select their real store.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="certificate workspace selector"
harness_init
export NEBULA_UI=plain
export MENU_PATH="Main Menu"

# A store that exists on disk should be offered as a detected store.
mkdir -p "$HOME/keys/nebula"
: > "$HOME/keys/nebula/ca.crt"

# --- detected store is listed ---
out="$(printf '\n' | select_cert_workspace 2>&1)"
assert_contains "lists the detected store" "$out" "Use detected store: $HOME/keys/nebula"
assert_contains "lists the custom option"  "$out" "Enter a custom path"

# --- choose the detected store by number ---
# (menu order: 1 current, 2 detected store, 3 default, 4 server, 5 custom)
out="$(printf '2\n' | select_cert_workspace 2>&1)"
assert_eq "detected store selected by number" "$(load_cert_dir_selection)" "$HOME/keys/nebula"

# --- 'custom path' prompt still works (number 5) ---
out="$(printf '5\n%s/custom1\n' "$SANDBOX" | select_cert_workspace 2>&1)"
assert_eq "custom path via prompt saved" "$(load_cert_dir_selection)" "$SANDBOX/custom1"

# --- typing a directory directly at the menu is accepted ---
out="$(printf '%s/typed-ok\n' "$SANDBOX" | select_cert_workspace 2>&1)"
assert_eq "typed path accepted" "$(load_cert_dir_selection)" "$SANDBOX/typed-ok"
assert_contains "reports the change"   "$out" "workspace set to:"
assert_dir      "typed workspace created" "$SANDBOX/typed-ok"

# --- invalid input is reported and re-prompts; a valid answer then wins ---
out="$(printf 'bogus\n%s/after-retry\n' "$SANDBOX" | select_cert_workspace 2>&1)"
assert_contains "invalid input is reported" "$out" "Invalid choice"
assert_eq "re-prompt then succeeds" "$(load_cert_dir_selection)" "$SANDBOX/after-retry"

# --- EOF/cancel leaves the selection untouched ---
before="$(load_cert_dir_selection)"
printf '' | select_cert_workspace >/dev/null 2>&1
assert_eq "EOF leaves selection unchanged" "$(load_cert_dir_selection)" "$before"

# --- tilde in a typed path is expanded ---
export HOME="$SANDBOX/home2"; mkdir -p "$HOME"
printf '~/mystore\n' | select_cert_workspace >/dev/null 2>&1
assert_eq "tilde is expanded" "$(load_cert_dir_selection)" "$SANDBOX/home2/mystore"

# --- warning when an env override would win ---
export NEBULA_KEYS_DIR="$SANDBOX/envstore"
out="$(printf '1\n' | select_cert_workspace 2>&1)"
assert_contains "warns about env override" "$out" "overrides this saved selection"

harness_summary
