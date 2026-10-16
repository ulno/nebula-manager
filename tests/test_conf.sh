#!/usr/bin/env bash
# Test: nebula-manager.conf path resolution (user-first, least privilege).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="config path resolution"
harness_init

if [[ -f /etc/nebula/nebula-manager.conf ]]; then
    echo "SKIP: /etc/nebula/nebula-manager.conf exists on this host"
    exit 77
fi

export SYSTEM_SERVER_CONF="/nonexistent/nebula-manager.conf"
unset CONF_OVERRIDE

# Default: per-user config -> no root to create/download it.
assert_eq "defaults to per-user config" \
    "$(resolve_server_conf)" "$XDG_CONFIG_HOME/nebula-manager/nebula-manager.conf"
if path_requires_root "$(resolve_server_conf)"; then
    _bad "per-user config path needs no root"
else
    _ok "per-user config path needs no root"
fi

# Explicit override (--config / NEBULA_MANAGER_CONF) always wins.
export CONF_OVERRIDE="$SANDBOX/custom.conf"
assert_eq "explicit override wins" "$(resolve_server_conf)" "$SANDBOX/custom.conf"
unset CONF_OVERRIDE

# An existing system-wide config is preferred over the per-user default.
touch "$SANDBOX/system.conf"
export SYSTEM_SERVER_CONF="$SANDBOX/system.conf"
assert_eq "existing system config preferred" "$(resolve_server_conf)" "$SANDBOX/system.conf"

# --- bundled template: located offline, installed with no network/sudo ---
tpl="$(find_config_template)" || tpl=""
assert_nonempty_file "bundled template located" "$tpl"
assert_contains "template contains [global]" "$(cat "$tpl" 2>/dev/null)" "[global]"

dest="$SANDBOX/created.conf"
install_config_template "$dest" >/dev/null 2>&1
assert_file "config created from local template" "$dest"
assert_contains "created config has [server." "$(cat "$dest")" "[server."
assert_eq "template install used no sudo" "$(sudo_count)" "0"

install_config_template "$dest" >/dev/null 2>&1; rc=$?
assert_eq "refuses to overwrite without --force" "$rc" "1"
install_config_template "$dest" --force >/dev/null 2>&1; rc=$?
assert_eq "overwrites with --force" "$rc" "0"

# --- headless CLI ---
NM="$REPO_ROOT/nebula-manager"
assert_eq "config path prints resolved path" \
    "$("$NM" --config "$SANDBOX/x.conf" config path)" "$SANDBOX/x.conf"
"$NM" config init --config "$SANDBOX/cli.conf" >/dev/null 2>&1
assert_file "config init via CLI (offline)" "$SANDBOX/cli.conf"
assert_contains "CLI-created config has [global]" "$(cat "$SANDBOX/cli.conf")" "[global]"
assert_eq "config init used no sudo" "$(sudo_count)" "0"

harness_summary
