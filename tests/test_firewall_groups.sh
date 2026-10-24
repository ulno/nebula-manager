#!/usr/bin/env bash
# Test: firewall group picker, rule templates, explain/diff and CLI.
#   * groups are discovered from the certificate workspace, with counts
#   * the picker preselects the rule's groups and accepts manual names
#   * templates add inbound/outbound group rules and can restrict the default
#   * _edit_firewall_rule uses the picker (no free-text group prompt)
#   * explain shows defaults, rules, match counts and flags unknown groups
#   * the firewall diff asks before saving; decline leaves the source alone
#   * user-owned configs never need sudo
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="firewall groups/templates"
harness_init
require_cmd nebula-cert
require_cmd yq
require_cmd jq
require_yq_v4 || exit 77

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"

# --- fixture: certs with groups + a firewall config -------------------------
CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 \
    || { echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="alpha.mesh" SIGN_IP="10.42.0.2/24" SIGN_GROUPS="home,admin" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="beta.mesh" SIGN_IP="10.42.0.3/24" SIGN_GROUPS="home" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="phone.mesh" SIGN_IP="10.42.0.4/24" SIGN_GROUPS="mobile" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1

cfg="$SANDBOX/config.yml"
cat > "$cfg" <<'YAML'
firewall:
  inbound_action: drop
  outbound_action: accept
  inbound:
    - port: any
      proto: any
      groups:
        - home
  outbound:
    - port: any
      proto: any
      host: any
YAML

rule_groups() {  # <file> <direction> <index>
    yq -r ".firewall.$2[$3].groups // [] | join(\",\")" "$1"
}

# --- discovery --------------------------------------------------------------
known="$(firewall_known_groups "$keys")"
assert_contains "known groups include home"   "$known" "home"
assert_contains "home count is 2"             "$known" $'home\t2'
assert_contains "admin count is 1"            "$known" $'admin\t1'
assert_contains "mobile count is 1"           "$known" $'mobile\t1'
assert_eq "most-used group comes first" "$(printf '%s\n' "$known" | head -n1 | cut -f1)" "home"

# --- group picker (plain mode) ---------------------------------------------
out="$(printf '\n' | firewall_pick_groups 'home,admin')"
assert_eq "picker keeps defaults on Enter" "$out" "home,admin"

out="$(printf '1,3\n' | firewall_pick_groups 'home,admin')"
assert_eq "picker accepts a numeric multi-selection" "$out" "home,mobile"

out="$(printf 'none\n' | firewall_pick_groups 'home')"
assert_eq "picker can clear the selection" "$out" ""

out="$(printf '4\nnewnode\n' | firewall_pick_groups '')"
assert_eq "picker accepts a manual group name" "$out" "newnode"

out="$(printf '4\nbad name\n' | firewall_pick_groups '')"
assert_eq "picker ignores an invalid manual name" "$out" ""

# A group already on the rule is kept even if no certificate carries it.
out="$(printf '\n' | firewall_pick_groups 'ghost')"
assert_eq "picker keeps unknown groups already on the rule" "$out" "ghost"

# With no workspace at all, the manual entry is preselected.
mkdir -p "$SANDBOX/nokeys"
cfg_old="$CERT_DIR_OVERRIDE"
CERT_DIR_OVERRIDE="$SANDBOX/nokeys"
out="$(printf '\nfresh\n' | firewall_pick_groups '')"
CERT_DIR_OVERRIDE="$cfg_old"
assert_eq "picker falls back to manual with no certs" "$out" "fresh"

# --- rule creation + templates ---------------------------------------------
firewall_add_rule "$cfg" inbound 22 tcp "home,admin"
rc=$?
assert_eq "add rule succeeds" "$rc" "0"
assert_eq "added rule port"   "$(yq -r '.firewall.inbound[-1].port' "$cfg")"  "22"
assert_eq "added rule proto"  "$(yq -r '.firewall.inbound[-1].proto' "$cfg")" "tcp"
assert_eq "added rule groups" "$(rule_groups "$cfg" inbound -1)" "home,admin"

firewall_apply_template "$cfg" allow-ssh "mobile"
assert_eq "allow-ssh port"   "$(yq -r '.firewall.inbound[-1].port' "$cfg")"  "22"
assert_eq "allow-ssh groups" "$(rule_groups "$cfg" inbound -1)" "mobile"

firewall_apply_template "$cfg" allow-port "home" "51820" "udp"
assert_eq "allow-port port"  "$(yq -r '.firewall.inbound[-1].port' "$cfg")"  "51820"
assert_eq "allow-port proto" "$(yq -r '.firewall.inbound[-1].proto' "$cfg")" "udp"

firewall_apply_template "$cfg" out-any "home"
assert_eq "out-any groups" "$(rule_groups "$cfg" outbound -1)" "home"

firewall_apply_template "$cfg" restrict "home"
assert_eq "restrict sets inbound_action" "$(yq -r '.firewall.inbound_action' "$cfg")" "drop"
assert_eq "restrict adds the allow rule" "$(rule_groups "$cfg" inbound -1)" "home"

if firewall_add_rule "$cfg" inbound "notaport" tcp "home" >/dev/null 2>&1; then
    _bad "invalid port is rejected"
else
    _ok "invalid port is rejected"
fi
if firewall_add_rule "$cfg" sideway any any "home" >/dev/null 2>&1; then
    _bad "invalid direction is rejected"
else
    _ok "invalid direction is rejected"
fi

# A config without any firewall section is initialised safely.
empty="$SANDBOX/empty.yml"; printf '{}\n' > "$empty"
firewall_add_rule "$empty" inbound any any "home"
assert_eq "empty config gets a rule"     "$(rule_groups "$empty" inbound -1)" "home"
assert_eq "empty config gets defaults"   "$(yq -r '.firewall.inbound[0].port' "$empty")" "any"
firewall_apply_template "$empty" restrict "home"
assert_eq "restrict initialises firewall" "$(yq -r '.firewall.inbound_action' "$empty")" "drop"

# --- editor integration: the group section is the picker -------------------
cfg2="$SANDBOX/config2.yml"; cp "$cfg" "$cfg2"
printf 'any\nany\n\n\n\n1\n' | _edit_firewall_rule append "$cfg2" inbound >/dev/null 2>&1
assert_eq "_edit_firewall_rule used the picker" "$(rule_groups "$cfg2" inbound -1)" "home"

empty2="$SANDBOX/empty2.yml"; printf '{}\n' > "$empty2"
printf 'any\nany\n\n\n\n1\n' | _edit_firewall_rule append "$empty2" inbound >/dev/null 2>&1
assert_eq "_edit_firewall_rule initialises an empty config" "$(rule_groups "$empty2" inbound -1)" "home"

# --- template TUI wrapper ---------------------------------------------------
cfg4="$SANDBOX/config4.yml"; cp "$cfg" "$cfg4"
printf '1\n1\nn\n' | FIREWALL_CONFIG_EDIT="$cfg4" configure_firewall_templates >/dev/null 2>&1
assert_eq "template menu added an inbound rule" "$(rule_groups "$cfg4" inbound -1)" "home"
assert_eq "template menu used any/any" "$(yq -r '.firewall.inbound[-1].port' "$cfg4")" "any"

# --- explain ----------------------------------------------------------------
explain="$(firewall_explain "$cfg" 2>&1)"
assert_contains "explain: inbound default"  "$explain" "Inbound default:  drop"
assert_contains "explain: outbound default" "$explain" "Outbound default: accept"
assert_contains "explain: group rule"       "$explain" "groups [home]"
assert_contains "explain: match count"      "$explain" "2 cert(s) match"
assert_contains "explain: host any is any peer" "$explain" "any peer"
assert_contains "explain: workspace groups" "$explain" "home"

cfg3="$SANDBOX/config3.yml"; cp "$cfg" "$cfg3"
firewall_add_rule "$cfg3" inbound any any "ghost" >/dev/null 2>&1
warn="$(firewall_explain "$cfg3" 2>&1)"
assert_contains "explain warns about an unknown rule group" "$warn" "Group 'ghost' is used in a rule"

# --- diff + save prompt -----------------------------------------------------
work="$SANDBOX/work.yml"; cp "$cfg" "$work"
firewall_diff_text "$cfg" "$work" >/dev/null; rc=$?
assert_eq "identical firewall -> no diff" "$rc" "1"

yq -i '.firewall.inbound[0].port = "2222"' "$work"
difftext="$(firewall_diff_text "$cfg" "$work")"
assert_contains "diff has a before/after header" "$difftext" "before"
assert_contains "diff shows the changed port"   "$difftext" "2222"

printf 'n\n' | firewall_commit_with_preview "$cfg" "$work" >/dev/null 2>&1; rc=$?
assert_eq "declining the preview cancels the save" "$rc" "1"
printf 'y\n' | firewall_commit_with_preview "$cfg" "$work" >/dev/null 2>&1; rc=$?
assert_eq "accepting the preview allows the save" "$rc" "0"

# End-to-end: declining in the firewall menu restores an in-place writable file.
neb="$SANDBOX/neb"; mkdir -p "$neb"; cp "$cfg" "$neb/config.yml"
before_hash="$(sha256sum "$neb/config.yml" | cut -d' ' -f1)"
old_nebula_dir="${NEBULA_DIR:-}"
NEBULA_DIR="$neb"
printf '1\nadd\nany\nany\n\n\n\nnone\nskip\n6\nn\n' | manage_firewall >/dev/null 2>&1
after_hash="$(sha256sum "$neb/config.yml" | cut -d' ' -f1)"
if [[ -n "$old_nebula_dir" ]]; then NEBULA_DIR="$old_nebula_dir"; else unset NEBULA_DIR; fi
assert_eq "declining the firewall preview restores the file" "$after_hash" "$before_hash"

# --- CLI --------------------------------------------------------------------
cli="$(bash "$REPO_ROOT/nebula-manager" firewall explain --nebula-config "$cfg" --cert-dir "$keys" 2>&1)"
assert_contains "CLI explain runs"          "$cli" "Inbound rules"
assert_contains "CLI explain shows the group rule" "$cli" "groups [home]"

gout="$(bash "$REPO_ROOT/nebula-manager" firewall groups --cert-dir "$keys" 2>&1)"
assert_contains "CLI groups lists home"     "$gout" "home"
assert_contains "CLI groups shows a count"  "$gout" "2 cert(s)"

if bash "$REPO_ROOT/nebula-manager" firewall explain --nebula-config "$SANDBOX/missing.yml" >/dev/null 2>&1; then
    _bad "CLI explain fails cleanly on a missing config"
else
    _ok "CLI explain fails cleanly on a missing config"
fi

# --- safety -----------------------------------------------------------------
assert_eq "no sudo used for user-owned configs" "$(sudo_count)" "0"

harness_summary
