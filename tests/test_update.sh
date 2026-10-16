#!/usr/bin/env bash
# Test: self-update source resolution and version comparison.
# Regression guard for the fork bug where upstream's older version prompted a
# downgrade (and would have replaced the modular install with the monolith).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="update check & repo resolution"
harness_init

# --- repo slug normalization ---
assert_eq "https .git suffix" "$(_normalize_repo_slug 'https://github.com/me/nebula-manager.git')" "me/nebula-manager"
assert_eq "https plain"       "$(_normalize_repo_slug 'https://github.com/me/nebula-manager')"     "me/nebula-manager"
assert_eq "git@ scp form"     "$(_normalize_repo_slug 'git@github.com:me/nebula-manager.git')"     "me/nebula-manager"
assert_eq "ssh url form"      "$(_normalize_repo_slug 'ssh://git@github.com/me/nebula-manager')"  "me/nebula-manager"

# --- repo resolution ---
export NEBULA_MANAGER_REPO="me/fork"
assert_eq "env repo override wins" "$(manager_remote_repo)" "me/fork"
unset NEBULA_MANAGER_REPO
assert_eq "falls back to upstream" "$(manager_remote_repo)" "jordanhillis/nebula-manager"

# --- version comparison ---
if version_gt 2.0.0 1.1.0; then _ok "2.0.0 > 1.1.0"; else _bad "2.0.0 > 1.1.0"; fi
if version_gt 1.1.0 2.0.0; then _bad "1.1.0 < 2.0.0"; else _ok "1.1.0 < 2.0.0"; fi
if version_gt 1.10.0 1.9.0; then _ok "1.10.0 > 1.9.0 (version sort)"; else _bad "1.10.0 > 1.9.0 (version sort)"; fi
if version_gt 1.1.0 1.1.0; then _bad "equal is not greater"; else _ok "equal is not greater"; fi

# --- update only offered when remote is strictly newer ---
if update_available 2.0.0 1.1.0; then _bad "fork ahead -> no prompt"; else _ok "fork ahead -> no prompt"; fi
if update_available 1.1.0 1.1.0; then _bad "equal -> no prompt"; else _ok "equal -> no prompt"; fi
if update_available 1.1.0 1.2.0; then _ok "remote newer -> prompt"; else _bad "remote newer -> prompt"; fi

# --- URL derivation follows repo/ref and keys the cache per repo ---
export NEBULA_MANAGER_REPO="me/fork" NEBULA_MANAGER_REF="dev"
init_remote_urls
assert_contains "script url uses fork/ref"  "$SCRIPT_URL"       "raw.githubusercontent.com/me/fork/refs/heads/dev/nebula-manager"
assert_contains "version url uses fork/ref" "$VERSION_URL"      "me/fork/refs/heads/dev/latest_version.txt"
assert_contains "conf url uses fork/ref"    "$SERVER_CONF_URL"  "me/fork/refs/heads/dev/nebula-manager.conf"
assert_eq       "release page uses fork"    "$RELEASE_PAGE"     "https://github.com/me/fork"
assert_contains "version cache keyed by repo" "$VERSION_CACHE_FILE" "me_fork"
unset NEBULA_MANAGER_REPO NEBULA_MANAGER_REF

harness_summary
