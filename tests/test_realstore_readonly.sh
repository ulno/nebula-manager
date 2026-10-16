#!/usr/bin/env bash
# Test: a real certificate store is used STRICTLY read-only.
# The store is provided via NEBULA_TEST_STORE (no paths/names are hardcoded);
# the test skips (exit 77) when it is unset or absent — it never writes to it.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="real cert store (read-only)"
harness_init

STORE="${NEBULA_TEST_STORE:-}"
if [[ -z "$STORE" ]]; then echo "SKIP: set NEBULA_TEST_STORE to a certificate directory"; exit 77; fi
if [[ ! -d "$STORE" ]]; then echo "SKIP: $STORE not present"; exit 77; fi
require_cmd nebula-cert

# Fingerprint only the material we must not touch.
snap() { ( cd "$STORE" && sha256sum ./*.crt ./*.key 2>/dev/null ); }
before="$(snap)"
[[ -n "$before" ]] || { echo "SKIP: no cert/key material in $STORE"; exit 77; }

NM="$REPO_ROOT/nebula-manager"

out="$("$NM" --cert-dir "$STORE" cert list 2>&1)"
assert_contains "lists a CA" "$out" "CA"
assert_contains "lists a certificate" "$out" "Cert"

out2="$("$NM" --cert-dir "$STORE" cert expiry 2>&1)"
assert_contains "expiry view works" "$out2" "Cert"

# Nothing may be written into the store.
assert_eq "no bundle written into the store" \
    "$(cd "$STORE" && ls ./*-nebula-bundle.zip 2>/dev/null | wc -l | tr -d ' ')" "0"
after="$(snap)"
assert_eq "store cert/key hashes unchanged" "$after" "$before"
assert_eq "read-only operations used no sudo" "$(sudo_count)" "0"

harness_summary
