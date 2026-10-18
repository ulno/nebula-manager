#!/usr/bin/env bash
# Test: CLI argument parsing, flag precedence and headless subcommands.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="CLI parsing & headless commands"
harness_init

NM="$REPO_ROOT/nebula-manager"

# --- version / help ---
assert_contains "--version prints version" "$("$NM" --version)" "Nebula Manager v"
assert_contains "--help prints usage"     "$("$NM" --help)"    "Usage:"

# --- paths subcommand (also exercises directory resolution through the entry) ---
out="$("$NM" paths)"
assert_contains "default config path is per-user" "$out" "config:    $XDG_CONFIG_HOME/nebula-manager/nebula-manager.conf"
assert_contains "default cert dir is per-user" "$out" "cert-dir:  $XDG_DATA_HOME/nebula-manager/keys"
assert_eq "paths needs no sudo" "$(sudo_count)" "0"

out="$("$NM" --cert-dir="$SANDBOX/cli" paths)"
assert_contains "--cert-dir override parsed" "$out" "cert-dir:  $SANDBOX/cli"

out="$("$NM" paths --cert-dir="$SANDBOX/cli2")"
assert_contains "--cert-dir parsed after command" "$out" "cert-dir:  $SANDBOX/cli2"

out="$("$NM" --config="$SANDBOX/my.conf" paths)"
assert_contains "--config override parsed" "$out" "config:    $SANDBOX/my.conf"

out="$(NEBULA_MANAGER_CONF="$SANDBOX/env.conf" "$NM" paths)"
assert_contains "NEBULA_MANAGER_CONF honoured" "$out" "config:    $SANDBOX/env.conf"

out="$(NEBULA_KEYS_DIR="$SANDBOX/env" "$NM" paths)"
assert_contains "NEBULA_KEYS_DIR honoured via entry" "$out" "cert-dir:  $SANDBOX/env"

out="$(NEBULA_KEYS_DIR="$SANDBOX/env" "$NM" --cert-dir="$SANDBOX/cli" paths)"
assert_contains "cli --cert-dir beats env at entry level" "$out" "cert-dir:  $SANDBOX/cli"

out="$("$NM" paths)"
assert_contains "screen clearing is off by default" "$out" "clear-screen: 0"
out="$("$NM" --clear-screen paths)"
assert_contains "--clear-screen is parsed" "$out" "clear-screen: 1"
out="$(NEBULA_CLEAR_SCREEN=1 "$NM" --no-clear-screen paths)"
assert_contains "--no-clear-screen wins" "$out" "clear-screen: 0"

# --- argument validation ---
err="$("$NM" sign 2>&1)"; rc=$?
assert_eq "sign without args exits 2" "$rc" "2"
assert_contains "sign prints usage" "$err" "Usage:"

err="$("$NM" ca 2>&1)"; rc=$?
assert_eq "ca without --name exits 2" "$rc" "2"

err="$("$NM" frobnicate 2>&1)"; rc=$?
assert_eq "unknown command exits 2" "$rc" "2"

# --- end-to-end unprivileged PKI through the CLI ---
require_cmd nebula-cert
d="$SANDBOX/e2e"
"$NM" ca --name e2e-ca --cert-dir "$d" >/dev/null 2>&1
assert_file "CLI created CA cert" "$d/ca.crt"
assert_file "CLI created CA key"  "$d/ca.key"

"$NM" sign --cert-dir "$d" --name node1 --ip 10.7.7.7/24 --groups servers >/dev/null 2>&1
assert_file "CLI signed node1.crt" "$d/node1.crt"
assert_file "CLI signed node1.key" "$d/node1.key"

assert_eq "CLI PKI needed no sudo" "$(sudo_count)" "0"

out="$("$NM" --cert-dir "$d" cert list 2>/dev/null)"
assert_contains "cert list shows node1" "$out" "node1"

harness_summary
