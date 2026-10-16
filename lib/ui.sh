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

# Headless-friendly logging helpers. Errors/warnings go to stderr so that
# scriptable output on stdout stays clean.
log_info()    { echo -e "$(show_status 'info') $*"; }
log_success() { echo -e "$(show_status 'success') $*"; }
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
${BG_ORANGE}  ${BOLD}${BLACK}By Jordan Hillis [jordan@hillis.email]    ${BOLD}⎦˚◡˚⎣ ${WHITE}v${MANAGER_VERSION:-${VERSION:-dev}}  ${RESET}"
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

# Select which backend to use. Honours NEBULA_UI=auto|whiptail|dialog|plain.
# whiptail is strongly preferred; dialog is a last resort and plain text is the
# final fallback (also used for non-interactive/headless runs).
ui_backend() {
    case "${NEBULA_UI:-auto}" in
        plain)    printf 'plain';    return 0 ;;
        whiptail) command -v whiptail >/dev/null 2>&1 && { printf 'whiptail'; return 0; }
                  printf 'plain'; return 0 ;;
        dialog)   command -v dialog  >/dev/null 2>&1 && { printf 'dialog';  return 0; }
                  printf 'plain'; return 0 ;;
    esac
    # auto: only use a curses backend when attached to a real terminal
    if [[ -t 0 && -t 1 ]]; then
        if command -v whiptail >/dev/null 2>&1; then
            printf 'whiptail'; return 0
        fi
        if command -v dialog >/dev/null 2>&1; then
            if [[ "${_NEBULA_DIALOG_WARNED:-}" != 1 ]]; then
                log_warn "whiptail not found - falling back to dialog (last resort; install whiptail for the best UI)."
                _NEBULA_DIALOG_WARNED=1
            fi
            printf 'dialog'; return 0
        fi
    fi
    printf 'plain'
}

# ui_msg <title> <message>
ui_msg() {
    local title="$1" msg="$2" backend
    backend="$(ui_backend)"
    case "$backend" in
        whiptail) whiptail --title "$title" --msgbox "$msg" 15 70 ;;
        dialog)   dialog --title "$title" --msgbox "$msg" 15 70 ;;
        *)        echo -e "${BOLD}$title${RESET}\n$msg" ;;
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
            read -rp "$(show_status 'question') $prompt " value
            [[ -z "$value" && -n "$default" ]] && value="$default"
            ;;
    esac
    printf '%s' "$value"
}

# ui_fselect <title> <prompt> [start_dir] ; prints the selected path
# Uses the curses file-selection browser where available, else a typed path.
ui_fselect() {
    local title="$1" prompt="$2" start="${3:-$HOME}" backend value
    backend="$(ui_backend)"
    case "$backend" in
        whiptail) value=$(whiptail --title "$title" --fselect "${start%/}/" 18 78 3>&1 1>&2 2>&3) || return 1 ;;
        dialog)   value=$(dialog   --title "$title" --fselect "${start%/}/" 18 78 3>&1 1>&2 2>&3) || return 1 ;;
        *)        read -rp "$(show_status 'question') $prompt " value ;;
    esac
    printf '%s\n' "$value"
}

# ui_dselect <title> <prompt> [start_dir] ; prints the selected directory
ui_dselect() {
    local title="$1" prompt="$2" start="${3:-$HOME}" backend value
    backend="$(ui_backend)"
    case "$backend" in
        whiptail) value=$(whiptail --title "$title" --dselect "${start%/}/" 18 78 3>&1 1>&2 2>&3) || return 1 ;;
        dialog)   value=$(dialog   --title "$title" --dselect "${start%/}/" 18 78 3>&1 1>&2 2>&3) || return 1 ;;
        *)        read -rp "$(show_status 'question') $prompt " value ;;
    esac
    printf '%s' "$value"
}

# ui_menu <title> <prompt> <tag> <desc> [<tag> <desc> ...] ; prints chosen tag
ui_menu() {
    local title="$1" prompt="$2"; shift 2
    local backend choice
    backend="$(ui_backend)"
    case "$backend" in
        whiptail) choice=$(whiptail --title "$title" --menu "$prompt" 20 70 12 "$@" 3>&1 1>&2 2>&3) || return 1 ;;
        dialog)   choice=$(dialog --title "$title" --menu "$prompt" 20 70 12 "$@" 3>&1 1>&2 2>&3) || return 1 ;;
        *)
            echo -e "${BOLD}$title${RESET}"
            local -a tags=()
            while (( $# )); do
                tags+=("$1")
                printf "  ${BOLD}${YELLOW}%d.${RESET} %s\n" "${#tags[@]}" "$2"
                shift 2
            done
            read -rp "$(show_status 'question') $prompt " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#tags[@]} )); then
                printf '%s' "${tags[$((choice-1))]}"
            else
                return 1
            fi
            ;;
    esac
    printf '%s' "$choice"
}

###################################################################
######################### Menu dispatcher #########################
###################################################################
# Function to dynamically build option menus (plain text). Kept as the
# default dispatcher because it works over any terminal/pipe.
dynamic_menu() {
    local -n title_parts="$1"
    local -n labels="$2"
    local -n actions="$3"
    local depth="${4:-0}"  # Default to 0 if not passed
    local indent=" "
    for ((i = 0; i < depth; i++)); do
        indent+="   "  # 3 spaces per depth level
    done
    while true; do
        show_menu_header "${title_parts[@]}"
        for i in "${!labels[@]}"; do
            printf "${indent}${BOLD}${YELLOW}%d.${RESET} %b\n" "$((i + 1))" "${labels[$i]}"
        done
        local max_choice="${#labels[@]}"
        if (( depth > 0 )); then
            ((max_choice++))
            printf "${indent}${BOLD}${YELLOW}%d.${RESET} $(get_icon 'back')${BOLD}Go Back${RESET}\n" "$max_choice"
        fi
        read -p "${indent}$(show_status 'question') Choose an option [1-$max_choice]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#labels[@]} )); then
            eval "${actions[$((choice - 1))]}"
        elif (( depth > 0 && choice == max_choice )); then
            break
        else
            echo -e "${indent}$(show_status 'error') ${RED}Invalid option. Please choose again.${RESET}"
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
