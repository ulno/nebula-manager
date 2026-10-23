#!/usr/bin/env bash
# Test: rename/migrate a group across certificates.
#   * preview lists only the certificates that carry the old group
#   * re-signing replaces the group (deduplicated, order preserved)
#   * untouched certificates and all private keys stay byte-identical
#   * originals are backed up to <name>.crt.bak
#   * no sudo is required in a user-owned store
#   * the CLI (rename-group) behaves the same as the library helpers
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="rename-group"
harness_init
require_cmd nebula-cert
require_cmd jq

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"

groups_of() {
    nebula_cert_json "$(dirname "$(pki_cert_bin)")" "$1" | jq -r '(.details.groups // []) | join(",")'
}

# --- fixture: CA + four certs -----------------------------------------------
CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 \
    || { echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="alpha.mesh" SIGN_IP="10.42.0.2/24" SIGN_GROUPS="laptops,admin" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="beta.mesh" SIGN_IP="10.42.0.3/24" SIGN_GROUPS="laptops,infra" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="gamma.mesh" SIGN_IP="10.42.0.4/24" SIGN_GROUPS="desktops" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
# Already carries the target group as well as the old one.
SIGN_NAME="delta.mesh" SIGN_IP="10.42.0.5/24" SIGN_GROUPS="laptops,ulno,admin" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
# Routed subnet must survive the re-sign.
SIGN_NAME="eta.mesh" SIGN_IP="10.42.0.8/24" SIGN_GROUPS="laptops,router" \
    SIGN_SUBNETS="192.168.50.0/24" CERT_DIR="$keys" pki_sign >/dev/null 2>&1
assert_file "fixture alpha.crt" "$keys/alpha.mesh.crt"
assert_file "fixture beta.crt"  "$keys/beta.mesh.crt"
assert_file "fixture gamma.crt" "$keys/gamma.mesh.crt"
assert_file "fixture delta.crt" "$keys/delta.mesh.crt"

# --- group replacement helper (pure) ----------------------------------------
assert_eq "replaces and dedupes" \
    "$(_pki_groups_replace 'laptops,admin,laptops' laptops ulno)" "ulno,admin"
assert_eq "drops a duplicate that is already present" \
    "$(_pki_groups_replace 'laptops,ulno,admin' laptops ulno)" "ulno,admin"
assert_eq "keeps the list when the old group is absent" \
    "$(_pki_groups_replace 'a,b' laptops ulno)" "a,b"
assert_eq "trims whitespace" \
    "$(_pki_groups_replace ' laptops , admin ' laptops ulno)" "ulno,admin"

# --- scan + preview ---------------------------------------------------------
gamma_before="$(sha256sum "$keys/gamma.mesh.crt" | cut -d' ' -f1)"
alpha_key_before="$(sha256sum "$keys/alpha.mesh.key" | cut -d' ' -f1)"
beta_key_before="$(sha256sum "$keys/beta.mesh.key" | cut -d' ' -f1)"
ca_key_before="$(sha256sum "$keys/ca.key" | cut -d' ' -f1)"
ca_crt_before="$(sha256sum "$keys/ca.crt" | cut -d' ' -f1)"
alpha_na_before="$(date -d "$(nebula_cert_json "$(dirname "$(pki_cert_bin)")" "$keys/alpha.mesh.crt" | jq -r '.details.notAfter')" +%s)"

if pki_group_scan laptops ulno "$keys"; then _ok "scan finds certificates with 'laptops'"
else _bad "scan finds certificates with 'laptops'"; fi
assert_eq "scan matched alpha, beta, delta and eta (not gamma/CA)" "${#PKI_RENAME_FILES[@]}" "4"

preview="$(pki_group_preview_text laptops ulno)"
assert_contains "preview mentions alpha" "$preview" "alpha.mesh.crt"
assert_contains "preview shows alpha's old->new" "$preview" "[laptops,admin] -> [ulno,admin]"
assert_contains "preview shows beta's old->new" "$preview" "[laptops,infra] -> [ulno,infra]"
assert_contains "preview deduplicates delta" "$preview" "[laptops,ulno,admin] -> [ulno,admin]"
assert_not_contains "preview omits unaffected gamma" "$preview" "gamma.mesh.crt"
assert_not_contains "preview omits the CA" "$preview" "ca.crt"
# Regression: every line must be separated (a $(...) capture used to eat the
# trailing newlines and glue the preview into one unreadable blob).
preview_lines="$(printf '%s\n' "$preview" | grep -c .)"
assert_eq "preview keeps one line per match" "$preview_lines" "$(( ${#PKI_RENAME_FILES[@]} + 2 ))"

# --- apply ------------------------------------------------------------------
pki_group_apply "$keys" >/dev/null 2>&1
assert_eq "apply succeeded" "$?" "0"

assert_eq "alpha now uses the new group" "$(groups_of "$keys/alpha.mesh.crt")" "ulno,admin"
assert_eq "beta now uses the new group"  "$(groups_of "$keys/beta.mesh.crt")"  "ulno,infra"
assert_eq "delta was deduplicated"       "$(groups_of "$keys/delta.mesh.crt")" "ulno,admin"
assert_eq "eta now uses the new group"   "$(groups_of "$keys/eta.mesh.crt")"   "ulno,router"
assert_eq "eta keeps its routed subnet" \
    "$(nebula_cert_json "$(dirname "$(pki_cert_bin)")" "$keys/eta.mesh.crt" | jq -r '.details.subnets | join(",")')" \
    "192.168.50.0/24"
assert_eq "gamma's groups untouched"     "$(groups_of "$keys/gamma.mesh.crt")" "desktops"

assert_file "alpha backed up" "$keys/alpha.mesh.crt.bak"
assert_file "beta backed up"  "$keys/beta.mesh.crt.bak"
assert_file "delta backed up" "$keys/delta.mesh.crt.bak"
assert_no_file "unaffected gamma has no backup" "$keys/gamma.mesh.crt.bak"
assert_no_file "the CA is not backed up/renamed" "$keys/ca.crt.bak"

assert_eq "backup holds the original alpha groups" \
    "$(groups_of "$keys/alpha.mesh.crt.bak")" "laptops,admin"

# --- untouched files and keys ----------------------------------------------
assert_eq "unaffected certificate bytes unchanged" \
    "$(sha256sum "$keys/gamma.mesh.crt" | cut -d' ' -f1)" "$gamma_before"
assert_eq "alpha private key untouched" \
    "$(sha256sum "$keys/alpha.mesh.key" | cut -d' ' -f1)" "$alpha_key_before"
assert_eq "beta private key untouched" \
    "$(sha256sum "$keys/beta.mesh.key" | cut -d' ' -f1)" "$beta_key_before"
assert_eq "CA key untouched" \
    "$(sha256sum "$keys/ca.key" | cut -d' ' -f1)" "$ca_key_before"
assert_eq "CA cert untouched" \
    "$(sha256sum "$keys/ca.crt" | cut -d' ' -f1)" "$ca_crt_before"

# --- re-signing preserved name/IP/expiry -----------------------------------
json="$(nebula_cert_json "$(dirname "$(pki_cert_bin)")" "$keys/alpha.mesh.crt")"
assert_eq "name preserved" "$(jq -r '.details.name' <<<"$json")" "alpha.mesh"
assert_eq "IP preserved"   "$(jq -r '.details.ips | join(",")' <<<"$json")" "10.42.0.2/24"
# Re-signing must not silently extend or shorten the certificate's lifetime.
alpha_na_after="$(date -d "$(jq -r '.details.notAfter' <<<"$json")" +%s)"
na_delta=$(( alpha_na_after - alpha_na_before ))
(( na_delta < 0 )) && na_delta=$(( -na_delta ))
if (( na_delta <= 5 )); then _ok "expiry preserved (delta ${na_delta}s)"
else _bad "expiry preserved" "delta ${na_delta}s"; fi

# --- no match ---------------------------------------------------------------
if pki_group_scan nosuchgroup x "$keys"; then
    _bad "scan reports no match for an unknown group"
else
    _ok "scan reports no match for an unknown group"
fi

# --- least privilege --------------------------------------------------------
assert_eq "no sudo used for user-owned PKI" "$(sudo_count)" "0"

# --- CLI --------------------------------------------------------------------
SIGN_NAME="epsilon.mesh" SIGN_IP="10.42.0.6/24" SIGN_GROUPS="lab2" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
cli_out="$(bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" rename-group lab2 lab3 --yes 2>&1)"
cli_rc=$?
assert_eq "CLI exit status" "$cli_rc" "0"
assert_contains "CLI previews the change" "$cli_out" "[lab2] -> [lab3]"
assert_contains "CLI reports the re-sign" "$cli_out" "Re-signed"
assert_eq "CLI changed epsilon's group" "$(groups_of "$keys/epsilon.mesh.crt")" "lab3"
assert_file "CLI left a backup" "$keys/epsilon.mesh.crt.bak"
assert_eq "CLI still used no sudo" "$(sudo_count)" "0"

# CLI refuses to act non-interactively without --yes.
SIGN_NAME="zeta.mesh" SIGN_IP="10.42.0.7/24" SIGN_GROUPS="lab9" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
if bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" rename-group lab9 lab10 </dev/null >/dev/null 2>&1; then
    _bad "CLI refuses without --yes on a non-tty"
else
    _ok "CLI refuses without --yes on a non-tty"
fi
assert_eq "refused run left the certificate alone" \
    "$(groups_of "$keys/zeta.mesh.crt")" "lab9"
assert_no_file "refused run created no backup" "$keys/zeta.mesh.crt.bak"

# --- privileged workspace: writes are routed through elevate() --------------
# A root-owned store cannot be written as the current user, so the sign/backup/
# write steps must go through elevate() (which announces the reason + command).
priv="$SANDBOX/privkeys"
cp -a "$keys" "$priv"
SIGN_NAME="theta.mesh" SIGN_IP="10.42.0.9/24" SIGN_GROUPS="privgroup,admin" \
    CERT_DIR="$priv" pki_sign >/dev/null 2>&1
elevate_log="$SANDBOX/elevate.log"
: > "$elevate_log"
elevate() { printf 'elevate %s\n' "$*" >> "$elevate_log"; "$@"; }
path_requires_root() { return 0; }   # pretend an /etc/nebula-like workspace
pki_group_scan privgroup privgroup2 "$priv"
pki_group_apply "$priv" >/dev/null 2>&1
priv_rc=$?
assert_eq "privileged apply succeeded" "$priv_rc" "0"
assert_contains "sign routed through elevate"   "$(cat "$elevate_log")" "sign -name theta.mesh"
assert_contains "backup routed through elevate" "$(cat "$elevate_log")" "cp -p"
assert_eq "privileged rename applied" "$(groups_of "$priv/theta.mesh.crt")" "privgroup2,admin"
assert_file "privileged backup written" "$priv/theta.mesh.crt.bak"
assert_eq "never invoked mocked sudo directly" "$(sudo_count)" "0"

harness_summary
