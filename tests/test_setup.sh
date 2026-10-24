#!/usr/bin/env bash
# Test: Setup-menu state detection & config adoption (least privilege).
# Verifies that nebula-manager reflects *detected* state (its own config, enabled
# servers, cert workspace) and can adopt/delete a config without sudo when it is
# user-owned.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="setup state & config adoption"
harness_init
export SYSTEM_SERVER_CONF="/nonexistent/nebula-manager.conf"
export NEBULA_NO_PROMPT=1
unset CONF_OVERRIDE

# --- no config yet: summary says so and still reports the cert store ---
out="$(setup_state_summary)"
assert_contains "summary reports missing config" "$out" "Manager config: none yet"
assert_contains "summary reports a cert store"   "$out" "Certificates:"

# --- manager conf with 2 enabled / 1 disabled server ---
conf="$XDG_CONFIG_HOME/nebula-manager/nebula-manager.conf"
mkdir -p "$(dirname "$conf")"
printf '[global]\nbin_path=/usr/local/bin\n[server.a]\ndir=/etc/nebula\nenabled=true\n[server.b]\nenabled=true\n[server.c]\nenabled=false\n' > "$conf"

assert_eq "counts only enabled servers" "$(_conf_count_enabled "$conf")" "2"
out="$(setup_state_summary)"
assert_contains "summary shows config path"    "$out" "Manager config: $conf"
assert_contains "summary shows enabled count"  "$out" "2 instance(s) enabled"

# --- a Nebula config.yml is not a manager conf ---
printf 'pki:\n  ca: ca.crt\nlisten:\n  port: 4545\n' > "$SANDBOX/nebula.yml"
assert_eq "count is 0 for a Nebula config.yml" "$(_conf_count_enabled "$SANDBOX/nebula.yml")" "0"

# --- config_use_file: adopt a valid manager conf, reject Nebula's config.yml ---
unset CONF_OVERRIDE
config_use_file "$conf" >/dev/null 2>&1; rc=$?
assert_eq "adopts a manager conf" "$rc" "0"
assert_eq "adoption sets CONF_OVERRIDE" "$CONF_OVERRIDE" "$conf"
assert_eq "adoption sets SERVER_CONF"   "$SERVER_CONF" "$conf"

unset CONF_OVERRIDE
config_use_file "$SANDBOX/nebula.yml" >/dev/null 2>&1; rc=$?
assert_eq "rejects Nebula config.yml" "$rc" "1"
assert_eq "rejected file not adopted" "${CONF_OVERRIDE:-}" ""

unset CONF_OVERRIDE
config_use_file "$SANDBOX/does-not-exist.conf" >/dev/null 2>&1; rc=$?
assert_eq "rejects a missing file" "$rc" "1"

# --- config_remove_cli --force deletes a user-owned config without sudo ---
del="$SANDBOX/removeme.conf"
printf '[global]\n[server.x]\nenabled=true\n' > "$del"
CONF_OVERRIDE="$del"
config_remove_cli --force >/dev/null 2>&1; rc=$?
assert_eq "config remove --force succeeds" "$rc" "0"
assert_no_file "config file removed" "$del"
assert_eq "config remove used no sudo for a user path" "$(sudo_count)" "0"
unset CONF_OVERRIDE

# --- deleting a privileged config DOES elevate (mock sudo), and only then ---
# Point at a path that path_requires_root() classifies as privileged.
priv="/etc/nebula/nebula-manager.conf.test"
CONF_OVERRIDE="$priv"
: > "$SUDO_LOG"
# Nothing to remove (file absent) -> warns, no sudo.
config_remove_cli --force >/dev/null 2>&1
assert_eq "no sudo when there is nothing to delete" "$(sudo_count)" "0"
unset CONF_OVERRIDE

# --- service path resolution (bare unit name must not write to CWD) ---
NEBULA_SERVICE="nebula.service"
assert_eq "bare unit name -> /etc/systemd/system" "$(resolve_service_path)" "/etc/systemd/system/nebula.service"
NEBULA_SERVICE="/etc/systemd/system/nebula-test.service"
assert_eq "absolute unit path preserved" "$(resolve_service_path)" "/etc/systemd/system/nebula-test.service"
unset NEBULA_SERVICE

harness_summary
