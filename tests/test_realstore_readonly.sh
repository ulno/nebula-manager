#!/usr/bin/env bash
# Test: the real certificate store is used STRICTLY read-only.
# Skips (exit 77) when the store is absent, so the suite stays portable.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="real cert store (read-only)"
harness_init

STORE="${NEBULA_TEST_STORE:-/home/ulno/keys/nebula}"
if [[ ! -d "$STORE" ]]; then echo "SKIP: $STORE not present"; exit 77; fi
require_cmd nebula-cert

# Fingerprint only the material we must not touch.
snap() { ( cd "$STORE" && sha256sum ./*.crt ./*.key 2>/dev/null ); }
before="$(snap)"
[[ -n "$before" ]] || { echo "SKIP: no cert/key material in $STORE"; exit 77; }

NM="$REPO_ROOT/nebula-manager"

out="$("$NM" --cert-dir "$STORE" cert list 2>&1)"
assert_contains "lists the real CA" "$out" "UlnoMeshCA"
assert_contains "lists the real client cert" "$out" "ulno-frame"
assert_contains "lists another real cert" "$out" "vps.ulno.mesh"

out2="$("$NM" --cert-dir "$STORE" cert expiry 2>&1)"
assert_contains "expiry view works on real certs" "$out2" "ulno-framework"

after="$(snap)"
assert_eq "store cert/key hashes unchanged" "$after" "$before"
assert_no_file "no bundle written into the store" \
    "$STORE/ulno-framework.ulno.mesh-nebula-bundle.zip"
assert_eq "read-only operations used no sudo" "$(sudo_count)" "0"

harness_summary
