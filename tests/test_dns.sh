#!/usr/bin/env bash
# Test: Nebula DNS helpers (lighthouse serve_dns + client resolvectl setup).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="Nebula DNS"
harness_init
export NEBULA_NO_PROMPT=1

if ! yq_is_v4; then
    echo "SKIP: mikefarah yq v4 is required for the lighthouse DNS test"
    exit 77
fi

# A fake resolvectl so command -v succeeds; elevate() logs the sudo command.
cat > "$SANDBOX/bin/resolvectl" <<'MOCK'
#!/usr/bin/env bash
if [[ "${FAKE_RESOLVE_CONFIG:-0}" == 1 ]]; then
    case "${1:-}" in
        dns)    echo "Link 7 (lo): 10.100.0.1" ;;
        domain) echo "Link 7 (lo): ~theprof.mesh" ;;
    esac
else
    case "${1:-}" in
        dns|domain) echo "Link 7 (lo):" ;;
    esac
fi
MOCK
chmod +x "$SANDBOX/bin/resolvectl"

# --- client helpers ---------------------------------------------------------
CLIENT="$SANDBOX/client"
mkdir -p "$CLIENT"
cat > "$CLIENT/config.yml" <<'YAML'
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/client.theprof.mesh.crt
  key: /etc/nebula/client.theprof.mesh.key
lighthouse:
  am_lighthouse: false
  hosts:
    - "10.100.0.1"
static_host_map:
  "10.100.0.1": ["vps.theprof.demo:4545"]
listen:
  port: 0
tun:
  dev: lo
firewall:
  inbound: []
YAML

assert_eq "client role detected" "$(_dns_role "$CLIENT/config.yml")" "client"
assert_eq "lighthouse overlay IP parsed" "$(_dns_lh_ips "$CLIENT/config.yml")" "10.100.0.1"
assert_eq "mesh domain derived from the cert name" "$(_dns_mesh_domain "$CLIENT/config.yml")" "theprof.mesh"

# static_host_map fallback when lighthouse.hosts is absent
STATIC_ONLY="$SANDBOX/static.yml"
cat > "$STATIC_ONLY" <<'YAML'
static_host_map:
  "10.100.0.1": ["vps.theprof.demo:4545"]
lighthouse:
  am_lighthouse: false
YAML
assert_eq "static_host_map fallback for lighthouse IPs" "$(_dns_lh_ips "$STATIC_ONLY")" "10.100.0.1"

# --- client status + setup --------------------------------------------------
out="$(NEBULA_DIR="$CLIENT" dns_status 2>&1)"
assert_contains "status shows the role" "$out" "Role:         client"
assert_contains "status shows the lighthouse" "$out" "Lighthouse:   10.100.0.1"
assert_contains "status shows the DNS suffix" "$out" "Mesh domain:  theprof.mesh"
assert_contains "status flags an unconfigured resolver" "$out" "Resolver DNS: <not configured>"
assert_contains "status flags an unconfigured suffix" "$out" "DNS suffix:   <not configured>"
assert_contains "status shows the boot hook" "$out" "Boot hook:    not installed"

out="$(FAKE_RESOLVE_CONFIG=1 NEBULA_DIR="$CLIENT" dns_status 2>&1)"
assert_contains "status shows configured DNS" "$out" "Resolver DNS: 10.100.0.1"
assert_contains "status shows configured suffix" "$out" "DNS suffix:   ~theprof.mesh"

: > "$SUDO_LOG"
out="$(NEBULA_DIR="$CLIENT" configure_client_dns 2>&1)"; rc=$?
assert_eq "client DNS setup succeeds" "$rc" "0"
assert_contains "client DNS points resolvectl at the lighthouse" "$(cat "$SUDO_LOG")" "resolvectl dns lo 10.100.0.1"
assert_contains "client DNS routes the mesh suffix" "$(cat "$SUDO_LOG")" "resolvectl domain lo ~theprof.mesh"
assert_contains "client DNS reports success" "$out" "Name resolution: 'theprof.mesh'"

# apply + persist installs the boot hook through the elevate path
: > "$SUDO_LOG"
out="$(NEBULA_NO_PROMPT=1 NEBULA_DIR="$CLIENT" configure_client_dns --persist 2>&1)"; rc=$?
assert_eq "client DNS persist succeeds" "$rc" "0"
assert_contains "persist installs the resolver unit" "$(cat "$SUDO_LOG")" "nebula-manager-resolved.service"
assert_contains "persist enables the resolver unit" "$(cat "$SUDO_LOG")" "systemctl enable --now"

# --- lighthouse setup -------------------------------------------------------
LH="$SANDBOX/lh"
mkdir -p "$LH"
cat > "$LH/config.yml" <<'YAML'
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/vps.theprof.mesh.crt
  key: /etc/nebula/vps.theprof.mesh.key
lighthouse:
  am_lighthouse: true
  hosts: []
listen:
  port: 4545
tun:
  dev: lo
firewall:
  inbound: []
YAML

assert_eq "lighthouse role detected" "$(_dns_role "$LH/config.yml")" "lighthouse"
: > "$SUDO_LOG"
out="$(NEBULA_DIR="$LH" configure_lighthouse_dns 2>&1)"; rc=$?
assert_eq "lighthouse DNS setup succeeds" "$rc" "0"
cfg="$(cat "$LH/config.yml")"
assert_contains "serve_dns enabled" "$cfg" "serve_dns: true"
assert_contains "DNS binds the overlay IP" "$cfg" "host: 127.0.0.1"
assert_contains "DNS port set to 53" "$cfg" "port: 53"
assert_contains "firewall allows UDP" "$cfg" "proto: udp"
assert_contains "lighthouse setup reports success" "$out" "Lighthouse DNS enabled"
assert_eq "user-owned lighthouse config used no sudo" "$(sudo_count)" "0"

out="$(NEBULA_DIR="$LH" dns_status 2>&1)"
assert_contains "status reports serve_dns" "$out" "serve_dns:    enabled"

# --- dns CLI ----------------------------------------------------------------
out="$(NEBULA_DIR="$CLIENT" dns_cli status 2>&1)"
assert_contains "dns status subcommand works" "$out" "Role:         client"

harness_summary
