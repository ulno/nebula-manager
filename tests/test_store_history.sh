#!/usr/bin/env bash
# Test: certificate-store action log + overwrite backups (folder and git).
#   * every CA/sign/group/remove/bundle action is recorded in nebula-manager.log
#   * a non-git store gets datestamped backups/<ts>-<reason>/ with the old files
#     (mode 600) and ACTION.txt
#   * a git store commits pending certificates *before* the overwrite and never
#     tracks private keys or backup folders
#   * CLI: cert store status/log/backup/git-init (+ top-level store alias)
#   * no sudo for user-owned stores
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="certificate store history"
harness_init
require_cmd nebula-cert
require_cmd jq
require_cmd git

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"
LOG="$keys/nebula-manager.log"

hash_of() { sha256sum "$1" | cut -d' ' -f1; }
latest_backup() { find "$keys/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1; }
backup_count() { find "$keys/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }

# --- fixture ----------------------------------------------------------------
CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 \
    || { echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="host1.mesh" SIGN_IP="10.42.0.2/24" SIGN_GROUPS="old,admin" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1

assert_file "action log created" "$LOG"
assert_contains "log records the CA"        "$(cat "$LOG")" "ca-create"
assert_contains "log records the signing"   "$(cat "$LOG")" 'sign name="host1.mesh"'

# --- folder backup before overwriting --------------------------------------
old_crt="$(hash_of "$keys/host1.mesh.crt")"
old_key="$(hash_of "$keys/host1.mesh.key")"
assert_eq "no backup yet" "$(backup_count)" "0"

SIGN_NAME="host1.mesh" SIGN_IP="10.42.0.2/24" SIGN_GROUPS="new,admin" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
assert_ne "certificate was replaced" "$(hash_of "$keys/host1.mesh.crt")" "$old_crt"
assert_ne "key was replaced"         "$(hash_of "$keys/host1.mesh.key")" "$old_key"

b1="$(latest_backup)"
assert_dir "backup folder created" "$b1"
assert_file "old certificate backed up" "$b1/host1.mesh.crt"
assert_file "old key backed up"         "$b1/host1.mesh.key"
assert_file "action file written"       "$b1/ACTION.txt"
assert_eq "backup holds the old cert" "$(hash_of "$b1/host1.mesh.crt")" "$old_crt"
assert_eq "backup holds the old key"  "$(hash_of "$b1/host1.mesh.key")"  "$old_key"
assert_contains "ACTION names the reason" "$(cat "$b1/ACTION.txt")" "reason: sign host1.mesh (overwrite)"

log="$(cat "$LOG")"
assert_contains "log records the snapshot" "$log" 'snapshot reason="sign host1.mesh (overwrite)" mode=folder'
assert_contains "log records overwrite=1"  "$log" 'overwrite=1'
assert_contains "log records the backup path" "$log" "$b1"

# --- manual snapshot + status ----------------------------------------------
before="$(backup_count)"
cert_store_snapshot_before "$keys" "manual-test" >/dev/null
after="$(backup_count)"
assert_eq "manual snapshot adds a folder" "$after" "$((before + 1))"
assert_contains "manual ACTION reason" "$(cat "$(latest_backup)/ACTION.txt")" "reason: manual-test"

status="$(cert_store_status "$keys")"
assert_contains "status shows no VCS" "$status" "VCS:               none"
assert_contains "status shows the log" "$status" "Action log:"
assert_contains "status shows backups" "$status" "Backup folders:"

# --- group re-sign snapshot -------------------------------------------------
SIGN_NAME="grp.mesh" SIGN_IP="10.42.0.3/24" SIGN_GROUPS="groupa" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
grp_crt="$(hash_of "$keys/grp.mesh.crt")"
cert_select "$keys" --select group:groupa >/dev/null
pki_group_plan add groupb
before="$(backup_count)"
pki_group_apply "$keys" >/dev/null 2>&1
assert_eq "group apply added a snapshot" "$(backup_count)" "$((before + 1))"
gb="$(latest_backup)"
assert_eq "group backup holds the old cert" "$(hash_of "$gb/grp.mesh.crt")" "$grp_crt"
assert_contains "group ACTION names the action" "$(cat "$gb/ACTION.txt")" "reason: group-add"
assert_contains "log records group-add" "$(cat "$LOG")" "group-add changed=1"

# --- CA overwrite backup ----------------------------------------------------
old_ca="$(hash_of "$keys/ca.crt")"
CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1
ca_backup="$(latest_backup)"
assert_eq "CA backup holds the old CA" "$(hash_of "$ca_backup/ca.crt")" "$old_ca"
assert_contains "CA ACTION reason" "$(cat "$ca_backup/ACTION.txt")" "reason: ca-create test-ca"

# --- git mode ---------------------------------------------------------------
gkeys="$SANDBOX/gitkeys"
export CERT_DIR_OVERRIDE="$gkeys"
CA_NAME="git-ca" CERT_DIR="$gkeys" pki_ca_create >/dev/null 2>&1
SIGN_NAME="git1.mesh" SIGN_IP="10.9.0.2/24" SIGN_GROUPS="old" \
    CERT_DIR="$gkeys" pki_sign >/dev/null 2>&1

cert_store_git_init "$gkeys" >/dev/null 2>&1
assert_file "gitignore created" "$gkeys/.gitignore"
assert_contains "gitignore excludes keys" "$(cat "$gkeys/.gitignore")" "*.key"
assert_contains "gitignore excludes backups" "$(cat "$gkeys/.gitignore")" "backups/"
if git -C "$gkeys" check-ignore -q "ca.key"; then _ok "private key is ignored by git"
else _bad "private key is ignored by git"; fi
if git -C "$gkeys" ls-files | grep -q '\.key$'; then
    _bad "no private key is tracked"
else
    _ok "no private key is tracked"
fi

# An untracked change (new cert) must be committed before the next overwrite.
SIGN_NAME="git2.mesh" SIGN_IP="10.9.0.3/24" SIGN_GROUPS="old" \
    CERT_DIR="$gkeys" pki_sign >/dev/null 2>&1
old_git1="$(hash_of "$gkeys/git1.mesh.crt")"
SIGN_NAME="git1.mesh" SIGN_IP="10.9.0.2/24" SIGN_GROUPS="new" \
    CERT_DIR="$gkeys" pki_sign >/dev/null 2>&1
assert_eq "pre-change snapshot used git" "$CERT_STORE_LAST_SNAPSHOT" "git"
assert_eq "HEAD holds the pre-overwrite certificate" \
    "$(git -C "$gkeys" show HEAD:git1.mesh.crt | sha256sum | cut -d' ' -f1)" "$old_git1"
if git -C "$gkeys" cat-file -e HEAD:git2.mesh.crt 2>/dev/null; then
    _ok "pending certificates were committed before the overwrite"
else
    _bad "pending certificates were committed before the overwrite"
fi
if git -C "$gkeys" log --all --name-only --pretty=format: | grep -q '\.key$'; then
    _bad "git history never contains a private key"
else
    _ok "git history never contains a private key"
fi
assert_no_file "git mode does not create backup folders" "$gkeys/backups"

gstatus="$(cert_store_status "$gkeys")"
assert_contains "status reports git" "$gstatus" "VCS:               git"
assert_contains "status reports the log" "$gstatus" "Action log:"

# --- CLI --------------------------------------------------------------------
out="$(bash "$REPO_ROOT/nebula-manager" cert store status --cert-dir "$keys" 2>&1)"
assert_contains "CLI status works" "$out" "Certificate store:"
assert_contains "CLI status reports backups" "$out" "Backup folders:"

out="$(bash "$REPO_ROOT/nebula-manager" store log -n 5 --cert-dir "$keys" 2>&1)"
assert_contains "top-level store alias works" "$out" "sign name="

before="$(backup_count)"
bash "$REPO_ROOT/nebula-manager" cert store backup --reason cli-test --cert-dir "$keys" >/dev/null 2>&1
assert_eq "CLI backup adds a folder" "$(backup_count)" "$((before + 1))"
assert_contains "CLI backup reason" "$(cat "$(latest_backup)/ACTION.txt")" "reason: cli-test"
assert_contains "CLI backup records the command" "$(cat "$(latest_backup)/ACTION.txt")" "command:"
assert_contains "log records the triggering command" "$(cat "$LOG")" "cmd="

bash "$REPO_ROOT/nebula-manager" cert store git-init --cert-dir "$gkeys" >/dev/null 2>&1
assert_eq "git-init on an existing repo succeeds" "$?" "0"

# --- safety -----------------------------------------------------------------
assert_eq "no sudo used anywhere" "$(sudo_count)" "0"

harness_summary
