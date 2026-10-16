#!/usr/bin/env bash
# Test: optional freshness check of the bundled config template against the repo.
# Network-dependent, so it is SKIPPED unless NEBULA_TEST_ONLINE=1.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="template freshness (online)"
harness_init

if [[ "${NEBULA_TEST_ONLINE:-0}" != "1" ]]; then
    echo "SKIP: set NEBULA_TEST_ONLINE=1 to compare the bundled template with the remote"
    exit 77
fi
require_cmd curl

tpl="$(find_config_template)" || { echo "SKIP: no bundled template found"; exit 77; }
init_remote_urls
remote_url="${REPO_BASE}/nebula-manager.conf"

remote="$(curl -fsSL "$remote_url" 2>/dev/null)" || {
    _bad "could not fetch remote template from $remote_url"
    harness_summary
    exit 1
}

if [[ "$(cat "$tpl")" == "$remote" ]]; then
    _ok "bundled template matches $remote_url"
else
    _ok "bundled template differs from $remote_url (refresh with: config refresh)"
fi

harness_summary
