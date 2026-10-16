#!/usr/bin/env bash
# Test: the import wizard (discover a Nebula install -> generate nebula-manager.conf).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="import wizard"
harness_init

# synthetic Nebula config + certificate workspace
mkdir -p "$SANDBOX/keys"
: > "$SANDBOX/keys/ca.crt"; : > "$SANDBOX/keys/host1.crt"; : > "$SANDBOX/keys/host2.crt"
cfg="$SANDBOX/nebula.yml"
cat > "$cfg" <<EOF
pki:
  ca: $SANDBOX/keys/ca.crt
  cert: $SANDBOX/keys/host1.crt
  key: $SANDBOX/keys/host1.key
listen:
  host: 0.0.0.0
  port: 4545
lighthouse:
  am_lighthouse: false
tun:
  dev: nebula1
static_host_map:
  "10.100.0.1": ["vps.theprof.demo:4545"]
EOF

# --- YAML helpers ---
assert_eq "tun.dev parsed" "$(_imp_section_key "$cfg" tun dev)" "nebula1"
assert_eq "listen.port parsed" "$(_imp_section_key "$cfg" listen port)" "4545"
assert_eq "lighthouse.am_lighthouse parsed" "$(_imp_section_key "$cfg" lighthouse am_lighthouse)" "false"
assert_eq "pki.ca parsed" "$(_imp_section_key "$cfg" pki ca)" "$SANDBOX/keys/ca.crt"
assert_eq "static_host_map parsed" "$(_imp_static_host "$cfg")" "10.100.0.1 vps.theprof.demo:4545"

# --- detection ---
import_detect "$cfg"
assert_eq "detect tun" "$IMP_TUN" "nebula1"
assert_eq "detect port" "$IMP_PORT" "4545"
assert_eq "detect lighthouse" "$IMP_IS_LH" "false"
assert_contains "detect static peer" "$IMP_STATIC" "vps.theprof.demo:4545"
assert_eq "detect certs dir" "$IMP_CERTS_DIR" "$SANDBOX/keys"
assert_eq "detect cert count" "$IMP_CERT_COUNT" "3"
assert_eq "detect config dir" "$IMP_CONFIG_DIR" "$SANDBOX"

# --- rendered proposal ---
conf="$(import_render_conf)"
assert_contains "render cert_dir" "$conf" "cert_dir=$SANDBOX/keys"
assert_contains "render default_port" "$conf" "default_port=4545"
assert_contains "render bin_path" "$conf" "bin_path="
assert_contains "render server section" "$conf" "[server."

# --- CLI behaviour ---
NM="$REPO_ROOT/nebula-manager"
out="$("$NM" import --dry-run --from "$cfg" --config "$SANDBOX/out.conf" 2>&1)"
assert_contains "CLI prints proposal" "$out" "[server."
assert_contains "CLI shows detected port" "$out" "4545"
assert_no_file "dry-run writes nothing" "$SANDBOX/out.conf"

"$NM" import --from "$cfg" --config "$SANDBOX/out.conf" >/dev/null 2>&1
assert_no_file "non-tty without --yes refuses to write" "$SANDBOX/out.conf"

"$NM" import --yes --from "$cfg" --config "$SANDBOX/out.conf" >/dev/null 2>&1
assert_file "writes with --yes" "$SANDBOX/out.conf"
assert_contains "written config has cert_dir" "$(cat "$SANDBOX/out.conf")" "cert_dir=$SANDBOX/keys"

# --- unit-file parsing / service-name rendering (works without D-Bus) ---
ud="$SANDBOX/units"; mkdir -p "$ud"
printf '[Service]\nExecStart=/usr/bin/nebula -config %s/config.yml\n' "$SANDBOX" > "$ud/nebula.service"
assert_eq "parses ExecStart from a unit file" \
    "$(_imp_unit_execstart "$ud/nebula.service")" "/usr/bin/nebula -config $SANDBOX/config.yml"

# service= is rendered as the unit NAME even when we resolved a unit-file path
IMP_SERVICE="nebula.service"
IMP_SERVICE_PATH="/lib/systemd/system/nebula.service"
assert_contains "render prefers the unit name" "$(import_render_conf)" "service=nebula.service"
assert_not_contains "render does not emit a unit path" "$(import_render_conf)" "service=/lib/systemd"

harness_summary
