#!/usr/bin/env bash
#
# run_tests.sh - run the nebula-manager test suite.
# =================================================
# Runs the standalone, mock-driven Bash harness in tests/ (no external test
# framework required). If `bats` is installed and tests/*.bats exist, those
# are run as well.
#
# Exit code: 0 when nothing failed, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$REPO_ROOT" || exit 1

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
yellow(){ printf '\033[33m%s\033[0m' "$1"; }

files_pass=0
files_fail=0
files_skip=0
failed_names=()

shopt -s nullglob

# Optional BATS suite
bats_files=("$REPO_ROOT"/tests/*.bats)
if ((${#bats_files[@]})); then
    if command -v bats >/dev/null 2>&1; then
        echo "==> $(yellow 'bats') suite (${#bats_files[@]} file(s))"
        if bats "${bats_files[@]}"; then files_pass=$((files_pass+1)); else files_fail=$((files_fail+1)); failed_names+=("bats"); fi
    else
        echo "==> $(yellow 'bats') tests present but 'bats' not installed - skipping"
        files_skip=$((files_skip+1))
    fi
fi

# Standalone harness
for t in "$REPO_ROOT"/tests/test_*.sh; do
    name="$(basename "$t")"
    printf '==> %s\n' "$(yellow "$name")"
    if bash "$t"; then
        files_pass=$((files_pass+1))
    else
        rc=$?
        if [[ "$rc" -eq 77 ]]; then
            files_skip=$((files_skip+1))
            echo "   (skipped)"
        else
            files_fail=$((files_fail+1))
            failed_names+=("$name")
        fi
    fi
done

echo
echo "=================================================="
printf 'Files: %s passed, %s failed, %s skipped\n' \
    "$(green "$files_pass")" "$(red "$files_fail")" "$(yellow "$files_skip")"
if (( files_fail > 0 )); then
    printf 'Failed: %s\n' "${failed_names[*]}"
fi
echo "=================================================="

(( files_fail == 0 ))
