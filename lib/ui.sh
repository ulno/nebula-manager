#!/bin/bash
# shellcheck shell=bash
#
# lib/ui.sh - Presentation layer for Nebula Manager
# ------------------------------------------------
# Everything that renders to a terminal lives here: colour codes, status
# badges, icons, banners, the plain-text menu dispatcher and the
# whiptail/dialog wrappers.
#
# Nothing in this file requires root privileges.

[[ -n "${NEBULA_MANAGER_UI_SOURCED:-}" ]] && return 0
NEBULA_MANAGER_UI_SOURCED=1

# A cleaner default look for whiptail/newt (the stock theme is the blue "installer"
# look people often mistake for dialog). Respects a user-provided NEWT_COLORS.
if [[ -z "${NEWT_COLORS:-}" ]]; then
    export NEWT_COLORS='root=lightgray,black;border=cyan,black;window=lightgray,black;shadow=black,black;title=cyan,black;button=black,cyan;actbutton=black,yellow;checkbox=lightgray,black;actcheckbox=black,yellow;entry=lightgray,black;label=lightgray,black;listbox=lightgray,black;actlistbox=black,cyan;sellistbox=black,green;actsellistbox=black,yellow;textbox=lightgray,black;compactbutton=lightgray,black'
fi

###################################################################
########################## Colors / Icons #########################
###################################################################
# Colors are only declared if the caller (load_global_config) has not
# already cleared them (use_color=false).
: "${RESET:=\033[0m}"
: "${BOLD:=\033[1m}"
# Text Colors
: "${BLACK:=\e[30m}"
: "${GRAY:=\e[30m}"
: "${RED:=\e[31m}"
: "${GREEN:=\e[32m}"
: "${YELLOW:=\e[33m}"
: "${BLUE:=\e[34m}"
: "${MAGENTA:=\e[35m}"
: "${CYAN:=\e[36m}"
: "${WHITE:=\e[37m}"
: "${ORANGE:=\e[38;5;202m}"
# Background Colors
: "${BG_BLACK:=\e[40m}"
: "${BG_RED:=\e[41m}"
: "${BG_GREEN:=\e[42m}"
: "${BG_YELLOW:=\e[43m}"
: "${BG_BLUE:=\e[44m}"
: "${BG_MAGENTA:=\e[45m}"
: "${BG_CYAN:=\e[46m}"
: "${BG_WHITE:=\e[47m}"
: "${BG_ORANGE:=\e[48;5;202m}"
: "${BG_GRAY:=\e[48;5;240m}"
: "${BG_LIGHT_GRAY:=\e[48;5;250m}"
: "${BG_LIGHT_BLACK:=\e[48;5;233m}"

# Colors that load_global_config() will clear when use_color=false
NEBULA_COLOR_VARS=(
  RESET BOLD BLACK GRAY RED GREEN YELLOW BLUE MAGENTA CYAN WHITE ORANGE
  BG_BLACK BG_RED BG_GREEN BG_YELLOW BG_BLUE BG_MAGENTA BG_CYAN BG_WHITE
  BG_ORANGE BG_GRAY BG_LIGHT_GRAY BG_LIGHT_BLACK
)

# Function to generate icons
get_icon() {
  if [[ "${USE_ICONS:-true}" == "false" ]]; then
    echo ""
    return
  fi
  case "$1" in
    certificate)     echo "📜 " ;;
    configuration)   echo "🔧 " ;;
    connectivity)    echo "📡 " ;;
    maintenance)     echo "🧰 " ;;
    exit)            echo "🚪 " ;;
    start)           echo "🧩 " ;;
    update)          echo "⬆️ " ;;
    schedule)        echo "⏰ " ;;
    install)         echo "📥 " ;;
    uninstall)       echo "🔥 " ;;
    validate)        echo "✅ " ;;
    edit)            echo "📝 " ;;
    firewall)        echo "🧱 " ;;
    left-arrow)      echo "⬅️ " ;;
    right-arrow)     echo "➡️ " ;;
    security)        echo "🔐 " ;;
    list)            echo "📄 " ;;
    create)          echo "🆕 " ;;
    inspect)         echo "🔍 " ;;
    revoke)          echo "⛔ " ;;
    delete)          echo "🗑️ " ;;
    ping)            echo "📶 " ;;
    status)          echo "📈 " ;;
    trace)           echo "🗺️ " ;;
    scan)            echo "🔎 " ;;
    logs)            echo "🧾 " ;;
    tools)           echo "🧰 " ;;
    backup)          echo "💾 " ;;
    restore)         echo "♻️ " ;;
    info)            echo "ℹ️ " ;;
    warning)         echo "⚠️ " ;;
    error)           echo "❌ " ;;
    success)         echo "✔️ " ;;
    question)        echo "❓ " ;;
    download)        echo "📦 " ;;
    upload)          echo "📤 " ;;
    lock)            echo "🔐 " ;;
    s_success)       echo "✔ " ;;
    s_error)         echo "✘ " ;;
    back)            echo "↩️ " ;;
    menu)            echo "📋 " ;;
    home)            echo "🏠 " ;;
    refresh)         echo "🔄 " ;;
    package)         echo "📦 " ;;
    link)            echo "🔗 " ;;
    hour-glass)      echo "⏳ " ;;
    bench)           echo "🏁 " ;;
    keys)            echo "🗝️ " ;;
    *)               echo "" ;;
  esac
}

# Function to display status with color
show_status() {
    local status="$1"
    if [[ "$status" == "success" ]]; then
        echo -e -n "${GREEN}[${BOLD}✔${RESET}${GREEN}]${RESET}"
    elif [[ "$status" == "error" ]]; then
        echo -e -n "${RED}[${BOLD}✘${RESET}${RED}]${RESET}"
    elif [[ "$status" == "question" ]]; then
        echo -e -n "${CYAN}[${BOLD}?${RESET}${CYAN}]${RESET}"
    elif [[ "$status" == "warning" ]]; then
        echo -e -n "${YELLOW}[${BOLD}!${RESET}${YELLOW}]${RESET}"
    else
        echo -e -n "${YELLOW}[${BOLD}-${RESET}${YELLOW}]${RESET}"
    fi
}

###################################################################
########################## Debug modes ###########################
###################################################################
# DEBUG=warn|log|info|learn|all   (comma-separated combinations allowed)
#
#   warn    only warnings/errors (normal info/success chatter is hidden)
#   log     classic behaviour (the default when DEBUG is unset)
#   info    log + internal detection/resolution details
#   learn   log + every Nebula CLI command *before* it runs, so you can
#           reproduce/learn the underlying `nebula-cert` / `nebula` calls
#   all     info + learn
#
# Everything debug-related is written to stderr: stdout stays clean for
# scriptable output (menus, JSON, printed paths, ...).
_NM_DEBUG_INIT=0
_NM_DEBUG_RAW=""
_NM_DEBUG_INFO=0
_NM_DEBUG_LEARN=0
_NM_DEBUG_QUIET=0

_nm_debug_apply() {
    local raw="${DEBUG:-}" d tok bad=""
    d="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    _NM_DEBUG_INFO=0; _NM_DEBUG_LEARN=0; _NM_DEBUG_QUIET=0
    _NM_DEBUG_RAW="$raw"
    _NM_DEBUG_INIT=1
    case "$d" in
        ""|0|false|off) return 0 ;;
    esac
    local IFS=','
    for tok in $d; do
        case "$tok" in
            all|learn) _NM_DEBUG_INFO=1; _NM_DEBUG_LEARN=1 ;;
            info)      _NM_DEBUG_INFO=1 ;;
            warn)      _NM_DEBUG_QUIET=1 ;;
            log)       : ;;
            "")        : ;;
            *)         bad+="${bad:+, }$tok" ;;
        esac
    done
    if [[ -n "$bad" ]]; then
        printf '[debug] unknown DEBUG level(s): %s (use warn|log|info|learn|all)\n' "$bad" >&2
    fi
}

# Re-parse only when DEBUG changed (cheap for the many log calls).
_nm_debug_ensure() {
    [[ "$_NM_DEBUG_INIT" == 1 && "$_NM_DEBUG_RAW" == "${DEBUG:-}" ]] && return 0
    _nm_debug_apply
}

# debug_want <learn|info|warn|log>
debug_want() {
    _nm_debug_ensure
    case "${1:-}" in
        learn) (( _NM_DEBUG_LEARN == 1 )) ;;
        info)  (( _NM_DEBUG_INFO  == 1 )) ;;
        warn)  (( _NM_DEBUG_QUIET == 1 )) ;;
        log)   (( _NM_DEBUG_QUIET == 0 )) ;;
        *)     return 1 ;;
    esac
}

# debug_info <message...> : extra internal detail (stderr only).
debug_info() {
    debug_want info || return 0
    local prefix="[debug]"
    [[ "${USE_COLOR:-true}" != "false" ]] && prefix="${CYAN}[debug]${RESET}"
    printf '%b %s\n' "$prefix" "$*" >&2
}

# debug_print_cmd <cmd> [args...] : show a command exactly as it will run.
debug_print_cmd() {
    debug_want learn || return 0
    local a quoted out="" prefix="[learn]"
    [[ "${USE_COLOR:-true}" != "false" ]] && prefix="${CYAN}[learn]${RESET}"
    for a in "$@"; do
        printf -v quoted '%q' "$a"
        out+="${out:+ }$quoted"
    done
    printf '%b %s\n' "$prefix" "$out" >&2
}

# debug_run <cmd> [args...] : print (learn mode) then execute.
debug_run() {
    debug_print_cmd "$@"
    "$@"
}

# debug_run_quiet <cmd> [args...] : like debug_run, but discard the command's
# own stderr (for optional probes). The learn line is still printed to stderr.
debug_run_quiet() {
    debug_print_cmd "$@"
    "$@" 2>/dev/null
}

# Headless-friendly logging helpers. Errors/warnings go to stderr so that
# scriptable output on stdout stays clean. DEBUG=warn silences info/success.
log_info()    { debug_want log || return 0; echo -e "$(show_status 'info') $*"; }
log_success() { debug_want log || return 0; echo -e "$(show_status 'success') $*"; }
log_warn()    { echo -e "$(show_status 'warning') $*" >&2; }
log_error()   { echo -e "$(show_status 'error') $*" >&2; }

# Helper: truncate text if it exceeds given width
maxlen() {
    local text="$1" max="$2"
    [[ ${#text} -le $max ]] && echo "$text" || echo "${text:0:$((max - 3))}..."
}

# Function to display the banner
banner() {
    echo -e "${BG_BLACK}${GREEN}  ░█▀█░█▀▀░█▀▄░█░█░█░░░█▀█░░░█▄█░█▀█░█▀█░█▀█░█▀▀░█▀▀░█▀▄  
  ░█░█░█▀▀░█▀▄░█░█░█░░░█▀█░░░█░█░█▀█░█░█░█▀█░█░█░█▀▀░█▀▄  
  ░▀░▀░▀▀▀░▀▀░░▀▀▀░▀▀▀░▀░▀░░░▀░▀░▀░▀░▀░▀░▀░▀░▀▀▀░▀▀▀░▀░▀  
${BG_ORANGE}  ${BOLD}${BLACK}By Jordan Hillis [jordan@hillis.email] + ulno   ${WHITE}v${MANAGER_VERSION:-${VERSION:-dev}}  ${RESET}"
}

# Function for menu header menu
show_menu_header() {
    local -a color_vars=(MAGENTA YELLOW ORANGE RED BLUE GREEN CYAN)
    local reset="${RESET:-}"
    local bold="${BOLD:-}"
    local styled_path=""
    local i=0
    local last_index=$(($# - 1))
    if [[ "${USE_COLOR:-true}" = false ]]; then
        styled_path="$*"
    else
        for segment in "$@"; do
            local color_var="${color_vars[i % ${#color_vars[@]}]}"
            local color="${!color_var}"

            if [[ $i -eq $last_index ]]; then
                styled_path+="${bold}${color}${segment}${reset}"
            else
                styled_path+="${color}${segment}${reset} ${CYAN}>${reset} "
            fi
            ((i++))
        done
    fi
    echo -e "${bold}${CYAN}=~=~=~=~=~=~=~=~=~=~=~[ ${styled_path}${CYAN} ]~=~=~=~=~=~=~=~=~=~=~=${reset}"
}

# Function to convert text to dynamic color
hash_color_256() {
    [[ "${USE_COLOR:-true}" = false ]] && echo "" && return
    local input="$1"
    local index
    local -a colors=(196 202 208 214 220 226 190 154 118 82 46 47 51 39 27 21 57 93 129 165 201 200)
    index=$(echo -n "$input" | cksum | awk '{print $1}')
    echo "${colors[$((index % ${#colors[@]}))]}"
}

###################################################################
##################### Whiptail / dialog helpers ###################
###################################################################
# Every interactive prompt goes through these wrappers so that the tool
# degrades gracefully: whiptail -> dialog -> plain stdin/stdout.

# Select which backend to use for MENUS. Default (auto) is the PLAIN numbered
# menu: it is predictable, easy to debug / copy-paste, never clears the screen,
# and keeps the reason for a prompt visible. Set NEBULA_UI=whiptail|dialog to
# force a curses UI for everything.
#
# File/dir *browsing* is different (typing paths is painful), so it uses
# ui_browse_backend(), which prefers a graphical picker when one is available.
ui_backend() {
    local b="plain"
    case "${NEBULA_UI:-auto}" in
        plain)    b="plain" ;;
        whiptail) command -v whiptail >/dev/null 2>&1 && b="whiptail" ;;
        dialog)   command -v dialog   >/dev/null 2>&1 && b="dialog" ;;
        *)
            # auto: plain numbered menus (the debugging-friendly default).
            b="plain"
            ;;
    esac
    # NEBULA_UI_DEBUG=1 prints exactly which backend (and paths) are in play.
    if [[ "${NEBULA_UI_DEBUG:-0}" == "1" ]]; then
        printf 'ui: requested=%s menu=%s browse=%s whiptail=%s dialog=%s stdin_tty=%s\n' \
            "${NEBULA_UI:-auto}" "$b" "$(ui_browse_backend)" \
            "$(command -v whiptail 2>/dev/null || echo -)" \
            "$(command -v dialog   2>/dev/null || echo -)" \
            "$([[ -t 0 ]] && echo y || echo n)" >&2
    fi
    printf '%s' "$b"
}

# Backend for file / directory selection. Under 'auto' prefer a graphical picker
# (whiptail, then dialog) because navigating a filesystem by typing paths is
# awkward; fall back to plain when there is no tty or no picker. An explicit
# NEBULA_UI is honoured (NEBULA_UI=plain keeps even browsing plain).
ui_browse_backend() {
    local b="plain"
    case "${NEBULA_UI:-auto}" in
        plain)    b="plain" ;;
        whiptail) command -v whiptail >/dev/null 2>&1 && b="whiptail" ;;
        dialog)   command -v dialog   >/dev/null 2>&1 && b="dialog" ;;
        *)
            if [[ -t 0 ]]; then
                if command -v whiptail >/dev/null 2>&1; then
                    b="whiptail"
                elif command -v dialog >/dev/null 2>&1; then
                    b="dialog"
                fi
            fi
            ;;
    esac
    printf '%s' "$b"
}

# ui_report : explain which backends are selected and why (diagnostic aid).
ui_report() {
    local m b
    m="$(ui_backend)"; b="$(ui_browse_backend)"
    printf 'requested (NEBULA_UI): %s\n' "${NEBULA_UI:-<unset/auto>}"
    printf 'menu backend:          %s\n' "$m"
    printf 'browse backend:        %s\n' "$b"
    printf 'whiptail:              %s\n' "$(command -v whiptail 2>/dev/null || echo 'not found')"
    printf 'dialog:                %s\n' "$(command -v dialog   2>/dev/null || echo 'not found')"
    printf 'stdin is a tty:        %s\n' "$([[ -t 0 ]] && echo yes || echo no)"
    if [[ "$m" == plain && "$b" == plain ]]; then
        printf 'note: plain is the default. NEBULA_UI=whiptail forces a curses UI everywhere.\n'
    elif [[ "$m" == dialog || "$b" == dialog ]]; then
        printf 'note: whiptail is preferred over dialog.\n'
    fi
}

# ui_msg <title> <message>
ui_msg() {
    local title="$1" msg="$2" backend
    backend="$(ui_backend)"
    case "$backend" in
        whiptail) whiptail --title "$title" --msgbox "$msg" 15 70 ;;
        dialog)   dialog --title "$title" --msgbox "$msg" 15 70 ;;
        *)        echo -e "${BOLD}$title${RESET}\n$msg" >&2 ;;
    esac
}

# ui_yesno <title> <prompt> ; returns 0 for yes, 1 for no/cancel
ui_yesno() {
    local title="$1" prompt="$2" backend answer
    backend="$(ui_backend)"
    case "$backend" in
        whiptail) whiptail --title "$title" --yesno "$prompt" 15 70 ;;
        dialog)   dialog --title "$title" --yesno "$prompt" 15 70 ;;
        *)
            read -rp "$(show_status 'question') $prompt [y/N]: " answer
            [[ "$answer" =~ ^[Yy]$ ]]
            ;;
    esac
}

# ui_input <title> <prompt> [default] ; prints entered value
ui_input() {
    local title="$1" prompt="$2" default="${3:-}" backend value
    backend="$(ui_backend)"
    case "$backend" in
        whiptail) value=$(whiptail --title "$title" --inputbox "$prompt" 15 70 "$default" 3>&1 1>&2 2>&3) || return 1 ;;
        dialog)   value=$(dialog --title "$title" --inputbox "$prompt" 15 70 "$default" 3>&1 1>&2 2>&3) || return 1 ;;
        *)
            local shown="$prompt"
            [[ -n "$default" ]] && shown="$prompt [${default}]"
            read -rp "$(show_status 'question') $shown " value
            [[ -z "$value" && -n "$default" ]] && value="$default"
            ;;
    esac
    printf '%s' "$value"
}

# Portable directory/file browser. whiptail has NO --fselect/--dselect (those
# are dialog-only), so for whiptail we navigate with --menu. Echoes the chosen
# path, or returns non-zero on cancel.
# Decide what a browser selection means. Prints: "goto <dir>" to descend,
# "done <path>" to finish. Directories always descend (never end the browse);
# the explicit "Use this directory" item finishes a directory pick.
_ui_browse_resolve() {
    local cur="$1" upper="$2" sel="$3"
    case "$sel" in
        __PARENT__) printf 'goto %s\n' "$(dirname "$upper")" ;;
        __USE__)    printf 'done %s\n' "$cur" ;;
        *)          if [[ -d "$sel" ]]; then printf 'goto %s\n' "$sel"; else printf 'done %s\n' "$sel"; fi ;;
    esac
}

_ui_whiptail_browse() {
    local title="$1" start="${2:-$HOME}" mode="${3:-dir}" cur
    cur="${start%/}"; [[ -d "$cur" ]] || cur="${HOME:-/}"
    while true; do
        local -a dirs=() files=() items=()
        local upper glob e name
        upper="$cur"; [[ -z "$upper" ]] && upper="/"
        glob="$upper"; [[ "$glob" == "/" ]] && glob=""   # avoid '//*' globs at root
        for e in "$glob"/* "$glob"/.[!.]*; do
            [[ -e "$e" ]] || continue
            name="$(basename "$e")"
            if [[ -d "$e" ]]; then dirs+=( "$e" "[dir] $name/" )
            elif [[ "$mode" == "file" && -f "$e" ]]; then files+=( "$e" "$name" ); fi
        done
        items=( "__PARENT__" "../" )
        [[ "$mode" == "dir" ]] && items+=( "__USE__" "Use this directory" )
        (( ${#dirs[@]} ))  && items+=( "${dirs[@]}" )
        (( ${#files[@]} )) && items+=( "${files[@]}" )
        local sel act path
        sel="$(whiptail --title "$title" --cancel-button "Cancel" --ok-button "Select" \
            --menu "In: $cur" 22 "$(_ui_box_cols)" 14 "${items[@]}" 3>&1 1>&2 2>&3)" || return 1
        read -r act path < <(_ui_browse_resolve "$cur" "$upper" "$sel")
        case "$act" in
            goto) cur="$path" ;;
            done) printf '%s' "$path"; return 0 ;;
        esac
    done
}

# ui_fselect <title> <prompt> [start_dir] ; prints the selected file
# graphical pickers when available; else a typed path.
ui_fselect() {
    local title="$1" prompt="$2" start="${3:-$HOME}" backend value
    backend="$(ui_browse_backend)"
    case "$backend" in
        whiptail) value="$(_ui_whiptail_browse "$title" "$start" file)" || return 1 ;;
        dialog)   value=$(dialog --title "$title" --cancel-button "Back" --fselect "${start%/}/" 20 "$(_ui_box_cols)" 3>&1 1>&2 2>&3) || return 1 ;;
        *)        read -rp "$(show_status 'question') $prompt " value ;;
    esac
    printf '%s\n' "$value"
}

# ui_dselect <title> <prompt> [start_dir] ; prints the selected directory
# graphical pickers when available; else a typed path.
ui_dselect() {
    local title="$1" prompt="$2" start="${3:-$HOME}" backend value
    backend="$(ui_browse_backend)"
    case "$backend" in
        whiptail) value="$(_ui_whiptail_browse "$title" "$start" dir)" || return 1 ;;
        dialog)   value=$(dialog --title "$title" --cancel-button "Back" --dselect "${start%/}/" 20 "$(_ui_box_cols)" 3>&1 1>&2 2>&3) || return 1 ;;
        *)        read -rp "$(show_status 'question') $prompt " value ;;
    esac
    printf '%s' "$value"
}

# Terminal width for boxes (override with UI_MENU_COLS for testing).
_ui_box_cols() {
    local c="${UI_MENU_COLS:-}"
    [[ -n "$c" ]] || c="$(tput cols 2>/dev/null || echo 80)"
    [[ "$c" =~ ^[0-9]+$ ]] || c=80
    (( c < 50 )) && c=50
    printf '%s' "$c"
}

# Compute a sensible box geometry from the prompt text AND the menu items, so
# nothing overflows or gets squeezed. Truncates over-long descriptions.
# Sets: _UI_W, _UI_H, _UI_MH, _UI_PAIRS[].
_ui_menu_geometry() {
    local prompt="$1"; shift
    local -a pairs=("$@")
    local -a plines=() line
    while IFS= read -r line; do plines+=("$line"); done <<< "$prompt"

    local i maxw=0
    for line in "${plines[@]}"; do (( ${#line} > maxw )) && maxw=${#line}; done
    for ((i=0; i<${#pairs[@]}; i+=2)); do
        line="${pairs[i]}  ${pairs[i+1]}"
        (( ${#line} > maxw )) && maxw=${#line}
    done

    local cols; cols="$(_ui_box_cols)"
    _UI_W=$(( maxw + 6 ))
    (( _UI_W > cols - 4 )) && _UI_W=$(( cols - 4 ))
    (( _UI_W < 60 )) && _UI_W=60

    local lim=$(( _UI_W - 6 ))
    _UI_PAIRS=()
    local tag desc allowed
    for ((i=0; i<${#pairs[@]}; i+=2)); do
        tag="${pairs[i]}"; desc="${pairs[i+1]}"
        allowed=$(( lim - ${#tag} - 2 ))
        (( allowed < 8 )) && allowed=8
        (( ${#desc} > allowed )) && desc="${desc:0:$((allowed-3))}..."
        _UI_PAIRS+=("$tag" "$desc")
    done

    # How many lines the prompt wraps to, given the box width.
    local wrapw=$(( _UI_W - 6 )); (( wrapw < 10 )) && wrapw=10
    local textlines=0 pl n
    for pl in "${plines[@]}"; do
        n=$(( (${#pl} + wrapw - 1) / wrapw )); (( n < 1 )) && n=1
        textlines=$(( textlines + n ))
    done

    local nitems=$(( ${#pairs[@]} / 2 ))
    (( nitems < 1 )) && nitems=1
    _UI_MH=$(( nitems < 14 ? nitems : 14 ))
    _UI_H=$(( textlines + _UI_MH + 7 ))

    local rows="${UI_MENU_ROWS:-}"
    [[ -n "$rows" ]] || rows="$(tput lines 2>/dev/null || echo 24)"
    [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
    (( _UI_H > rows - 2 )) && _UI_H=$(( rows - 2 ))
}

# ui_menu <title> <prompt> <tag> <desc> [<tag> <desc> ...] ; prints chosen tag
ui_menu() {
    local title="$1" prompt="$2"; shift 2
    local backend choice
    backend="$(ui_backend)"
    case "$backend" in
        whiptail|dialog)
            _ui_menu_geometry "$prompt" "$@"
            if [[ "$backend" == "whiptail" ]]; then
                choice=$(whiptail --title "$title" --cancel-button "Back" --ok-button "Select" \
                    --menu "$prompt" "$_UI_H" "$_UI_W" "$_UI_MH" "${_UI_PAIRS[@]}" 3>&1 1>&2 2>&3) || return 1
            else
                choice=$(dialog --title "$title" --cancel-button "Back" --ok-button "Select" \
                    --menu "$prompt" "$_UI_H" "$_UI_W" "$_UI_MH" "${_UI_PAIRS[@]}" 3>&1 1>&2 2>&3) || return 1
            fi
            ;;
        *)
            # Display on stderr so choices stay visible when stdout is captured
            # by the caller's command substitution; only the answer goes to stdout.
            echo -e "${BOLD}$title${RESET}" >&2
            [[ -n "$prompt" ]] && echo -e "$prompt" >&2
            local -a tags=()
            while (( $# )); do
                tags+=("$1")
                printf "  ${BOLD}${YELLOW}%d.${RESET} %s\n" "${#tags[@]}" "$2" >&2
                shift 2
            done
            read -rp "$(show_status 'question') $prompt " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#tags[@]} )); then
                choice="${tags[$((choice-1))]}"
            else
                return 1
            fi
            ;;
    esac
    printf '%s' "$choice"
}

# ui_menu_or_text <title> <prompt> <tag> <desc> [...]
# Like ui_menu, but in plain mode any non-numeric input is accepted and returned
# as "text:<value>" (instead of being rejected). Curses backends cannot accept
# free text and return the chosen tag as usual. Return codes: 0 = chose,
# 2 = empty/invalid input, 1 = cancel/EOF.
ui_menu_or_text() {
    local title="$1" prompt="$2"; shift 2
    local backend; backend="$(ui_backend)"
    if [[ "$backend" != "plain" ]]; then
        ui_menu "$title" "$prompt" "$@"
        return
    fi
    echo -e "${BOLD}$title${RESET}" >&2
    [[ -n "$prompt" ]] && echo -e "$prompt" >&2
    local -a tags=()
    while (( $# )); do
        tags+=("$1")
        printf "  ${BOLD}${YELLOW}%d.${RESET} %s\n" "${#tags[@]}" "$2" >&2
        shift 2
    done
    local answer
    read -rp "$(show_status 'question') Selection (number, name, or path): " answer || return 1
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#tags[@]} )); then
        printf '%s' "${tags[$((answer-1))]}"
        return 0
    fi
    [[ -n "$answer" ]] && { printf 'text:%s' "$answer"; return 0; }
    return 2
}

# ui_choose_or_path <title> <prompt> <tag> <desc> [...]
# Like ui_menu, but in plain mode a typed filesystem path is ALSO accepted and
# returned as "path:<value>" (so a user can either pick a number or just type
# the directory they mean). Curses backends return the chosen tag as usual.
# Return codes: 0 = chose (answer on stdout), 2 = invalid input, 1 = cancel/EOF.
ui_choose_or_path() {
    local title="$1" prompt="$2"; shift 2
    local backend; backend="$(ui_backend)"
    if [[ "$backend" != "plain" ]]; then
        ui_menu "$title" "$prompt" "$@"
        return
    fi
    echo -e "${BOLD}$title${RESET}" >&2
    [[ -n "$prompt" ]] && echo -e "$prompt" >&2
    local -a tags=()
    while (( $# )); do
        tags+=("$1")
        printf "  ${BOLD}${YELLOW}%d.${RESET} %s\n" "${#tags[@]}" "$2" >&2
        shift 2
    done
    local answer
    read -rp "$(show_status 'question') $prompt " answer || return 1
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#tags[@]} )); then
        printf '%s' "${tags[$((answer-1))]}"
        return 0
    fi
    # A typed path (contains a slash, or is relative/home-relative) is accepted.
    if [[ -n "$answer" && ( "$answer" == */* || "$answer" == "~"* || "$answer" == .* ) ]]; then
        printf 'path:%s' "${answer/#\~/$HOME}"
        return 0
    fi
    return 2
}

###################################################################
######################### Menu dispatcher #########################
###################################################################
# Make a label safe for a curses box (strip ANSI colours and non-ASCII glyphs).
_ui_label_clean() {
    printf '%s' "$1" \
        | sed -e 's/\\033\[[0-9;]*m//g' -e 's/\\e\[[0-9;]*m//g' -e 's/\o033\[[0-9;]*m//g' \
        | tr -d '\200-\377' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Function to dynamically build option menus. Renders a text-graphical menu
# (whiptail/dialog) when one is available, otherwise a plain numbered menu.
# Force the numbered menu with NEBULA_UI=plain.
#
# An optional 5th argument names a "refresh" function that is run before every
# redraw. It may rebuild the label/action arrays in place (they are passed by
# name) and set DYNAMIC_MENU_PROMPT to a status line shown inside the box. That
# is what lets the Setup menu show the *detected* state (config found? Nebula
# installed? cert workspace?) and update it live as actions run. Note: freshness
# is scoped per invocation - nested menus (which pass no refresh) ignore any
# DYNAMIC_MENU_PROMPT left over from an outer menu.
dynamic_menu() {
    local -n title_parts="$1"
    local -n labels="$2"
    local -n actions="$3"
    local depth="${4:-0}"  # Default to 0 if not passed
    local refresh="${5:-}"
    local backend; backend="$(ui_backend)"
    local indent=" " i choice
    for ((i = 0; i < depth; i++)); do
        indent+="   "  # 3 spaces per depth level
    done

    while true; do
        # Recompute dynamic state (and optionally the prompt) before each draw.
        local prompt=""
        if [[ -n "$refresh" ]]; then
            "$refresh"
            prompt="${DYNAMIC_MENU_PROMPT:-}"
        fi
        if [[ "$backend" != "plain" ]]; then
            # ---- text-graphical menu ----
            [[ -z "$prompt" ]] && prompt="Choose an option"
            local -a pairs=()
            for i in "${!labels[@]}"; do
                pairs+=( "$((i + 1))" "$(_ui_label_clean "${labels[$i]}")" )
            done
            (( depth > 0 )) && pairs+=( "0" "Back" )
            local sel
            sel="$(ui_menu "${title_parts[*]}" "$prompt" "${pairs[@]}")" || return 0
            [[ "$sel" == "0" ]] && return 0
            eval "${actions[$((sel - 1))]}"
            # A reload request unwinds every nested menu back to tui_main(), which
            # owns the flag and clears it there.
            [[ "${TUI_RESTART:-0}" == 1 ]] && return 0
            read -rp "$(show_status 'question') Press Enter to continue..." _ 2>/dev/null || true
        else
            # ---- plain numbered menu ----
            show_menu_header "${title_parts[@]}"
            [[ -n "$prompt" ]] && printf '%b\n' "$prompt"
            for i in "${!labels[@]}"; do
                printf "${indent}${BOLD}${YELLOW}%d.${RESET} %b\n" "$((i + 1))" "${labels[$i]}"
            done
            local max_choice="${#labels[@]}"
            if (( depth > 0 )); then
                ((max_choice++))
                printf "${indent}${BOLD}${YELLOW}%d.${RESET} $(get_icon 'back')${BOLD}Go Back${RESET}\n" "$max_choice"
            fi
            read -p "${indent}$(show_status 'question') Choose an option [1-$max_choice]: " choice || { printf '\n'; break; }
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#labels[@]} )); then
                eval "${actions[$((choice - 1))]}"
                [[ "${TUI_RESTART:-0}" == 1 ]] && break
            elif (( depth > 0 && choice == max_choice )); then
                break
            else
                echo -e "${indent}$(show_status 'error') ${RED}Invalid option. Please choose again.${RESET}"
            fi
        fi
    done
}

# Function to show the spinner used while background jobs run
start_spinner() {
    local message="$1"
    SPINNER_ACTIVE=true
    command -v tput >/dev/null 2>&1 && tput civis 2>/dev/null
    (
        local sp='|/-\'
        local i=0
        while $SPINNER_ACTIVE; do
            echo -ne "\r$(show_status 'success') ${YELLOW}${message} ${sp:i++%${#sp}:1} ${RESET}"
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

# Function to stop the spinner
stop_spinner() {
    SPINNER_ACTIVE=false
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        unset SPINNER_PID
    fi
    command -v tput >/dev/null 2>&1 && tput cnorm 2>/dev/null
    printf "\r\033[K" # clear line
}
