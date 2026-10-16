#!/usr/bin/env bash
# Test: PKI generation + signing works with no root privileges.
# Uses a real nebula-cert when available, in a temporary workspace.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="unprivileged PKI"
harness_init
require_cmd nebula-cert

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"

assert_ne "test process is unprivileged" "$(id -u)" "0"
assert_eq "cert bin resolved to system path" "$(pki_cert_bin)" "$NEBULA_BIN_PATH/nebula-cert"

# --- CA creation (unprivileged) ---
CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create
assert_file "ca.crt created" "$keys/ca.crt"
assert_file "ca.key created" "$keys/ca.key"

# --- Certificate signing (unprivileged) ---
SIGN_NAME="host1" SIGN_IP="10.42.0.2/24" SIGN_GROUPS="servers" CERT_DIR="$keys" pki_sign
assert_file "host1.crt created" "$keys/host1.crt"
assert_file "host1.key created" "$keys/host1.key"

# --- Least privilege: no sudo was needed for user-owned state ---
assert_eq "no sudo used for user-owned PKI" "$(sudo_count)" "0"

# --- The signed cert is real and inspectable ---
out="$("$NEBULA_BIN_PATH/nebula-cert" print -path "$keys/host1.crt" 2>&1)"
assert_contains "signed cert reports name" "$out" "host1"
assert_contains "signed cert reports IP" "$out" "10.42.0.2"

# --- Expiry helper works ---
dl="$(pki_cert_days_left "$keys/host1.crt")"
if [[ "$dl" =~ ^-?[0-9]+$ ]]; then _ok "days-left computed ($dl)"; else _bad "days-left computed" "got [$dl]"; fi

# --- Client bundle ---
CERT_DIR="$keys" pki_bundle_client_zip "host1" "$SANDBOX/out" "$keys" >/dev/null
assert_file "client zip bundle created" "$SANDBOX/out/host1-nebula-bundle.zip"

# --- Removal (unprivileged) ---
pki_remove "host1" "$keys"
assert_no_file "host1.crt removed" "$keys/host1.crt"
assert_no_file "host1.key removed" "$keys/host1.key"
assert_eq "still no sudo used" "$(sudo_count)" "0"

harness_summary
