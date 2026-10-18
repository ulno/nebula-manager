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

# --- a menu can optionally accept typed text -------------------------------
out="$(printf '2\n' | ui_menu_or_text "Title" "Pick one" a "First" b "Second")"
assert_eq "menu_or_text returns the chosen tag" "$out" "b"

out="$(printf 'host1\n' | ui_menu_or_text "Title" "Pick one" a "First" b "Second")"
assert_eq "menu_or_text accepts typed text" "$out" "text:host1"

printf '\n' | ui_menu_or_text "Title" "Pick one" a "First" >/dev/null 2>&1; rc=$?
assert_eq "menu_or_text rejects empty input" "$rc" "2"

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

# auto now defaults to the plain numbered menu (also for headless runs).
if [[ ! -t 0 ]]; then
    unset NEBULA_UI
    assert_eq "auto menu backend -> plain" "$(ui_backend)" "plain"
    assert_eq "auto browse backend -> plain (no tty)" "$(ui_browse_backend)" "plain"
    export NEBULA_UI=plain
fi

# an explicit backend is honoured for both menus and browsing
if command -v whiptail >/dev/null 2>&1; then
    export NEBULA_UI=whiptail
    assert_eq "whiptail forced for menus"  "$(ui_backend)" "whiptail"
    assert_eq "whiptail forced for browse" "$(ui_browse_backend)" "whiptail"
fi
export NEBULA_UI=plain
assert_eq "plain forced for menus"  "$(ui_backend)" "plain"
assert_eq "plain forced for browse" "$(ui_browse_backend)" "plain"

# --- ui_report is available and reports the selection ---
report="$(ui_report)"
assert_contains "ui_report shows the menu backend"   "$report" "menu backend:"
assert_contains "ui_report shows the browse backend" "$report" "browse backend:"

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

# a multi-line prompt (like the Setup state summary) still fits the box
UI_MENU_COLS=100
UI_MENU_ROWS=40
_ui_menu_geometry "$(printf 'Config: /x (2 server(s) enabled)\nNebula: installed (v1.11.2)\nCertificates: /y (5 .crt)')" \
    1 "Import / update from this host" 2 "Create config from template" 3 "Browse for a config file" \
    4 "Edit config" 5 "Delete config" 6 "Manage servers" 7 "Certificate workspace" \
    8 "Reload & continue" 9 "Exit"
if (( _UI_W >= 60 && _UI_H <= 38 )); then
    _ok "multi-line setup prompt sizes a sane box"
else
    _bad "multi-line setup prompt sizes a sane box" "got ${_UI_W}x${_UI_H}"
fi
unset UI_MENU_COLS UI_MENU_ROWS

# --- label cleaning for curses menus ---
export USE_ICONS=true
assert_eq "label clean strips colour + emoji" \
    "$(_ui_label_clean "$(get_icon 'certificate')Certificates ${BOLD}${RESET}")" "Certificates"
assert_eq "label clean trims whitespace" "$(_ui_label_clean "   spaced   ")" "spaced"

# whiptail has no --fselect; we use a menu navigator instead
if declare -F _ui_whiptail_browse >/dev/null; then _ok "whiptail browser helper defined"; else _bad "whiptail browser helper defined"; fi

# browser navigation decisions (selecting a dir must descend, not finish)
mkdir -p "$SANDBOX/tree/sub"; : > "$SANDBOX/tree/a.conf"
assert_eq "browse: dir selection descends" "$(_ui_browse_resolve "$SANDBOX/tree" "$SANDBOX/tree" "$SANDBOX/tree/sub")" "goto $SANDBOX/tree/sub"
assert_eq "browse: file selection finishes" "$(_ui_browse_resolve "$SANDBOX/tree" "$SANDBOX/tree" "$SANDBOX/tree/a.conf")" "done $SANDBOX/tree/a.conf"
assert_eq "browse: parent goes up" "$(_ui_browse_resolve "$SANDBOX/tree" "$SANDBOX/tree" "__PARENT__")" "goto $SANDBOX"
assert_eq "browse: use-this-directory finishes" "$(_ui_browse_resolve "$SANDBOX/tree" "$SANDBOX/tree" "__USE__")" "done $SANDBOX/tree"

harness_summary
