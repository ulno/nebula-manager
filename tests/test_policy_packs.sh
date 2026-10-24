#!/usr/bin/env bash
# Test: firewall policy packs.
#   * create/list/show/validate a pack from a Nebula config
#   * suggest a pack for certificates whose groups match
#   * embed a pack into a generated client config/bundle (CLI + TUI)
#   * export per-host firewall.yml + README for a selection
#   * apply a pack to a local config (working copy, backup, --yes)
#   * no sudo for user-owned files
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="firewall policy packs"
harness_init
require_cmd nebula-cert
require_cmd yq
require_cmd jq
require_yq_v4 || exit 77

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"
BIN_PATH="$(dirname "$(pki_cert_bin)")"

CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 \
    || { echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="home1.mesh" SIGN_IP="10.42.0.2/24" SIGN_GROUPS="home" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="home2.mesh" SIGN_IP="10.42.0.3/24" SIGN_GROUPS="home" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="roam.mesh" SIGN_IP="10.42.0.4/24" SIGN_GROUPS="mobile" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1

src="$SANDBOX/source.yml"
cat > "$src" <<'YAML'
firewall:
  inbound_action: drop
  inbound:
    - port: any
      proto: any
      groups:
        - home
    - port: 22
      proto: tcp
      groups:
        - admin
  outbound:
    - port: any
      proto: any
      host: any
YAML



# --- create / list / show / validate ---------------------------------------
policy_path_file="$(policy_dir)/home.yml"
assert_no_file "no pack before creation" "$policy_path_file"

policy_create_from_config "home" "$src" "home" "Home machines" >/dev/null
assert_file "pack created" "$policy_path_file"
assert_eq "pack name"   "$(yq -r '.name' "$policy_path_file")" "home"
assert_eq "pack groups" "$(yq -r '.groups | join(",")' "$policy_path_file")" "home"
assert_eq "pack description" "$(yq -r '.description' "$policy_path_file")" "Home machines"
assert_eq "pack carries the firewall" "$(yq -r '.firewall.inbound_action' "$policy_path_file")" "drop"
assert_eq "pack carries the group rule" \
    "$(yq -r '.firewall.inbound[0].groups | join(",")' "$policy_path_file")" "home"

if policy_validate "$policy_path_file"; then _ok "pack validates"; else _bad "pack validates"; fi

list="$(policy_list)"
assert_contains "list shows the pack" "$list" "home"
assert_contains "list shows the target group" "$list" "home"
assert_contains "list shows the rule count" "$list" "3 rule(s)"

show="$(policy_show home)"
assert_contains "show prints the firewall" "$show" "inbound_action: drop"

# overwrite protection
if policy_create_from_config "home" "$src" "home" "again" >/dev/null 2>&1; then
    _bad "existing pack is not overwritten without force"
else
    _ok "existing pack is not overwritten without force"
fi
policy_create_from_config "home" "$src" "home" "again" 1 >/dev/null
assert_eq "force overwrites the description" "$(yq -r '.description' "$policy_path_file")" "again"

# --- suggestions ------------------------------------------------------------
sugg="$(policy_suggest_for_cert home1.mesh "$keys")"
assert_eq "suggests the pack for a matching group" "$sugg" "home"
sugg="$(policy_suggest_for_cert roam.mesh "$keys")"
assert_eq "no suggestion for an unrelated group" "$sugg" ""

# --- embed in a generated client config ------------------------------------
tmpl="$SANDBOX/config.yml.template"
pki_write_client_config "$tmpl" "home1.mesh" "$keys" "$(policy_resolve home)"
assert_contains "template names the pack" "$(cat "$tmpl")" "Firewall policy pack: home"
assert_eq "template uses the pack's default action" "$(yq -r '.firewall.inbound_action' "$tmpl")" "drop"
assert_eq "template uses the pack's group rule" \
    "$(yq -r '.firewall.inbound[0].groups | join(",")' "$tmpl")" "home"
assert_eq "template still has the pki section" "$(yq -r '.pki.ca' "$tmpl")" "/etc/nebula/ca.crt"

# --- bundles embed the pack ------------------------------------------------
mkdir -p "$SANDBOX/out"
pki_bundle_client_zip home1.mesh "$SANDBOX/out" "$keys" "$(policy_resolve home)" >/dev/null
zipfile="$SANDBOX/out/home1.mesh-nebula-bundle.zip"
assert_file "bundle with a policy was created" "$zipfile"
if command -v unzip >/dev/null 2>&1; then
    unzip -p "$zipfile" config.yml.template > "$SANDBOX/fromzip.yml"
    assert_eq "zip template uses the policy" \
        "$(yq -r '.firewall.inbound_action' "$SANDBOX/fromzip.yml")" "drop"
else
    _ok "unzip unavailable - skipping zip content check"
fi

# --- CLI bundle --policy ----------------------------------------------------
mkdir -p "$SANDBOX/cliout"
cli="$(bash "$REPO_ROOT/nebula-manager" cert bundle home1.mesh --cert-dir "$keys" \
    --out "$SANDBOX/cliout" --policy home 2>&1)"
assert_eq "CLI bundle exit status" "$?" "0"
assert_contains "CLI reports the policy" "$cli" "policy pack: home"
assert_file "CLI bundle exists" "$SANDBOX/cliout/home1.mesh-nebula-bundle.zip"

# Without --policy the CLI only suggests, never applies.
mkdir -p "$SANDBOX/cliout2"
hint="$(bash "$REPO_ROOT/nebula-manager" cert bundle home1.mesh --cert-dir "$keys" \
    --out "$SANDBOX/cliout2" 2>&1)"
assert_contains "CLI suggests the pack" "$hint" "Suggested policy pack"
assert_contains "CLI says nothing is automatic" "$hint" "nothing is applied automatically"
if command -v unzip >/dev/null 2>&1; then
    unzip -p "$SANDBOX/cliout2/home1.mesh-nebula-bundle.zip" config.yml.template > "$SANDBOX/nopolicy.yml"
    if grep -q 'Firewall policy pack:' "$SANDBOX/nopolicy.yml"; then
        _bad "CLI does not silently embed a suggested policy"
    else
        _ok "CLI does not silently embed a suggested policy"
    fi
fi

# --- TUI bundle asks about the suggested pack ------------------------------
mkdir -p "$SANDBOX/tuiout"
# 1 = first exportable cert (home1), 2 = pack 'home' (none is 1), then out dir
printf '1\n2\n%s\n' "$SANDBOX/tuiout" | pki_bundle_client_menu >/dev/null 2>&1
assert_file "TUI bundle exists" "$SANDBOX/tuiout/home1.mesh-nebula-bundle.zip"
if command -v unzip >/dev/null 2>&1; then
    unzip -p "$SANDBOX/tuiout/home1.mesh-nebula-bundle.zip" config.yml.template > "$SANDBOX/tuipolicy.yml"
    assert_eq "TUI bundle uses the chosen policy" \
        "$(yq -r '.firewall.inbound_action' "$SANDBOX/tuipolicy.yml")" "drop"
fi

# --- export per host --------------------------------------------------------
bash "$REPO_ROOT/nebula-manager" policy export --pack home --select group:home \
    --out "$SANDBOX/policies" --cert-dir "$keys" >/dev/null 2>&1
assert_file "export wrote home1" "$SANDBOX/policies/home1.mesh/firewall.yml"
assert_file "export wrote home2" "$SANDBOX/policies/home2.mesh/firewall.yml"
assert_no_file "export skipped the unrelated cert" "$SANDBOX/policies/roam.mesh/firewall.yml"
assert_file "export wrote install notes" "$SANDBOX/policies/home1.mesh/README.txt"
assert_eq "exported fragment is the firewall map" \
    "$(yq -r '.inbound_action' "$SANDBOX/policies/home1.mesh/firewall.yml")" "drop"
assert_contains "install notes name the pack" \
    "$(cat "$SANDBOX/policies/home1.mesh/README.txt")" "Policy pack : home"

# --- apply to a local config ------------------------------------------------
apply="$SANDBOX/apply.yml"
cat > "$apply" <<'YAML'
firewall:
  inbound_action: accept
  inbound: []
  outbound:
    - port: any
      proto: any
      host: any
YAML
bash "$REPO_ROOT/nebula-manager" policy apply --pack home --nebula-config "$apply" --yes >/dev/null 2>&1
assert_eq "apply replaced the default action" "$(yq -r '.firewall.inbound_action' "$apply")" "drop"
assert_eq "apply replaced the inbound rules" \
    "$(yq -r '.firewall.inbound[0].groups | join(",")' "$apply")" "home"

# --- CLI new / validate / delete -------------------------------------------
bash "$REPO_ROOT/nebula-manager" policy new imported --from-config "$src" \
    --groups home --description "Imported" >/dev/null 2>&1
assert_file "CLI created a pack" "$(policy_dir)/imported.yml"
bash "$REPO_ROOT/nebula-manager" policy validate imported >/dev/null 2>&1
assert_eq "CLI validate exits 0" "$?" "0"
bash "$REPO_ROOT/nebula-manager" policy delete imported --yes >/dev/null 2>&1
assert_no_file "CLI deleted the pack" "$(policy_dir)/imported.yml"

# --- safety -----------------------------------------------------------------
assert_eq "no sudo used anywhere" "$(sudo_count)" "0"

harness_summary
