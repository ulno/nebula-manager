#!/usr/bin/env bash
# Test: importing a client bundle from Setup / `import --bundle`.
# Covers extraction, validation, rebasing config paths, manager.conf creation,
# overwrite protection/backups, dry-run, the TUI wrapper, and the CLI.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="client bundle import"
harness_init
require_cmd nebula-cert
require_cmd tar

# --- build a real bundle ----------------------------------------------------
PKI="$SANDBOX/pki"
mkdir -p "$PKI"
CERT_DIR="$PKI" CA_NAME="bundle-ca" pki_ca_create >/dev/null
CERT_DIR="$PKI" SIGN_NAME="client1" SIGN_IP="10.80.0.2/24" SIGN_GROUPS="clients" pki_sign >/dev/null

SRC="$SANDBOX/bundle-src"
mkdir -p "$SRC"
cp "$PKI/ca.crt" "$PKI/client1.crt" "$PKI/client1.key" "$SRC/"
cat > "$SRC/config.yml.template" <<'YAML'
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/client1.crt
  key: /etc/nebula/client1.key

listen:
  host: 0.0.0.0
  port: 0
YAML
chmod 600 "$SRC/client1.key"
ARCHIVE="$SANDBOX/client1.tar.gz"
tar -czf "$ARCHIVE" -C "$SRC" ca.crt client1.crt client1.key config.yml.template

# --- function import into a user-owned directory ---------------------------
CONF="$SANDBOX/manager.conf"
TARGET="$SANDBOX/target"
export CONF_OVERRIDE="$CONF" IMPORT_YES=1 IMPORT_FORCE=0 IMPORT_BUNDLE_DRY_RUN=0
out="$(import_bundle_run "$ARCHIVE" "$TARGET" 2>&1)"; rc=$?
assert_eq "bundle import succeeds" "$rc" "0"
assert_file "CA installed" "$TARGET/ca.crt"
assert_file "client cert installed" "$TARGET/client1.crt"
assert_file "client key installed" "$TARGET/client1.key"
assert_file "config.yml installed" "$TARGET/config.yml"
cfg="$(cat "$TARGET/config.yml")"
assert_contains "config paths are rebased to the target" "$cfg" "cert: $TARGET/client1.crt"
assert_contains "config keeps the listen section" "$cfg" "listen:"
mc="$(cat "$CONF")"
assert_contains "manager.conf gets a server entry" "$mc" "[server.client1]"
assert_contains "manager.conf points at the target" "$mc" "dir=$TARGET"
assert_contains "manager.conf sets the certificate workspace" "$mc" "cert_dir=$TARGET"
assert_contains "manager.conf marks the role" "$mc" "role=client"
assert_eq "user-owned import used no sudo" "$(sudo_count)" "0"

# --- overwrite protection and backup ---------------------------------------
export IMPORT_YES=1 IMPORT_FORCE=0
out="$(import_bundle_run "$ARCHIVE" "$TARGET" 2>&1)"; rc=$?
assert_eq "refuses to overwrite config.yml without --force" "$rc" "1"
assert_contains "overwrite refusal is explained" "$out" "Refusing to overwrite"

export IMPORT_FORCE=1
out="$(import_bundle_run "$ARCHIVE" "$TARGET" 2>&1)"; rc=$?
assert_eq "forced re-import succeeds" "$rc" "0"
assert_eq "existing config was backed up" "$(ls "$TARGET"/config.yml.bak.* 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "user-owned re-import used no sudo" "$(sudo_count)" "0"

# --- dry run ----------------------------------------------------------------
DRY_TARGET="$SANDBOX/dry-target"
export IMPORT_FORCE=0 IMPORT_BUNDLE_DRY_RUN=1
out="$(import_bundle_run "$ARCHIVE" "$DRY_TARGET" 2>&1)"; rc=$?
assert_eq "dry run succeeds" "$rc" "0"
assert_no_file "dry run writes nothing" "$DRY_TARGET"
assert_contains "dry run says so" "$out" "Dry run: nothing written"
export IMPORT_BUNDLE_DRY_RUN=0

# --- malformed bundle -------------------------------------------------------
BAD="$SANDBOX/bad"
mkdir -p "$BAD"
printf 'not a bundle\n' > "$BAD/readme.txt"
tar -czf "$SANDBOX/bad.tar.gz" -C "$BAD" readme.txt
out="$(import_bundle_run "$SANDBOX/bad.tar.gz" "$SANDBOX/bad-target" 2>&1)"; rc=$?
assert_eq "malformed bundle fails" "$rc" "1"
assert_contains "malformed bundle is explained" "$out" "does not look like a nebula-manager client bundle"

# --- target selection menu --------------------------------------------------
out="$(printf '\n' | _bundle_target_menu 2>/dev/null)"
assert_eq "target menu: Enter selects /etc/nebula" "$out" "/etc/nebula"

out="$(printf '2\n' | _bundle_target_menu 2>/dev/null)"
assert_eq "target menu: home option" "$out" "$HOME/nebula"

out="$(printf '%s\n' "$SANDBOX/custom-target" | _bundle_target_menu 2>/dev/null)"
assert_eq "target menu: typed path" "$out" "$SANDBOX/custom-target"

out="$(printf '3\n%s\n' "$SANDBOX/browsed-target" | _bundle_target_menu 2>/dev/null)"
assert_eq "target menu: browsed path" "$out" "$SANDBOX/browsed-target"

# --- TUI wrapper: file picker + target prompt + reload ---------------------
TARGET_TUI="$SANDBOX/tui-target"
export CONF_OVERRIDE="$SANDBOX/tui.conf" IMPORT_YES=0 IMPORT_FORCE=0 IMPORT_BUNDLE_DRY_RUN=0
TUI_RESTART=0
# Here-string (not a pipeline) so TUI_RESTART is set in this shell.
import_bundle_tui <<< "$(printf '%s\n%s\n' "$ARCHIVE" "$TARGET_TUI")" >"$SANDBOX/tui.log" 2>&1; rc=$?
assert_eq "TUI bundle import succeeds" "$rc" "0"
assert_file "TUI import installed the config" "$TARGET_TUI/config.yml"
assert_eq "TUI import requests a reload" "$TUI_RESTART" "1"
assert_eq "TUI import used no sudo" "$(sudo_count)" "0"

# --- CLI: import --bundle ---------------------------------------------------
CLI_CONF="$SANDBOX/cli.conf"
CLI_TARGET="$SANDBOX/cli-target"
out="$("$REPO_ROOT/nebula-manager" --config "$CLI_CONF" import --bundle "$ARCHIVE" --dir "$CLI_TARGET" --yes 2>&1)"; rc=$?
assert_eq "CLI bundle import succeeds" "$rc" "0"
assert_file "CLI installed the config" "$CLI_TARGET/config.yml"
assert_contains "CLI created manager.conf" "$(cat "$CLI_CONF")" "[server.client1]"
assert_contains "CLI output names the client" "$out" "Imported client 'client1'"
assert_eq "CLI bundle import used no sudo" "$(sudo_count)" "0"

harness_summary
