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

# --- unreadable config: graceful message, still no permission-denied spew ---
chmod 000 "$NEBULA_DIR/config.yml"
out="$(show_system_info 2>&1)"
assert_contains "unreadable config is reported gracefully" "$out" "config not readable"
assert_not_contains "no awk error when unreadable" "$out" "cannot open file"
assert_not_contains "no grep error when unreadable" "$out" "Permission denied"
chmod 644 "$NEBULA_DIR/config.yml"

# --- check_nebula_config tolerates an unreadable config without crashing ---
chmod 000 "$NEBULA_DIR/config.yml"
out="$(check_nebula_config "$NEBULA_DIR/config.yml" 2>&1)"; rc=$?
assert_eq "check_nebula_config fails cleanly when unreadable" "$rc" "1"
assert_contains "explains the read failure" "$out" "Cannot read Nebula config"
chmod 644 "$NEBULA_DIR/config.yml"

# --- nebula_bin(): configured path wins, else $PATH ---
mkdir -p "$SANDBOX/binp"
: > "$SANDBOX/binp/nebula"; chmod +x "$SANDBOX/binp/nebula"
NEBULA_BIN_PATH="$SANDBOX/binp"
assert_eq "nebula_bin uses the configured bin_path" "$(nebula_bin)" "$SANDBOX/binp/nebula"
unset NEBULA_BIN_PATH

harness_summary
