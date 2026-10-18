#!/usr/bin/env bash
# Test: show_system_info reads the (often service-owned) Nebula config through
# the guarded/elevating path instead of raw awk/grep (which used to spew
# "Permission denied" for /etc/nebula/config.yml owned by the service user).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="system info / privileged config"
harness_init
export NEBULA_NO_PROMPT=1   # no interactive sudo prompt in tests

# Stub systemctl so the "service active" branch runs without a D-Bus session.
systemctl() {
    case "${1:-}" in
        is-active)
            [[ "${2:-}" == "--quiet" ]] && return 0
            echo active; return 0 ;;
        is-enabled) echo enabled; return 0 ;;
        show)       echo "ActiveEnterTimestamp=Thu 2025-01-02 03:04:05 UTC"; return 0 ;;
        *)          return 0 ;;
    esac
}

# --- readable config: Network/State parsed, port resolved, no errors ---
export NEBULA_DIR="$SANDBOX/nebula"
mkdir -p "$NEBULA_DIR"
cat > "$NEBULA_DIR/config.yml" <<EOF
pki:
  ca: $SANDBOX/keys/ca.crt
listen:
  host: 0.0.0.0
  port: 0
lighthouse:
  am_lighthouse: false
tun:
  dev: nebula1
EOF
out="$(show_system_info 2>&1)"
assert_contains "shows the service state"   "$out" "Service:"
assert_contains "shows the tun interface"   "$out" "nebula1"
assert_contains "resolves the listen port"  "$out" "0.0.0.0:"
assert_not_contains "no awk permission error" "$out" "Permission denied"
assert_contains "reports client state"      "$out" "Client"
assert_contains "flags missing static_host_map" "$out" "missing static_host_map"
assert_contains "flags missing lighthouse.hosts" "$out" "lighthouse.hosts"

# --- a successful read populates the user-owned header cache ---
cache="$(nebula_info_cache_file)"
assert_file "info cache written" "$cache"
assert_contains "cache records the tun device" "$(cat "$cache")" "tun=nebula1"
assert_contains "cache is keyed to its source config" "$(cat "$cache")" "config=$NEBULA_DIR/config.yml"
assert_contains "cache records lighthouse health" "$(cat "$cache")" "lh_hosts=0"
assert_contains "cache records static-map health" "$(cat "$cache")" "static_hosts=0"

# A readable temporary copy must still key the cache to the real config path.
cp "$NEBULA_DIR/config.yml" "$SANDBOX/readable-copy.yml"
_nebula_info_derive "$SANDBOX/readable-copy.yml" "$NEBULA_DIR/config.yml" >/dev/null
assert_contains "cache keeps the real path for a readable copy" "$(cat "$cache")" "config=$NEBULA_DIR/config.yml"

# a cache from a different config path is never treated as fresh (multi-server)
cp "$cache" "$cache.orig"
sed -i 's|^config=.*|config=/some/other/config.yml|' "$cache"
if _nebula_info_fresh "$NEBULA_DIR/config.yml"; then _bad "cache is per config"; else _ok "cache is per config"; fi
mv "$cache.orig" "$cache"

# --- unreadable config + fresh cache: show cached values, no prompt/notice ---
chmod 000 "$NEBULA_DIR/config.yml"
out="$(show_system_info 2>&1)"
assert_contains "uses the cached tun when unreadable" "$out" "nebula1"
assert_contains "marks cached values" "$out" "[cached]"
assert_not_contains "no awk permission error" "$out" "Permission denied"
assert_not_contains "does not tell the user to run with sudo" "$out" "run with sudo"

# --- no cache + unreadable + no nebula interface: a notice pointing in-app ---
rm -f "$cache"
ip() { return 0; }          # pretend there is no nebula* interface
out="$(show_system_info 2>&1)"
assert_contains "notice points at Diagnostics" "$out" "choose Diagnostics"
assert_not_contains "notice never says run with sudo" "$out" "run with sudo"
assert_not_contains "no awk error when unreadable" "$out" "cannot open file"
assert_not_contains "no grep error when unreadable" "$out" "Permission denied"
unset -f ip

# --- no cache + unreadable + a nebula* interface: guess it without the config ---
ip() {
    if [[ "$*" == *"-o -4 addr show"* ]]; then
        echo "7: nebula1    inet 10.100.0.2/24 brd 10.100.0.255 scope global nebula1"
    else
        command ip "$@"
    fi
}
out="$(show_system_info 2>&1)"
assert_contains "guesses the interface without the config" "$out" "nebula1"
assert_contains "shows the overlay address" "$out" "10.100.0.2"
assert_contains "points at Diagnostics for the port" "$out" "see Diagnostics"
assert_contains "flags the unverified config" "$out" "not readable - lighthouse/static_host_map not verified"
assert_contains "points at Validate Config" "$out" "Validate Config"
assert_not_contains "unverified note never says run with sudo" "$out" "run with sudo"
unset -f ip
chmod 644 "$NEBULA_DIR/config.yml"

# --- check_nebula_config tolerates an unreadable config without crashing ---
chmod 000 "$NEBULA_DIR/config.yml"
out="$(check_nebula_config "$NEBULA_DIR/config.yml" 2>&1)"; rc=$?
assert_eq "check_nebula_config fails cleanly when unreadable" "$rc" "1"
assert_contains "explains the read failure" "$out" "Cannot read Nebula config"
chmod 644 "$NEBULA_DIR/config.yml"

# --- permission failure + cached sudo -> an elevated re-test is attempted ---
mkdir -p "$SANDBOX/elevbin"
cat > "$SANDBOX/elevbin/sudo" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then exit 0; fi
if [[ "${1:-}" == "cat" ]]; then chmod 600 "$2" 2>/dev/null; exec cat "$2"; fi
MOCK_SUDO=1 exec "$@"
MOCK
cat > "$SANDBOX/elevbin/nebula" <<'MOCK'
#!/usr/bin/env bash
if [[ "${MOCK_SUDO:-0}" == 1 ]]; then exit 0; fi
echo 'level=ERROR msg="Could not load client cert" error="unable to read pki.key file /x: permission denied"' >&2
exit 1
MOCK
chmod +x "$SANDBOX/elevbin/sudo" "$SANDBOX/elevbin/nebula"
ELEV_CFG="$SANDBOX/elev/config.yml"
mkdir -p "$(dirname "$ELEV_CFG")"
printf 'listen:\n  port: 4242\n' > "$ELEV_CFG"
chmod 000 "$ELEV_CFG"
OLD_PATH="$PATH"; OLD_BIN="${NEBULA_BIN_PATH:-}"
export PATH="$SANDBOX/elevbin:$PATH" NEBULA_BIN_PATH="$SANDBOX/elevbin"
out="$(check_nebula_config "$ELEV_CFG" 2>&1)"; rc=$?
assert_eq "elevated validation succeeds" "$rc" "0"
assert_contains "offers the elevated re-test" "$out" "Re-testing with temporary sudo"
assert_contains "reports valid after elevation" "$out" "Nebula config is valid"
chmod 644 "$ELEV_CFG"
export PATH="$OLD_PATH"
if [[ -n "$OLD_BIN" ]]; then export NEBULA_BIN_PATH="$OLD_BIN"; else unset NEBULA_BIN_PATH; fi

# --- nebula_bin(): configured path wins, else $PATH ---
mkdir -p "$SANDBOX/binp"
: > "$SANDBOX/binp/nebula"; chmod +x "$SANDBOX/binp/nebula"
NEBULA_BIN_PATH="$SANDBOX/binp"
assert_eq "nebula_bin uses the configured bin_path" "$(nebula_bin)" "$SANDBOX/binp/nebula"
unset NEBULA_BIN_PATH

harness_summary
