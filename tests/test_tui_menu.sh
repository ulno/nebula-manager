#!/usr/bin/env bash
# Test: the entrypoint's Setup/bootstrap TUI menu wiring.
# The entrypoint is *sourced* here (its main() is guarded) so we can inspect the
# menu it builds without starting the interactive flow.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="entrypoint Setup menu"
harness_init
export SYSTEM_SERVER_CONF="/nonexistent/nebula-manager.conf"
export NEBULA_NO_PROMPT=1
unset CONF_OVERRIDE

# shellcheck source=/dev/null
source "$REPO_ROOT/nebula-manager"

# --- item lists ---
_setup_menu_build 0
assert_eq "setup menu: 9 items" "${#_SETUP_FNS[@]}" "9"
assert_eq "setup menu: last action reloads" "${_SETUP_FNS[8]}" "tui_reload_request"
assert_eq "setup menu: offers browse" "$(printf '%s\n' "${_SETUP_FNS[@]}" | grep -c '^config_browse_tui$')" "1"
assert_eq "setup menu: offers delete" "$(printf '%s\n' "${_SETUP_FNS[@]}" | grep -c '^config_delete_tui$')" "1"
assert_eq "setup menu: offers import first" "${_SETUP_FNS[0]}" "import_run"
assert_eq "setup menu: offers client bundle import" "${_SETUP_FNS[1]}" "import_bundle_tui"
assert_contains "setup menu: labels the bundle import" "${_SETUP_OPTS[1]}" "Import client bundle"

_setup_menu_build 1
assert_eq "bootstrap menu: adds Exit (10 items)" "${#_SETUP_FNS[@]}" "10"
assert_eq "bootstrap menu: last action exits" "${_SETUP_FNS[9]}" "exit"

# --- refresh hook supplies the detected-state prompt ---
conf="$XDG_CONFIG_HOME/nebula-manager/nebula-manager.conf"
mkdir -p "$(dirname "$conf")"
printf '[global]\nbin_path=/usr/bin\n[server.a]\nenabled=true\n[server.b]\nenabled=false\n' > "$conf"
SETUP_MENU_BOOTSTRAP=1
_setup_menu_refresh
assert_contains "refresh prompt shows the config"      "$DYNAMIC_MENU_PROMPT" "Manager config: $conf"
assert_contains "refresh prompt counts enabled instances" "$DYNAMIC_MENU_PROMPT" "1 instance(s) enabled"
assert_contains "refresh prompt shows the cert store"   "$DYNAMIC_MENU_PROMPT" "Certificates:"
unset SETUP_MENU_BOOTSTRAP

# --- config_delete_tui guard: nothing to delete -> clean no-op, no sudo ---
unset CONF_OVERRIDE
_setup_menu_build 0
: > "$SUDO_LOG"
CONF_OVERRIDE="$SANDBOX/nope.conf"
config_delete_tui >/dev/null 2>&1; rc=$?
assert_eq "delete with no config is a clean no-op" "$rc" "0"
assert_eq "delete with no config used no sudo" "$(sudo_count)" "0"

# --- instance context block above the main menu -----------------------------
export NEBULA_DIR="$SANDBOX/nebula-dir"
mkdir -p "$NEBULA_DIR"; : > "$NEBULA_DIR/config.yml"
export SERVER_NAME="edge-a"
export NEBULA_SERVICE="/etc/systemd/system/nebula-edge.service"
out="$(instance_context_summary)"
assert_contains "context names the instance + service" "$out" "Instance: edge-a (nebula-edge.service)"
assert_contains "context names the Nebula config"      "$out" "Nebula config: $NEBULA_DIR/config.yml"
assert_contains "context names the cert store"         "$out" "Certificates:"
assert_contains "context names the manager config"     "$out" "Manager config:"

instance_context_refresh
assert_contains "context refresh sets the menu prompt" "$DYNAMIC_MENU_PROMPT" "Instance: edge-a"

# --- Option C menu labels ---------------------------------------------------
# Stub the dispatcher and the pre-flight probes so main_menu() only builds its
# label/action arrays; capture the labels for inspection.
capture_menu_labels() {
    local -n _labels="$2"
    printf '%s\n' "${_labels[@]}" > "$SANDBOX/main_labels.txt"
}
check_nebula_installed() { return 0; }
check_nebula_service()  { return 0; }
dynamic_menu() { capture_menu_labels "$@"; }
main_menu
labels="$(cat "$SANDBOX/main_labels.txt")"
assert_contains "main menu: Instances entry"          "$labels" "Instances"
assert_contains "main menu: Instance Settings entry"  "$labels" "Instance Settings"
assert_contains "main menu: Manager Setup entry"      "$labels" "Manager Setup"
assert_contains "main menu: Updates & Install entry"  "$labels" "Updates & Install"
assert_not_contains "main menu: no legacy Servers item" "$labels" "Servers"
assert_not_contains "main menu: no legacy Maintenance item" "$labels" "Maintenance"

harness_summary
