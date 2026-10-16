#!/usr/bin/env bash
# Test: certificate workspace selection / "already known" detection.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="certificate workspace selection"
harness_init

# --- nothing configured -> not known (so the TUI will prompt) ---
if nebula_keys_known; then _bad "unknown by default"; else _ok "unknown by default"; fi

# --- explicit --cert-dir / env -> known (never prompt) ---
export CERT_DIR_OVERRIDE="$SANDBOX/x"
if nebula_keys_known; then _ok "--cert-dir -> known"; else _bad "--cert-dir -> known"; fi
unset CERT_DIR_OVERRIDE
export NEBULA_KEYS_DIR="$SANDBOX/y"
if nebula_keys_known; then _ok "NEBULA_KEYS_DIR -> known"; else _bad "NEBULA_KEYS_DIR -> known"; fi
unset NEBULA_KEYS_DIR

# --- saved interactive selection -> known ---
save_cert_dir_selection "$SANDBOX/saved"
if nebula_keys_known; then _ok "saved selection -> known"; else _bad "saved selection -> known"; fi
rm -f "$(nebula_keys_state_file)"

# --- an existing user store (~/keys/nebula) is offered as a candidate ---
mkdir -p "$HOME/keys/nebula"
: > "$HOME/keys/nebula/ca.crt"
assert_contains "candidate ~/keys/nebula detected" "$(workspace_candidates)" "$HOME/keys/nebula"

# --- populated legacy server cert dir -> known ---
export NEBULA_DIR="$SANDBOX/srv"
mkdir -p "$NEBULA_DIR/certs"
: > "$NEBULA_DIR/certs/node.crt"
if nebula_keys_known; then _ok "legacy server certs -> known"; else _bad "legacy server certs -> known"; fi
unset NEBULA_DIR

harness_summary
