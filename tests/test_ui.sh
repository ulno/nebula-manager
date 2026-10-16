#!/usr/bin/env bash
# Test: UI wrappers (plain fallback).
# Regression guard: the menu must return ONLY the chosen tag on stdout (so the
# caller's $(...) captures the answer), while the prompt/options go to stderr so
# they stay visible on a real terminal.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="UI wrappers (plain)"
harness_init
export NEBULA_UI=plain

# --- menu returns just the selected tag on stdout ---
out="$(printf '2\n' | ui_menu "Title" "Pick one" a "First" b "Second")"
assert_eq "plain menu returns the chosen tag" "$out" "b"

out="$(printf '1\n' | ui_menu "Title" "Pick one" create "Create" browse "Browse" cancel "Cancel")"
assert_eq "plain menu returns first tag" "$out" "create"

# --- display (title + options) goes to stderr, not stdout ---
err="$(printf '1\n' | ui_menu "MenuTitle" "Pick one" a "First option" b "Second option" 2>&1 >/dev/null)"
assert_contains "title shown on stderr"   "$err" "MenuTitle"
assert_contains "prompt shown on stderr"  "$err" "Pick one"
assert_contains "option shown on stderr"  "$err" "First option"

# --- invalid selection -> non-zero, nothing on stdout ---
out="$(printf 'zzz\n' | ui_menu "T" "P" a "A" b "B")"; rc=$?
assert_eq "invalid selection exits non-zero" "$rc" "1"
assert_eq "invalid selection has empty stdout" "$out" ""

# --- input wrapper echoes the typed value on stdout ---
out="$(printf 'hello\n' | ui_input "T" "Value?")"
assert_eq "plain input returns the value" "$out" "hello"

# --- input wrapper applies the default on empty input ---
out="$(printf '\n' | ui_input "T" "Value?" "fallback")"
assert_eq "plain input uses default" "$out" "fallback"

# --- explicit backend selection (NEBULA_UI) ---
if command -v whiptail >/dev/null 2>&1; then
    export NEBULA_UI=whiptail
    assert_eq "explicit NEBULA_UI=whiptail" "$(ui_backend)" "whiptail"
fi
if command -v dialog >/dev/null 2>&1; then
    export NEBULA_UI=dialog
    assert_eq "explicit NEBULA_UI=dialog" "$(ui_backend)" "dialog"
fi
export NEBULA_UI=plain
assert_eq "explicit NEBULA_UI=plain" "$(ui_backend)" "plain"

# auto prefers whiptail; with no usable tty it degrades to plain
if [[ ! -t 0 ]]; then
    unset NEBULA_UI
    assert_eq "auto without tty -> plain" "$(ui_backend)" "plain"
    export NEBULA_UI=plain
fi

# --- ui_report is available and reports the selection ---
assert_contains "ui_report shows selected backend" "$(ui_report)" "selected backend:"

# --- menu geometry: box sized to content, capped to terminal, descs truncated ---
UI_MENU_COLS=80
UI_MENU_ROWS=24
_ui_menu_geometry "Pick one" a "short" b "a very long description that will definitely not fit inside an 80 column box"
assert_eq "menu width capped to terminal" "$_UI_W" "76"
assert_eq "menu keeps tag order" "${_UI_PAIRS[0]}" "a"
assert_eq "menu truncates long description" "${#_UI_PAIRS[3]}" "67"
assert_contains "truncation marked with ellipsis" "${_UI_PAIRS[3]}" "..."
assert_eq "menu height accounts for prompt" "$_UI_H" "10"

# small menu gets the minimum width; height tracks prompt + items
_ui_menu_geometry "p" a A b B
assert_eq "small menu uses minimum width" "$_UI_W" "60"
assert_eq "menu height = prompt lines + items + 7" "$_UI_H" "10"
unset UI_MENU_COLS UI_MENU_ROWS

# whiptail has no --fselect; we use a menu navigator instead
if declare -F _ui_whiptail_browse >/dev/null; then _ok "whiptail browser helper defined"; else _bad "whiptail browser helper defined"; fi

# browser navigation decisions (selecting a dir must descend, not finish)
mkdir -p "$SANDBOX/tree/sub"; : > "$SANDBOX/tree/a.conf"
assert_eq "browse: dir selection descends" "$(_ui_browse_resolve "$SANDBOX/tree" "$SANDBOX/tree" "$SANDBOX/tree/sub")" "goto $SANDBOX/tree/sub"
assert_eq "browse: file selection finishes" "$(_ui_browse_resolve "$SANDBOX/tree" "$SANDBOX/tree" "$SANDBOX/tree/a.conf")" "done $SANDBOX/tree/a.conf"
assert_eq "browse: parent goes up" "$(_ui_browse_resolve "$SANDBOX/tree" "$SANDBOX/tree" "__PARENT__")" "goto $SANDBOX"
assert_eq "browse: use-this-directory finishes" "$(_ui_browse_resolve "$SANDBOX/tree" "$SANDBOX/tree" "__USE__")" "done $SANDBOX/tree"

harness_summary
