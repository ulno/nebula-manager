#!/usr/bin/env bash
# Test: editing a possibly service-owned Nebula config without yq permission
# errors. Edits happen on a user-owned copy and are written back (with a
# backup) through the elevate() path.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="config editing (privileged-safe)"
harness_init

# A mock sudo that really performs cp/cat (as the current user) after making
# the relevant files accessible, so the copy/write-back flow can be exercised.
cat > "$SANDBOX/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
    [[ "${SUDO_CACHED:-0}" == 1 ]] && exit 0 || exit 1
fi
printf 'sudo %s\n' "$*" >> "${SUDO_LOG:?SUDO_LOG not set}"
case "${1:-}" in
    cat)
        chmod 600 "$2" 2>/dev/null
        exec cat "$2" ;;
    cp)
        shift
        for a in "$@"; do [[ -e "$a" ]] && chmod 600 "$a" 2>/dev/null; done
        exec cp "$@" ;;
esac
exec "$@"
MOCK
chmod +x "$SANDBOX/bin/sudo"
export SUDO_CACHED=0

make_cfg() {
    mkdir -p "$(dirname "$1")"
    printf 'listen:\n  port: 4242\n' > "$1"
}

count_backups() { ls "$1".bak.* 2>/dev/null | wc -l | tr -d ' '; }

# --- user-writable config: edit in place, no sudo ---------------------------
CFG="$SANDBOX/edit/writable.yml"
make_cfg "$CFG"
config_edit_begin "$CFG" >/dev/null
assert_eq "writable config is edited in place" "$CONFIG_EDIT_WORK" "$CFG"
printf '# edited\n' >> "$CONFIG_EDIT_WORK"
config_edit_commit >/dev/null
assert_contains "in-place edit saved" "$(cat "$CFG")" "# edited"
assert_eq "in-place edit used no sudo" "$(sudo_count)" "0"

# --- readable but not writable: work on a copy, write back with sudo --------
CFG2="$SANDBOX/edit/readonly.yml"
make_cfg "$CFG2"
chmod 444 "$CFG2"
config_edit_begin "$CFG2" >/dev/null
WORK2="$CONFIG_EDIT_WORK"
assert_ne "read-only config uses a working copy" "$WORK2" "$CFG2"
assert_file "working copy exists" "$WORK2"
printf '# edited-copy\n' >> "$WORK2"
config_edit_commit >/dev/null
assert_contains "copy written back to the source" "$(cat "$CFG2")" "# edited-copy"
assert_eq "write-back created a backup" "$(count_backups "$CFG2")" "1"
assert_no_file "working copy removed after save" "$WORK2"
assert_ne "write-back used sudo" "$(sudo_count)" "0"

# --- unreadable config with cached sudo: read a copy, edit, write back ------
CFG3="$SANDBOX/edit/private.yml"
make_cfg "$CFG3"
chmod 000 "$CFG3"
export SUDO_CACHED=1
config_edit_begin "$CFG3" >/dev/null
WORK3="$CONFIG_EDIT_WORK"
assert_ne "unreadable config uses a copy" "$WORK3" "$CFG3"
assert_file "readable copy created" "$WORK3"
printf '# edited-private\n' >> "$WORK3"
config_edit_commit >/dev/null
assert_contains "unreadable config written back" "$(cat "$CFG3")" "# edited-private"
assert_eq "private write-back created a backup" "$(count_backups "$CFG3")" "1"
assert_no_file "private working copy removed" "$WORK3"
chmod 600 "$CFG3"

# --- no changes: no write, no backup, no sudo -------------------------------
CFG4="$SANDBOX/edit/unchanged.yml"
make_cfg "$CFG4"
chmod 444 "$CFG4"
config_edit_begin "$CFG4" >/dev/null
WORK4="$CONFIG_EDIT_WORK"
before_sudo="$(sudo_count)"
before_bak="$(count_backups "$CFG4")"
out="$(config_edit_commit 2>&1)"
assert_contains "no-change commit says so" "$out" "No changes to save"
assert_eq "no-change commit used no sudo" "$(sudo_count)" "$before_sudo"
assert_eq "no-change commit created no backup" "$(count_backups "$CFG4")" "$before_bak"
assert_no_file "no-change working copy removed" "$WORK4"

# --- edit_nebula_config smoke test (mikefarah yq v4 syntax) --------------
if yq_is_v4; then
    EDIR="$SANDBOX/edit/editable"
    ED="$EDIR/config.yml"
    mkdir -p "$EDIR"
    cat > "$ED" <<'YAML'
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/client.crt
  key: /etc/nebula/client.key
static_host_map:
  "10.100.0.1": ["vps:4545"]
lighthouse:
  am_lighthouse: false
  interval: 60
  hosts:
    - "10.100.0.1"
listen:
  host: 0.0.0.0
  port: 0
punchy:
  punch: true
relay:
  am_relay: false
  use_relays: false
  relays: []
tun:
  dev: nebula1
YAML
    mkdir -p "$SANDBOX/fakebin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/fakebin/nebula"
    chmod +x "$SANDBOX/fakebin/nebula"
    OLD_BIN2="${NEBULA_BIN_PATH:-}"
    export NEBULA_BIN_PATH="$SANDBOX/fakebin" NEBULA_DIR="$EDIR" NEBULA_NO_PROMPT=1
    # Press Enter through every prompt (extra newlines are harmless).
    printf '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n' \
        | edit_nebula_config >"$SANDBOX/edit.out" 2>&1; rc=$?
    assert_eq "edit_nebula_config works with mikefarah yq v4" "$rc" "0"
    assert_not_contains "edit_nebula_config has no yq flag error" "$(cat "$SANDBOX/edit.out")" "unknown shorthand flag"
    assert_contains "edit_nebula_config kept the config" "$(cat "$ED")" "tun:"
    if [[ -n "$OLD_BIN2" ]]; then export NEBULA_BIN_PATH="$OLD_BIN2"; else unset NEBULA_BIN_PATH; fi
    unset NEBULA_DIR NEBULA_NO_PROMPT
fi

harness_summary
