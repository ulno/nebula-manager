#!/usr/bin/env bash
# Test: [server.*] management (add / list / remove / enable / disable).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="server.* management"
harness_init

NM="$REPO_ROOT/nebula-manager"
CONF="$SANDBOX/nebula-manager.conf"

# --- add creates the config and both sections ---
"$NM" --config "$CONF" server add alpha --dir /etc/nebula --service nebula.service --role client >/dev/null 2>&1
"$NM" --config "$CONF" server add beta --dir /etc/nebula-b --service nebula-b.service --role lighthouse --host b.example:4545 >/dev/null 2>&1
assert_file "config created" "$CONF"
assert_contains "global header" "$(cat "$CONF")" "[global]"
assert_contains "alpha section" "$(cat "$CONF")" "[server.alpha]"
assert_contains "beta section" "$(cat "$CONF")" "[server.beta]"
assert_contains "role stored" "$(cat "$CONF")" "role=lighthouse"
assert_contains "host stored" "$(cat "$CONF")" "host=b.example:4545"

# --- list ---
out="$("$NM" --config "$CONF" server list 2>&1)"
assert_contains "list shows alpha" "$out" "alpha"
assert_contains "list shows beta" "$out" "beta"
assert_contains "list shows dir" "$out" "/etc/nebula-b"

# --- re-add updates in place (no duplicate section) ---
"$NM" --config "$CONF" server add beta --dir /etc/nebula-b --service nebula-b.service --disabled >/dev/null 2>&1
assert_eq "no duplicate section" "$(grep -cF '[server.beta]' "$CONF")" "1"
assert_contains "beta disabled after re-add" "$(cat "$CONF")" "enabled=false"

# --- enable / disable ---
"$NM" --config "$CONF" server enable beta >/dev/null 2>&1
assert_contains "beta enabled" "$(cat "$CONF")" "enabled=true"
"$NM" --config "$CONF" server disable alpha >/dev/null 2>&1
assert_contains "alpha disabled" "$(cat "$CONF")" "enabled=false"

# --- remove ---
"$NM" --config "$CONF" server remove alpha >/dev/null 2>&1
assert_not_contains "alpha removed" "$(cat "$CONF")" "[server.alpha]"
assert_contains "beta survives" "$(cat "$CONF")" "[server.beta]"

# --- usage / error codes ---
"$NM" server add >/dev/null 2>&1; rc=$?
assert_eq "server add without name exits 2" "$rc" "2"
"$NM" --config "$CONF" server remove nope >/dev/null 2>&1; rc=$?
assert_eq "remove of missing server exits 1" "$rc" "1"

# --- least privilege ---
assert_eq "server edits used no sudo" "$(sudo_count)" "0"

harness_summary
