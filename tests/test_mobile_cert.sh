#!/usr/bin/env bash
# Test: mobile certificates — sign a device-generated public key and emit a QR.
# The device keeps its private key; nebula-manager must NOT write a .key.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="mobile cert (in-pub + qr)"
harness_init
require_cmd nebula-cert

keys="$SANDBOX/keys"
mkdir -p "$keys"
export CERT_DIR_OVERRIDE="$keys"
CA_NAME="TestMeshCA" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1

# The mobile app generates the keypair on-device and exports only the public key.
nebula-cert keygen -out-key "$SANDBOX/device.key" -out-pub "$SANDBOX/device.pub" >/dev/null 2>&1
assert_file "device public key generated" "$SANDBOX/device.pub"

# --- pki_sign with SIGN_IN_PUB + SIGN_QR ---
CERT_DIR="$keys" SIGN_NAME="phone.mesh.demo" SIGN_IP="10.100.0.9/24" \
    SIGN_GROUPS="mobile" SIGN_IN_PUB="$SANDBOX/device.pub" SIGN_QR="$SANDBOX/phone.png" \
    pki_sign >/dev/null 2>&1; rc=$?
assert_eq "in-pub signing succeeds" "$rc" "0"
assert_file "certificate written" "$keys/phone.mesh.demo.crt"
assert_no_file "no private key written for in-pub" "$keys/phone.mesh.demo.key"
assert_nonempty_file "QR code written" "$SANDBOX/phone.png"
assert_eq "in-pub signing used no sudo" "$(sudo_count)" "0"

out="$(nebula-cert print -path "$keys/phone.mesh.demo.crt" 2>&1)"
assert_contains "certificate carries the overlay IP" "$out" "10.100.0.9"
assert_contains "certificate carries the mobile group" "$out" "mobile"

# --- CLI: --in-pub + --qr, with name/IP suggestions ---
exp_ip="$(suggest_next_cert_ip "$keys")"
out="$("$REPO_ROOT/nebula-manager" sign --cert-dir "$keys" \
        --in-pub "$SANDBOX/device.pub" --qr "$SANDBOX/cli.png" 2>&1)"; rc=$?
assert_eq "CLI in-pub signing succeeds" "$rc" "0"
assert_contains "CLI used the suggested IP" "$out" "$exp_ip"
exp_name="$(suggest_cert_name "$keys")"
assert_file "CLI certificate written" "$keys/$exp_name.crt"
assert_no_file "CLI wrote no key for in-pub" "$keys/$exp_name.key"
assert_nonempty_file "CLI QR written" "$SANDBOX/cli.png"

# --- missing public key is a clean error ---
out="$("$REPO_ROOT/nebula-manager" sign --cert-dir "$keys" \
        --in-pub "$SANDBOX/nope.pub" --name nope --ip 10.100.0.50/24 2>&1)"; rc=$?
assert_ne "missing public key fails" "$rc" "0"
assert_contains "missing public key explained" "$out" "not found"

# --- TUI mobile flow (plain mode): name, mobile?=y, pubkey, IP, groups,
#     subnets=n, duration=default, qr=default ---
tui_name="tui-phone.mesh.demo"
printf '%s\ny\n%s\n10.100.0.77/24\nmobile\nn\n\n\n' "$tui_name" "$SANDBOX/device.pub" \
    | generate_nebula_cert >/dev/null 2>&1
assert_file "TUI mobile certificate written" "$keys/$tui_name.crt"
assert_no_file "TUI mobile wrote no key" "$keys/$tui_name.key"
assert_nonempty_file "TUI mobile QR written at default path" "$keys/$tui_name.png"

harness_summary
