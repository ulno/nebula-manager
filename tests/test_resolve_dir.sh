#!/usr/bin/env bash
# Test: certificate workspace / directory resolution precedence.
# Verifies: --cert-dir > NEBULA_KEYS_DIR > saved selection > legacy server dir > default.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="resolve_cert_dir precedence"
harness_init

# 1. Default fallback (user-owned, no privilege needed).
assert_eq "default -> per-user data dir" \
    "$(resolve_cert_dir)" "$XDG_DATA_HOME/nebula-manager/keys"

# 2. Environment variable.
export NEBULA_KEYS_DIR="$SANDBOX/env-keys"
assert_eq "NEBULA_KEYS_DIR honoured" "$(resolve_cert_dir)" "$SANDBOX/env-keys"

# 3. CLI override beats the environment.
export CERT_DIR_OVERRIDE="$SANDBOX/cli-keys"
assert_eq "--cert-dir beats NEBULA_KEYS_DIR" "$(resolve_cert_dir)" "$SANDBOX/cli-keys"
unset CERT_DIR_OVERRIDE NEBULA_KEYS_DIR

# 4. Saved interactive selection.
save_cert_dir_selection "$SANDBOX/saved-keys"
assert_eq "saved selection honoured" "$(resolve_cert_dir)" "$SANDBOX/saved-keys"
assert_eq "saved selection beats default" "$(resolve_cert_dir)" "$SANDBOX/saved-keys"
rm -f "$(nebula_keys_state_file)"

# 5. Legacy per-server directory.
export NEBULA_DIR="$SANDBOX/server"
assert_eq "legacy server dir -> dir/certs" "$(resolve_cert_dir)" "$SANDBOX/server/certs"
export NEBULA_CERT_FOLDER="mycerts"
assert_eq "legacy cert_folder honoured" "$(resolve_cert_dir)" "$SANDBOX/server/mycerts"
unset NEBULA_CERT_FOLDER

# 6. Explicit selection beats the legacy server dir.
export CERT_DIR_SELECTED="$SANDBOX/selected"
assert_eq "CERT_DIR_SELECTED beats legacy dir" "$(resolve_cert_dir)" "$SANDBOX/selected"
unset CERT_DIR_SELECTED NEBULA_DIR

# 7. Back to the default after clearing everything.
assert_eq "clears back to default" \
    "$(resolve_cert_dir)" "$XDG_DATA_HOME/nebula-manager/keys"

harness_summary
