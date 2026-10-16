#!/usr/bin/env bash
# Test: Nebula listen-port resolution (config value, auto-detection, default).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="listen port resolution"
harness_init

# --- pure parser over synthetic `ss` output ---
ss_out='State  Recv-Q Send-Q Local Address:Port  Peer Address:Port  Process
UNCONN 0      0      0.0.0.0:48118          0.0.0.0:*
UNCONN 0      0      0.0.0.0:54143          0.0.0.0:*           users:(("nebula",pid=123,fd=7))
UNCONN 0      0      0.0.0.0:5353           0.0.0.0:*'

assert_eq "parses nebula's UDP port from ss" \
    "$(printf '%s\n' "$ss_out" | _nebula_port_from_ss)" "54143"
assert_eq "returns nothing without a nebula line" \
    "$(printf '%s\n' "$ss_out" | grep -v nebula | _nebula_port_from_ss)" ""
assert_eq "handles wildcard address form" \
    "$(printf '%s\n' 'UNCONN 0 0 *:51820 0.0.0.0:* users:(("nebula",pid=9,fd=3))' | _nebula_port_from_ss)" "51820"

# --- explicit config port wins ---
cfg="$SANDBOX/config.yml"
printf 'listen:\n  host: 0.0.0.0\n  port: 4545\n' > "$cfg"
assert_eq "explicit config port used" "$(resolve_listen_port "$cfg")" "4545 config"

# --- listen.port: 0 => OS-assigned => auto-detect ---
printf 'listen:\n  host: 0.0.0.0\n  port: 0\n' > "$cfg"
autodetect_nebula_port() { printf '54143'; }
assert_eq "port 0 falls back to auto-detection" "$(resolve_listen_port "$cfg")" "54143 auto"

# --- port 0 + no detection => configured default ---
autodetect_nebula_port() { return 1; }
export NEBULA_DEFAULT_PORT=4545
assert_eq "port 0 falls back to default_port" "$(resolve_listen_port "$cfg")" "4545 default"
export NEBULA_DEFAULT_PORT=4242
assert_eq "default_port is configurable" "$(resolve_listen_port "$cfg")" "4242 default"
unset NEBULA_DEFAULT_PORT

harness_summary
