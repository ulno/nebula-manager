#!/usr/bin/env bash
# Test: name/IP suggestions for new client certificates, derived from the
# existing certs in the workspace (domain suffix + next free overlay address).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="cert name/ip suggestions"
harness_init
require_cmd nebula-cert

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"

# expected short hostname (same fallbacks as suggest_cert_name)
exp_host="$(hostname -s 2>/dev/null || head -n1 /etc/hostname 2>/dev/null || printf '%s' "${HOSTNAME:-}")"
exp_host="${exp_host%%.*}"

CA_NAME="TestMeshCA" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1
for spec in "host1.mesh.demo:10.100.0.1/24" "host2.mesh.demo:10.100.0.2/24" "host3.mesh.demo:10.100.0.3/24"; do
    n="${spec%%:*}"; a="${spec#*:}"
    SIGN_NAME="$n" SIGN_IP="$a" CERT_DIR="$keys" pki_sign >/dev/null 2>&1
done

# --- domain suffix from existing cert names ---
assert_eq "domain suffix detected" "$(cert_domain_suffix "$keys")" ".mesh.demo"

sname="$(suggest_cert_name "$keys")"
assert_contains "name suggestion uses the hostname" "$sname" "$exp_host"
assert_contains "name suggestion adds the mesh domain" "$sname" ".mesh.demo"

# --- next free IP in the most-used network ---
assert_eq "next free IP is .4/24" "$(suggest_next_cert_ip "$keys")" "10.100.0.4/24"

# consume .4 -> suggestion advances
SIGN_NAME="host4.mesh.demo" SIGN_IP="10.100.0.4/24" CERT_DIR="$keys" pki_sign >/dev/null 2>&1
assert_eq "suggestion advances to .5/24" "$(suggest_next_cert_ip "$keys")" "10.100.0.5/24"

# a lone address in another network does not steal the suggestion
SIGN_NAME="other" SIGN_IP="192.168.9.1/24" CERT_DIR="$keys" pki_sign >/dev/null 2>&1
assert_eq "most-used network still wins" "$(suggest_next_cert_ip "$keys")" "10.100.0.5/24"

# --- empty workspace: hostname only, no IP ---
empty="$SANDBOX/empty"; mkdir -p "$empty"
assert_eq "name falls back to hostname alone" "$(suggest_cert_name "$empty")" "$exp_host"
assert_eq "no IP suggestion without certs" "$(suggest_next_cert_ip "$empty")" ""

# --- CLI: sign with no --name/--ip fills them from the suggestions ---
NM="$REPO_ROOT/nebula-manager"
exp_name="$(suggest_cert_name "$keys")"
exp_ip="$(suggest_next_cert_ip "$keys")"
out="$("$NM" sign --cert-dir "$keys" 2>&1)"; rc=$?
assert_eq "sign without --name/--ip succeeds" "$rc" "0"
assert_contains "reports the suggested name" "$out" "Using suggested name:"
assert_contains "shows the suggested name value" "$out" "$exp_name"
assert_contains "reports the suggested IP"   "$out" "Using suggested IP:"
assert_contains "shows the suggested IP value" "$out" "$exp_ip"
assert_file "cert created with the suggested name" "$keys/$exp_name.crt"
signed_ip="$exp_ip"
out_cert="$("$NEBULA_BIN_PATH/nebula-cert" print -path "$keys/$exp_name.crt" 2>&1)"
assert_contains "signed cert carries the suggested IP" "$out_cert" "${signed_ip%%/*}"

# explicit flags still win over suggestions
out="$("$NM" sign --cert-dir "$keys" --name pinned.mesh.demo --ip 10.100.0.200/24 2>&1)"; rc=$?
assert_eq "explicit name/ip sign succeeds" "$rc" "0"
assert_file "explicit name respected" "$keys/pinned.mesh.demo.crt"
assert_not_contains "did not suggest when both given" "$out" "Using suggested"

# --- empty store: signing cannot be suggested -> clear error ---
out="$("$NM" sign --cert-dir "$empty" 2>&1)"; rc=$?
assert_eq "sign fails cleanly without a CA/suggestions" "$rc" "2"
assert_contains "explains the failure" "$out" "Could not derive"

harness_summary
