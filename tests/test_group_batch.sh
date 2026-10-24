#!/usr/bin/env bash
# Test: certificate selector + batch group actions (add/remove/move/set/prune).
#   * selector grammar: all / group / without / name glob / ip CIDR / cert / exclude
#   * add is a union (never replaces), remove subtracts, move is one re-sign
#   * set replaces the whole list (and can clear it)
#   * prune (remove only from matches) is expressed as select + remove
#   * CLI: idempotency, --dry-run, non-tty refusal, group list
#   * plain-mode ui_checklist parsing (all/none/ranges/defaults/invalid)
#   * nothing needs sudo in a user-owned store
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="group batch actions"
harness_init
require_cmd nebula-cert
require_cmd jq

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"
BIN_PATH="$(dirname "$(pki_cert_bin)")"

groups_of() {
    nebula_cert_json "$BIN_PATH" "$1" | jq -r '(.details.groups // []) | join(",")'
}
sel_names() { printf '%s\n' "${SEL_NAMES[@]}" | sort | paste -sd, -; }
hash_of() { sha256sum "$1" | cut -d' ' -f1; }

# --- fixture ----------------------------------------------------------------
CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 \
    || { echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="alpha.mesh" SIGN_IP="10.42.0.2/24" SIGN_GROUPS="laptops,admin" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="beta.mesh" SIGN_IP="10.42.0.3/24" SIGN_GROUPS="laptops" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="gamma.mesh" SIGN_IP="10.42.0.4/24" SIGN_GROUPS="desktops" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="delta.mesh" SIGN_IP="10.42.0.5/24" SIGN_GROUPS="home,laptops" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
gamma_before="$(hash_of "$keys/gamma.mesh.crt")"
gamma_key_before="$(hash_of "$keys/gamma.mesh.key")"

# --- selector grammar -------------------------------------------------------
cert_select "$keys" --select all >/dev/null
assert_eq "selector: all" "$(sel_names)" "alpha.mesh,beta.mesh,delta.mesh,gamma.mesh"
assert_eq "selector: all excludes the CA" "${#SEL_FILES[@]}" "4"

cert_select "$keys" --select group:laptops >/dev/null
assert_eq "selector: group" "$(sel_names)" "alpha.mesh,beta.mesh,delta.mesh"

cert_select "$keys" --select without:laptops >/dev/null
assert_eq "selector: without" "$(sel_names)" "gamma.mesh"

cert_select "$keys" --select name:al\* >/dev/null
assert_eq "selector: name glob" "$(sel_names)" "alpha.mesh"

cert_select "$keys" --select ip:10.42.0.0/30 >/dev/null
assert_eq "selector: ip CIDR containment" "$(sel_names)" "alpha.mesh,beta.mesh"

cert_select "$keys" --select ip:10.42.0.3/32 >/dev/null
assert_eq "selector: ip address" "$(sel_names)" "beta.mesh"

cert_select "$keys" --select cert:BETA.MESH >/dev/null
assert_eq "selector: cert name is case-insensitive" "$(sel_names)" "beta.mesh"

cert_select "$keys" --select alpha.mesh >/dev/null
assert_eq "selector: bare value is a cert name" "$(sel_names)" "alpha.mesh"

cert_select "$keys" --select group:home --select group:admin >/dev/null
assert_eq "selector: repeated --select unions" "$(sel_names)" "alpha.mesh,delta.mesh"

cert_select "$keys" --select all --exclude group:laptops >/dev/null
assert_eq "selector: --exclude subtracts" "$(sel_names)" "gamma.mesh"

if cert_select "$keys" --select group:nosuch >/dev/null 2>&1; then
    _bad "selector: no match returns non-zero"
else
    _ok "selector: no match returns non-zero"
fi

# --- helper: select then plan; sets PLAN_RC and PKI_RENAME_* ----------------
plan() {  # plan <selector-args...> -- <action> [args]
    local -a selargs=()
    while (( $# )) && [[ "${1:-}" != "--" ]]; do selargs+=("$1"); shift; done
    (( $# )) && shift
    cert_select "$keys" "${selargs[@]}" >/dev/null 2>&1 || { PLAN_RC=1; return 1; }
    pki_group_plan "$@"
    PLAN_RC=$?
    return 0
}

# --- add is a union ---------------------------------------------------------
plan --select group:laptops -- add extra
assert_eq "add: plan covers the 3 laptops" "${#PKI_RENAME_FILES[@]}" "3"
assert_contains "add: preview keeps existing groups" "$(pki_group_diff_text "Add 'extra'")" "[laptops,admin] -> [laptops,admin,extra]"
pki_group_apply "$keys" >/dev/null 2>&1
assert_eq "add: alpha keeps admin and gains extra" "$(groups_of "$keys/alpha.mesh.crt")" "laptops,admin,extra"
assert_eq "add: beta gains extra" "$(groups_of "$keys/beta.mesh.crt")" "laptops,extra"
assert_eq "add: delta gains extra" "$(groups_of "$keys/delta.mesh.crt")" "home,laptops,extra"
assert_eq "add: gamma untouched (bytes)" "$(hash_of "$keys/gamma.mesh.crt")" "$gamma_before"

plan --select group:laptops -- add extra
assert_eq "add: idempotent when already present" "$PLAN_RC" "1"
assert_eq "add: idempotent plan is empty" "${#PKI_RENAME_FILES[@]}" "0"

# --- remove -----------------------------------------------------------------
plan --select group:extra -- remove extra
assert_eq "remove: plan covers the 3 certs" "${#PKI_RENAME_FILES[@]}" "3"
pki_group_apply "$keys" >/dev/null 2>&1
assert_eq "remove: alpha back to laptops,admin" "$(groups_of "$keys/alpha.mesh.crt")" "laptops,admin"
assert_eq "remove: beta back to laptops"        "$(groups_of "$keys/beta.mesh.crt")" "laptops"
assert_eq "remove: delta back to home,laptops"  "$(groups_of "$keys/delta.mesh.crt")" "home,laptops"

plan --select group:extra -- remove extra
assert_eq "remove: idempotent when absent" "$PLAN_RC" "1"

# --- move: one re-sign, in-place replacement + dedupe -----------------------
plan --select group:laptops -- move laptops home
assert_eq "move: one plan for all 3" "${#PKI_RENAME_FILES[@]}" "3"
assert_eq "move: alpha preview replaces in place" "$(printf '%s\n' "${PKI_RENAME_NEWGROUPS[@]}" | grep -c '^home,admin$')" "1"
pki_group_apply "$keys" >/dev/null 2>&1
assert_eq "move: alpha now home,admin" "$(groups_of "$keys/alpha.mesh.crt")" "home,admin"
assert_eq "move: beta now home"        "$(groups_of "$keys/beta.mesh.crt")" "home"
assert_eq "move: delta deduplicated"   "$(groups_of "$keys/delta.mesh.crt")" "home"
plan --select group:laptops -- move laptops home
assert_eq "move: no laptops left" "$PLAN_RC" "1"

# --- set --------------------------------------------------------------------
plan --select cert:gamma.mesh -- set student,g1
assert_eq "set: one plan" "${#PKI_RENAME_FILES[@]}" "1"
assert_eq "set: preview replaces everything" "${PKI_RENAME_NEWGROUPS[0]}" "student,g1"
pki_group_apply "$keys" >/dev/null 2>&1
assert_eq "set: gamma exactly student,g1" "$(groups_of "$keys/gamma.mesh.crt")" "student,g1"
assert_eq "set: gamma's private key untouched" "$(hash_of "$keys/gamma.mesh.key")" "$gamma_key_before"

# clear all groups with an empty set list
plan --select cert:gamma.mesh -- set ""
assert_eq "set: empty list clears groups" "${PKI_RENAME_NEWGROUPS[0]:-}" ""
pki_group_apply "$keys" >/dev/null 2>&1
assert_eq "set: gamma has no groups now" "$(groups_of "$keys/gamma.mesh.crt")" ""

# --- prune: remove only from certs that have another group ------------------
SIGN_NAME="epsilon.mesh" SIGN_IP="10.42.0.6/24" SIGN_GROUPS="laptops" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="zeta.mesh" SIGN_IP="10.42.0.7/24" SIGN_GROUPS="laptops,home" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
plan --select group:home -- remove laptops
assert_eq "prune: only matching certs are planned" "${#PKI_RENAME_FILES[@]}" "1"
assert_eq "prune: zeta loses laptops" "${PKI_RENAME_NEWGROUPS[0]}" "home"
pki_group_apply "$keys" >/dev/null 2>&1
assert_eq "prune: epsilon keeps laptops" "$(groups_of "$keys/epsilon.mesh.crt")" "laptops"
assert_eq "prune: zeta now home"         "$(groups_of "$keys/zeta.mesh.crt")" "home"

# --- plain ui_checklist -----------------------------------------------------
out="$(printf 'all\n' | ui_checklist "T" "P" a "A" on b "B" off)"
assert_eq "checklist: all" "$out" $'a\nb'
out="$(printf '2\n' | ui_checklist "T" "P" a "A" on b "B" off)"
assert_eq "checklist: single number" "$out" "b"
out="$(printf '1-2\n' | ui_checklist "T" "P" a "A" on b "B" off)"
assert_eq "checklist: range" "$out" $'a\nb'
out="$(printf 'none\n' | ui_checklist "T" "P" a "A" on b "B" off)"
assert_eq "checklist: none" "$out" ""
out="$(printf '\n' | ui_checklist "T" "P" a "A" on b "B" off)"
assert_eq "checklist: empty keeps defaults" "$out" "a"
out="$(printf '1,2,1\n' | ui_checklist "T" "P" a "A" off b "B" off)"
assert_eq "checklist: deduplicates" "$out" $'a\nb'
printf 'zzz\n' | ui_checklist "T" "P" a "A" on >/dev/null 2>&1; rc=$?
assert_eq "checklist: invalid input -> 2" "$rc" "2"

# --- CLI --------------------------------------------------------------------
list_out="$(bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group list 2>&1)"
assert_contains "CLI list shows a certificate" "$list_out" "alpha.mesh"
assert_contains "CLI list shows groups"        "$list_out" "home,admin"

cli_out="$(bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group add cli --select cert:epsilon.mesh --yes 2>&1)"
assert_eq "CLI add exit status" "$?" "0"
assert_contains "CLI add previews the change" "$cli_out" "[laptops] -> [laptops,cli]"
assert_eq "CLI add applied" "$(groups_of "$keys/epsilon.mesh.crt")" "laptops,cli"

bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group remove cli --select cert:epsilon.mesh --dry-run >/dev/null 2>&1
assert_eq "CLI dry-run leaves the cert alone" "$(groups_of "$keys/epsilon.mesh.crt")" "laptops,cli"

bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group remove cli --select cert:epsilon.mesh --yes >/dev/null 2>&1
assert_eq "CLI remove applied" "$(groups_of "$keys/epsilon.mesh.crt")" "laptops"

# idempotent CLI operation is success and changes nothing
if bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group remove cli --select cert:epsilon.mesh --yes >/dev/null 2>&1; then
    _ok "CLI idempotent remove exits 0"
else
    _bad "CLI idempotent remove exits 0"
fi

# refusal without --yes on a non-tty
if bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group add refused --select cert:epsilon.mesh </dev/null >/dev/null 2>&1; then
    _bad "CLI refuses without --yes on a non-tty"
else
    _ok "CLI refuses without --yes on a non-tty"
fi
assert_eq "refused CLI run left the cert alone" "$(groups_of "$keys/epsilon.mesh.crt")" "laptops"

# CLI move + prune + set
SIGN_NAME="theta.mesh" SIGN_IP="10.42.0.8/24" SIGN_GROUPS="laptops,home" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group move laptops home --select cert:theta.mesh --yes >/dev/null 2>&1
assert_eq "CLI move applied" "$(groups_of "$keys/theta.mesh.crt")" "home"

SIGN_NAME="iota.mesh" SIGN_IP="10.42.0.9/24" SIGN_GROUPS="laptops" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="kappa.mesh" SIGN_IP="10.42.0.10/24" SIGN_GROUPS="laptops,home" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group prune laptops --when group:home --yes >/dev/null 2>&1
assert_eq "CLI prune only touches matches" "$(groups_of "$keys/kappa.mesh.crt")" "home"
assert_eq "CLI prune keeps non-matches"    "$(groups_of "$keys/iota.mesh.crt")" "laptops"

bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group set "final,g2" --select cert:iota.mesh --yes >/dev/null 2>&1
assert_eq "CLI set applied" "$(groups_of "$keys/iota.mesh.crt")" "final,g2"

bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group set "" --select cert:iota.mesh --yes >/dev/null 2>&1
assert_eq "CLI set '' clears the groups" "$(groups_of "$keys/iota.mesh.crt")" ""

if bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group set --select cert:iota.mesh --yes </dev/null >/dev/null 2>&1; then
    _bad "CLI set without a list is refused"
else
    _ok "CLI set without a list is refused"
fi

# a missing selector is refused for broad actions
if bash "$REPO_ROOT/nebula-manager" --cert-dir "$keys" group set everything --yes </dev/null >/dev/null 2>&1; then
    _bad "CLI requires --select for set"
else
    _ok "CLI requires --select for set"
fi

# --- TUI batch editor (plain mode, piped answers) ---------------------------
# filter -> default checklist -> add 'tuigroup' -> confirm -> another action ->
# add 'tuigroup2' -> confirm -> stop. The second action also proves the
# selection is refreshed from disk after the first re-sign.
printf 'group:laptops\n\n1\ntuigroup\ny\ny\n1\ntuigroup2\ny\nn\n' \
    | pki_group_edit_tui >/dev/null 2>&1
assert_eq "TUI batch add applied twice (selection refreshed)" \
    "$(groups_of "$keys/epsilon.mesh.crt")" "laptops,tuigroup,tuigroup2"

# --- safety -----------------------------------------------------------------
assert_eq "no sudo used anywhere" "$(sudo_count)" "0"
assert_file "originals are backed up" "$keys/alpha.mesh.crt.bak"
assert_eq "unaffected certificate still byte-identical" \
    "$(hash_of "$keys/gamma.mesh.crt.bak")" "$gamma_before"

harness_summary
