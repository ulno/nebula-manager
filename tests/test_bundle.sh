#!/usr/bin/env bash
# Test: client bundle/export UX.
# Verifies certificate listing, substring matching, sensible output directory
# resolution, the CLI/TUI flows and 0600 permissions on the archive.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="client bundle/export UX"
harness_init
require_cmd nebula-cert
require_cmd zip

NM="$REPO_ROOT/nebula-manager"
KEYS="$SANDBOX/keys"
mkdir -p "$KEYS"

# CA + three ordinary certs + one keyless (mobile-style) cert.
CERT_DIR="$KEYS" CA_NAME="bundle-ca" pki_ca_create >/dev/null
for spec in "alpha.one:10.50.0.2/24:servers" "alpha.two:10.50.0.3/24:desktops" "beta.one:10.50.0.4/24:servers"; do
    IFS=: read -r n ip grp <<<"$spec"
    CERT_DIR="$KEYS" SIGN_NAME="$n" SIGN_IP="$ip" SIGN_GROUPS="$grp" pki_sign >/dev/null
done
cp "$KEYS/alpha.one.crt" "$KEYS/phone.crt"       # no .key -> not exportable

ERR="$SANDBOX/bundle.err"
: > "$ERR"

# --- candidates & listing ---------------------------------------------------
out="$(pki_bundle_candidates "$KEYS")"
assert_contains "lists an exportable cert" "$out" "alpha.one"
assert_contains "candidate includes its IP" "$out" "10.50.0.2/24"
assert_not_contains "CA is not exportable" "$out" "bundle-ca"
assert_not_contains "keyless/mobile cert is not exportable" "$out" "phone"

out="$(pki_bundle_list "$KEYS")"
assert_contains "pretty list shows names" "$out" "- alpha.one"
assert_contains "pretty list shows groups" "$out" "[servers]"

# --- name resolution --------------------------------------------------------
pki_resolve_bundle_name "alpha.one" "$KEYS"
assert_eq "exact name resolves" "$?" "0"
assert_eq "exact resolution value" "$PKI_BUNDLE_RESOLVED" "alpha.one"

pki_resolve_bundle_name "ALPHA.ONE" "$KEYS"
assert_eq "case-insensitive exact resolves" "$?" "0"
assert_eq "case-insensitive value" "$PKI_BUNDLE_RESOLVED" "alpha.one"

pki_resolve_bundle_name "beta" "$KEYS"
assert_eq "unique substring resolves" "$?" "0"
assert_eq "unique substring value" "$PKI_BUNDLE_RESOLVED" "beta.one"

pki_resolve_bundle_name "$KEYS/alpha.two.crt" "$KEYS"
assert_eq "pasted .crt path resolves" "$?" "0"
assert_eq "pasted .crt path value" "$PKI_BUNDLE_RESOLVED" "alpha.two"

pki_resolve_bundle_name "alpha" "$KEYS"
assert_eq "ambiguous substring returns 2" "$?" "2"
assert_eq "ambiguous lists both matches" "${#PKI_BUNDLE_MATCHES[@]}" "2"

pki_resolve_bundle_name "nope" "$KEYS"
assert_eq "unknown name returns 1" "$?" "1"

pki_resolve_bundle_name "phone" "$KEYS"
assert_eq "keyless cert does not match" "$?" "1"

# --- default output directory ----------------------------------------------
mkdir -p "$SANDBOX/cwd" "$HOME/Downloads"
d="$(cd "$SANDBOX/cwd" && pki_default_bundle_dir)"
assert_eq "default output is the start directory" "$d" "$SANDBOX/cwd"

d="$(NEBULA_BUNDLE_DIR="$SANDBOX/exports" pki_default_bundle_dir)"
assert_eq "NEBULA_BUNDLE_DIR wins" "$d" "$SANDBOX/exports"

if [[ "$EUID" -ne 0 ]]; then
    mkdir -p "$SANDBOX/readonly"
    chmod 555 "$SANDBOX/readonly"
    d="$(cd "$SANDBOX/readonly" && pki_default_bundle_dir)"
    assert_eq "unwritable cwd falls back to ~/Downloads" "$d" "$HOME/Downloads"
    chmod 755 "$SANDBOX/readonly"
fi

# --- CLI: listing and matching ---------------------------------------------
err="$("$NM" --cert-dir "$KEYS" cert bundle 2>&1)"; rc=$?
assert_eq "bundle without a name exits 2" "$rc" "2"
assert_contains "bundle without a name lists candidates" "$err" "alpha.one"
assert_contains "bundle without a name prints usage" "$err" "Usage:"

out="$("$NM" --cert-dir "$KEYS" cert bundle beta --out "$SANDBOX/out" 2>"$ERR")"; rc=$?
assert_eq "substring bundle succeeds" "$rc" "0"
assert_contains "substring match is reported" "$out" "Matched 'beta' -> 'beta.one'"
assert_file "bundle written to --out" "$SANDBOX/out/beta.one-nebula-bundle.zip"
assert_eq "bundle path is printed" "$(printf '%s\n' "$out" | tail -n1)" "$SANDBOX/out/beta.one-nebula-bundle.zip"
assert_eq "bundle archive is mode 600" "$(stat -c '%a' "$SANDBOX/out/beta.one-nebula-bundle.zip")" "600"

# `export` is an alias, and positional output dirs keep working.
"$NM" --cert-dir "$KEYS" cert export alpha.one "$SANDBOX/pos" >/dev/null 2>&1
assert_file "export alias + positional dir" "$SANDBOX/pos/alpha.one-nebula-bundle.zip"

err="$("$NM" --cert-dir "$KEYS" cert bundle alpha 2>&1)"; rc=$?
assert_eq "ambiguous CLI name exits 2" "$rc" "2"
assert_contains "ambiguous CLI name lists matches" "$err" "Ambiguous certificate name"
assert_contains "ambiguous CLI name names alpha.one" "$err" "alpha.one"
assert_contains "ambiguous CLI name names alpha.two" "$err" "alpha.two"

err="$("$NM" --cert-dir "$KEYS" cert bundle nope 2>&1)"; rc=$?
assert_eq "unknown CLI name exits 1" "$rc" "1"
assert_contains "unknown CLI name explains" "$err" "No exportable certificate matching"
assert_contains "unknown CLI name lists what is available" "$err" "Exportable certificates:"

# --- CLI: default destination ----------------------------------------------
mkdir -p "$SANDBOX/rundir"
( cd "$SANDBOX/rundir" && "$NM" --cert-dir "$KEYS" cert bundle beta.one >/dev/null 2>&1 )
assert_file "CLI defaults to the start directory" "$SANDBOX/rundir/beta.one-nebula-bundle.zip"

NEBULA_BUNDLE_DIR="$SANDBOX/envout" "$NM" --cert-dir "$KEYS" cert bundle beta.one >/dev/null 2>&1
assert_file "CLI honours NEBULA_BUNDLE_DIR" "$SANDBOX/envout/beta.one-nebula-bundle.zip"

# --- TUI: selection list + output prompt ------------------------------------
TUI_KEYS="$SANDBOX/tui-keys"
TUI_OUT="$SANDBOX/tui-out"
mkdir -p "$TUI_KEYS"
CERT_DIR="$TUI_KEYS" CA_NAME="tui-ca" pki_ca_create >/dev/null
CERT_DIR="$TUI_KEYS" SIGN_NAME="solo" SIGN_IP="10.60.0.2/24" SIGN_GROUPS="laptops" pki_sign >/dev/null

out="$(printf '1\n%s\n' "$TUI_OUT" | CERT_DIR_SELECTED="$TUI_KEYS" pki_bundle_client_menu 2>"$ERR")"
assert_eq "TUI bundle succeeds" "$?" "0"
assert_contains "TUI lists the certificate" "$(cat "$ERR")" "solo"
assert_contains "TUI shows the cert IP" "$(cat "$ERR")" "10.60.0.2/24"
assert_file "TUI wrote the bundle" "$TUI_OUT/solo-nebula-bundle.zip"

# Typing a (partial) name at the selection prompt also works - no need to
# choose "Type a certificate name manually".
TUI_TYPED_OUT="$SANDBOX/tui-typed-out"
out="$(printf 'sol\n%s\n' "$TUI_TYPED_OUT" | CERT_DIR_SELECTED="$TUI_KEYS" pki_bundle_client_menu 2>"$ERR")"
assert_eq "TUI accepts a typed name at the menu" "$?" "0"
assert_contains "TUI reports the typed-name match" "$out" "Matched 'sol' -> 'solo'"
assert_file "TUI typed-name bundle written" "$TUI_TYPED_OUT/solo-nebula-bundle.zip"

# Empty input at the output prompt uses the sensible default (the start dir).
mkdir -p "$SANDBOX/tui-default"
out="$(cd "$SANDBOX/tui-default" && printf '1\n\n' | CERT_DIR_SELECTED="$TUI_KEYS" pki_bundle_client_menu 2>/dev/null)"
assert_file "TUI empty output prompt uses the default dir" "$SANDBOX/tui-default/solo-nebula-bundle.zip"

# --- no candidates ----------------------------------------------------------
mkdir -p "$SANDBOX/empty-keys"
CERT_DIR_SELECTED="$SANDBOX/empty-keys" pki_bundle_client_menu >/dev/null 2>"$ERR"; rc=$?
assert_eq "TUI with no exportable certs returns 1" "$rc" "1"
assert_contains "TUI explains what is needed" "$(cat "$ERR")" "needs <name>.crt and <name>.key"

harness_summary
