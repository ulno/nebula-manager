#!/usr/bin/env bash
# Test: generated client config.yml.template.
# Verifies that real network settings are taken from the local Nebula config
# and, when that is unavailable, from [server.*] entries + certificates. Also
# verifies that anything undetermined is flagged in the file and on stderr.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="generated client config"
harness_init
require_cmd nebula-cert

KEYS="$SANDBOX/keys"
mkdir -p "$KEYS"
CERT_DIR="$KEYS" CA_NAME="cfg-ca" pki_ca_create >/dev/null
CERT_DIR="$KEYS" SIGN_NAME="client1" SIGN_IP="10.100.0.5/24" pki_sign >/dev/null
CERT_DIR="$KEYS" SIGN_NAME="vps.example" SIGN_IP="10.100.0.1/24" SIGN_GROUPS="lighthouse,servers" pki_sign >/dev/null

OUT="$SANDBOX/config.out"
ERR="$SANDBOX/config.err"
: > "$OUT"; : > "$ERR"

run_writer() {
    PKI_NET_READY=0
    pki_write_client_config "$@" >"$OUT" 2>"$ERR"
}

# --- local config is authoritative -----------------------------------------
LOCAL="$SANDBOX/local/config.yml"
mkdir -p "$(dirname "$LOCAL")"
cat > "$LOCAL" <<'YAML'
pki:
  ca: /etc/nebula/ca.crt

static_host_map:
  "10.100.0.1": ["vps.example:4545"]

lighthouse:
  am_lighthouse: false
  interval: 5
  hosts:
    - "10.100.0.1"

punchy:
    punch: true
    respond: true
    delay: 1s

firewall:
  outbound:
    - port: any
      proto: any
      host: any
  inbound:
    - port: any
      proto: any
      host: any

listen:
  host: 0.0.0.0
  port: 0

tun:
    dev: nebula1
YAML

NEBULA_LOCAL_CONFIG="$LOCAL" NEBULA_DIR="$SANDBOX/no-such-dir" \
    CONF_OVERRIDE="$SANDBOX/no-manager.conf" \
    run_writer "$SANDBOX/client.yml" "client1" "$KEYS"

cfg="$(cat "$SANDBOX/client.yml")"
assert_contains "static_host_map uses the real lighthouse endpoint" "$cfg" '"10.100.0.1": ["vps.example:4545"]'
assert_contains "lighthouse hosts use the real overlay IP" "$cfg" '    - "10.100.0.1"'
assert_contains "lighthouse interval is kept" "$cfg" 'interval: 5'
assert_contains "listen port is kept" "$cfg" 'port: 0'
assert_contains "punching is enabled" "$cfg" 'punch: true'
assert_contains "punchy respond is enabled" "$cfg" 'respond: true'
assert_contains "punchy delay is kept" "$cfg" 'delay: 1s'
assert_contains "tun device is kept" "$cfg" 'dev: nebula1'
assert_contains "firewall policy is copied" "$cfg" 'firewall:'
assert_contains "firewall inbound rule is copied" "$cfg" '  inbound:'
assert_not_contains "complete config has no warning" "$cfg" 'WARNING: incomplete'
assert_contains "source is reported" "$(cat "$OUT")" "network settings from $LOCAL"
assert_empty_file "complete config emits no warning" "$ERR"

# --- fallback: [server.*] role/host + certificate IP -----------------------
MANAGER="$SANDBOX/manager.conf"
cat > "$MANAGER" <<EOF
[global]
cert_dir=$KEYS
[server.vps]
dir=/nonexistent
service=nebula.service
enabled=true
role=lighthouse
host=vps.example:4545
EOF

NEBULA_LOCAL_CONFIG="$SANDBOX/no-such-local.yml" NEBULA_DIR="$SANDBOX/no-such-dir" \
    CONF_OVERRIDE="$MANAGER" \
    run_writer "$SANDBOX/client2.yml" "client1" "$KEYS"

cfg="$(cat "$SANDBOX/client2.yml")"
assert_contains "fallback maps the server overlay IP" "$cfg" '"10.100.0.1": ["vps.example:4545"]'
assert_contains "fallback lists the lighthouse host" "$cfg" '    - "10.100.0.1"'
assert_contains "fallback keeps the default interval" "$cfg" 'interval: 60'
assert_contains "fallback gets a permissive firewall" "$cfg" 'This bundle is permissive'
assert_not_contains "fallback config has no warning" "$cfg" 'WARNING: incomplete'
assert_empty_file "fallback emits no warning" "$ERR"

# --- missing public endpoint is flagged ------------------------------------
cat > "$MANAGER" <<EOF
[global]
cert_dir=$KEYS
[server.vps]
dir=/nonexistent
service=nebula.service
enabled=true
role=lighthouse
EOF

NEBULA_LOCAL_CONFIG="$SANDBOX/no-such-local.yml" NEBULA_DIR="$SANDBOX/no-such-dir" \
    CONF_OVERRIDE="$MANAGER" \
    run_writer "$SANDBOX/client3.yml" "client1" "$KEYS"

cfg="$(cat "$SANDBOX/client3.yml")"
assert_contains "missing endpoint is flagged in the file" "$cfg" 'WARNING: incomplete'
assert_contains "missing static map is named" "$cfg" 'could not determine a lighthouse endpoint'
assert_contains "missing endpoint is flagged on stderr" "$(cat "$ERR")" 'could not determine'
assert_contains "missing endpoint names the lighthouse IP" "$(cat "$ERR")" 'static_host_map entry for lighthouse 10.100.0.1'
assert_contains "lighthouse itself is still detected" "$cfg" '    - "10.100.0.1"'

# --- no lighthouse at all is flagged ---------------------------------------
: > "$MANAGER"
NEBULA_LOCAL_CONFIG="$SANDBOX/no-such-local.yml" NEBULA_DIR="$SANDBOX/no-such-dir" \
    CONF_OVERRIDE="$MANAGER" \
    run_writer "$SANDBOX/client4.yml" "client1" "$KEYS"

cfg="$(cat "$SANDBOX/client4.yml")"
assert_contains "missing lighthouse is flagged in the file" "$cfg" 'could not determine the lighthouse overlay IP'
assert_contains "missing lighthouse is flagged on stderr" "$(cat "$ERR")" 'lighthouse overlay IP'
assert_contains "static map placeholder remains" "$cfg" '# static_host_map:'

# --- the bundle actually contains the populated template -------------------
if command -v zip >/dev/null 2>&1; then
    NEBULA_LOCAL_CONFIG="$LOCAL" NEBULA_DIR="$SANDBOX/no-such-dir" \
        CONF_OVERRIDE="$SANDBOX/no-manager.conf" \
        pki_bundle_client_zip "client1" "$SANDBOX/zipout" "$KEYS" >/dev/null 2>&1
    if command -v unzip >/dev/null 2>&1; then
        unzip -p "$SANDBOX/zipout/client1-nebula-bundle.zip" config.yml.template > "$SANDBOX/ziptpl"
        cfg="$(cat "$SANDBOX/ziptpl")"
        assert_contains "zip template has the real static_host_map" "$cfg" '"10.100.0.1": ["vps.example:4545"]'
        assert_contains "zip template has the real lighthouse" "$cfg" '    - "10.100.0.1"'
    fi
fi

# --- a lighthouse certificate gets am_lighthouse: true ---------------------
NEBULA_LOCAL_CONFIG="$LOCAL" NEBULA_DIR="$SANDBOX/no-such-dir" \
    CONF_OVERRIDE="$SANDBOX/no-manager.conf" \
    run_writer "$SANDBOX/lighthouse.yml" "vps.example" "$KEYS"
cfg="$(cat "$SANDBOX/lighthouse.yml")"
assert_contains "lighthouse cert -> am_lighthouse true" "$cfg" 'am_lighthouse: true'
assert_contains "lighthouse cert gets a fixed listen port" "$cfg" 'port: 4242'

harness_summary
