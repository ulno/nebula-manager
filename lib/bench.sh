#!/bin/bash
# shellcheck shell=bash
#
# lib/bench.sh - Benchmarks (iperf3) and diagnostics
# -------------------------------------------------
# iperf3 client/server, node connectivity checks and a quick diagnostic
# viewer. Everything here runs as an ordinary user: iperf3, ping, ss and
# nebula-cert all work unprivileged against the Nebula overlay.

[[ -n "${NEBULA_MANAGER_BENCH_SOURCED:-}" ]] && return 0
NEBULA_MANAGER_BENCH_SOURCED=1

###################################################################
############################ iperf3 ################################
###################################################################

bench_require_iperf3() {
    if ! command -v iperf3 >/dev/null 2>&1; then
        log_error "iperf3 is not installed. Install it (e.g. 'sudo apt install iperf3') and try again."
        return 1
    fi
    return 0
}

# bench_server <port> [--one-off] [--bind ADDR] [extra...]
bench_server() {
    bench_require_iperf3 || return 1
    local port="5201" one_off=0 bind=""
    local -a extra=()
    while (($#)); do
        case "$1" in
            --port|-p) shift; port="$1" ;;
            --one-off|-1) one_off=1 ;;
            --bind|-B) shift; bind="$1" ;;
            *) extra+=("$1") ;;
        esac
        shift
    done
    local -a args=(iperf3 -s -p "$port")
    (( one_off )) && args+=(-1)
    [[ -n "$bind" ]] && args+=(-B "$bind")
    (( ${#extra[@]} )) && args+=("${extra[@]}")
    log_info "Starting iperf3 server on port ${CYAN}$port${RESET} (Ctrl-C to stop)..."
    debug_run "${args[@]}"
}

# bench_client <host> [--port P] [--time SEC] [--streams N] [--reverse] [extra...]
bench_client() {
    bench_require_iperf3 || return 1
    local host="${1:-}"; shift || true
    [[ -z "$host" ]] && { echo "Usage: nebula-manager bench client HOST [--port P] [--time SEC] [--streams N] [--reverse]" >&2; return 2; }
    local port="5201" duration="10" streams="1" reverse=0
    local -a extra=()
    while (($#)); do
        case "$1" in
            --port|-p) shift; port="$1" ;;
            --time|-t|--duration) shift; duration="$1" ;;
            --streams|-P) shift; streams="$1" ;;
            --reverse|-R) reverse=1 ;;
            *) extra+=("$1") ;;
        esac
        shift
    done
    local -a args=(iperf3 -c "$host" -p "$port" -t "$duration" -P "$streams")
    (( reverse )) && args+=(-R)
    (( ${#extra[@]} )) && args+=("${extra[@]}")
    log_info "Running iperf3 to ${MAGENTA}$host${CYAN} (port $port, ${duration}s, ${streams} stream(s))${RESET}..."
    debug_run "${args[@]}"
    local rc=$?
    if (( rc == 0 )); then log_success "iperf3 completed successfully."
    else log_error "iperf3 exited with code ${rc}."; fi
    return $rc
}

# Interactive benchmark menu
run_benchmark() {
    show_menu_header "$MENU_PATH" "Benchmarks"
    local choice
    choice="$(ui_menu "iperf3" "Choose a benchmark mode:" \
        "server" "Run iperf3 server (this host listens)" \
        "client" "Run iperf3 client (throughput to a peer)") " || return 0
    case "$choice" in
        server)
            local port; port="$(ui_input "iperf3 server" "Listen port:" "5201")" || return
            bench_server --port "${port:-5201}"
            ;;
        client)
            local host; host="$(ui_input "iperf3 client" "Peer overlay IP/host:")" || return
            [[ -z "$host" ]] && return
            local port dur streams rev
            port="$(ui_input "iperf3 client" "Port:" "5201")"
            dur="$(ui_input "iperf3 client" "Duration seconds:" "10")"
            streams="$(ui_input "iperf3 client" "Parallel streams:" "1")"
            read -rp "$(show_status 'question') Reverse test (server→client)? [y/N]: " rev
            local -a rargs=()
            [[ "$rev" =~ ^[Yy]$ ]] && rargs+=(--reverse)
            bench_client "$host" --port "${port:-5201}" --time "${dur:-10}" --streams "${streams:-1}" "${rargs[@]}"
            ;;
    esac
}

###################################################################
######################### Connectivity ############################
###################################################################

# check_node_connectivity : ping every cert IP in the workspace in parallel
check_node_connectivity() {
    local certs_dir; certs_dir="$(resolve_cert_dir)"
    [[ -d "$certs_dir" ]] || { log_error "Certificates directory $certs_dir does not exist."; return 1; }
    local bin_path; bin_path="$(dirname "$(pki_cert_bin)")"

    local -a ROW_NAMES=() ROW_IPS=()
    local idx=1
    local border_len=78 border_line
    border_line=$(printf '%*s' "$border_len" '' | tr ' ' '-')

    local tmp_ping_out; tmp_ping_out="$(mktemp)"
    local MAX_JOBS=32 jobs=0

    start_spinner "Checking node connectivity..."

    local cert
    for cert in "$certs_dir"/*.crt; do
        [[ -f "$cert" ]] || continue
        local json name
        json=$(nebula_cert_json "$bin_path" "$cert") || continue
        name=$(jq -r '.details.name' <<<"$json")
        while read -r ip; do
            [[ -n "$ip" ]] || continue
            local ip_str="${ip%%/*}" this_idx this_name
            this_idx=$idx; this_name=$name
            {
                if ping_output=$(ping -c 1 -W 1 "$ip_str" 2>/dev/null); then
                    local ping_time
                    ping_time=$(awk -F'=' '/time=/{print $4}' <<<"$ping_output" | awk '{print $1}')
                    [[ -z "$ping_time" ]] && ping_time=$(grep -oE 'time=[0-9.]+' <<<"$ping_output" | cut -d= -f2)
                    printf "%s|%s|%s|online|%s\n" "$this_idx" "$this_name" "$ip_str" "${ping_time:-0}"
                else
                    printf "%s|%s|%s|offline|timeout\n" "$this_idx" "$this_name" "$ip_str"
                fi
            } >>"$tmp_ping_out" &
            ((jobs++))
            ((jobs>=MAX_JOBS)) && { wait -n 2>/dev/null || true; ((jobs--)); }
            ROW_NAMES[$idx]="$name"
            ROW_IPS[$idx]="$ip_str"
            ((idx++))
        done < <(jq -r '.details.ips[]' <<<"$json")
    done
    while ((jobs>0)); do wait -n 2>/dev/null || break; ((jobs--)); done
    stop_spinner

    echo -e "${BOLD}${CYAN}${border_line}${RESET}"
    printf "${BOLD}${CYAN}| ${YELLOW}%-3s${CYAN}| ${YELLOW}%-22s${CYAN}| ${YELLOW}%-19s${CYAN}| ${YELLOW}%-11s${CYAN}| ${YELLOW}%-12s${CYAN}|\n" \
        "#" "Node Name:" "IP Address:" "Status:" "Ping:"
    echo -e "${BOLD}${CYAN}${border_line}${RESET}"
    local r_idx r_name r_ip r_state r_ping
    while IFS='|' read -r r_idx r_name r_ip r_state r_ping; do
        local status_display ping_display ping_color ping_int
        if [[ "$r_state" == "online" ]]; then
            ping_int=${r_ping%.*}
            if (( ping_int < 50 )); then ping_color=$GREEN
            elif (( ping_int < 150 )); then ping_color=$YELLOW
            else ping_color=$ORANGE; fi
            status_display="${GREEN}$(printf '%-13s' '✔ Online')${RESET}"
            ping_display="${ping_color}$(printf '%-12s' "${r_ping} ms")${RESET}"
        else
            status_display="${RED}$(printf '%-13s' '✘ Offline')${RESET}"
            ping_display="${WHITE}$(printf '%-12s' 'timeout')${RESET}"
        fi
        printf "${CYAN}| ${ORANGE}%-3s${CYAN}| ${YELLOW}%-22s${CYAN}| ${ORANGE}%-19s${CYAN}| %b${CYAN}| %b${CYAN}|\n" \
            "$r_idx" "$r_name" "$r_ip" "$status_display" "$ping_display"
    done < <(sort -t'|' -k1,1n "$tmp_ping_out")
    echo -e "${BOLD}${CYAN}${border_line}${RESET}"
    rm -f "$tmp_ping_out"

    read -rp "$(show_status 'question') Run an iperf3 throughput test to one of the above nodes? [y/N]: " run_test
    [[ "$run_test" =~ ^[Yy]$ ]] || return 0
    bench_require_iperf3 || return 1
    local max=$((idx-1)) sel
    (( max < 1 )) && { log_error "No targets available for iperf3."; return 1; }
    while :; do
        read -rp "$(show_status 'question') Enter # (1-$max) or 'q' to cancel: " sel
        [[ "$sel" == "q" || "$sel" == "Q" ]] && return 0
        [[ "$sel" =~ ^[0-9]+$ && sel -ge 1 && sel -le max ]] && break
        log_warn "Invalid selection."
    done
    local target_ip="${ROW_IPS[sel]}" target_name="${ROW_NAMES[sel]}"
    local port dur streams rev
    read -rp "$(show_status 'info') Port [5201]: " port;     port=${port:-5201}
    read -rp "$(show_status 'info') Duration seconds [10]: " dur; dur=${dur:-10}
    read -rp "$(show_status 'info') Parallel streams [-P] [1]: " streams; streams=${streams:-1}
    read -rp "$(show_status 'info') Reverse test (server→client) [y/N]: " rev
    log_info "Running iperf3 to ${MAGENTA}${target_name}${CYAN} (${ORANGE}${target_ip}${CYAN})…${RESET}"
    local -a rargs=()
    [[ "$rev" =~ ^[Yy]$ ]] && rargs+=(-R)
    bench_client "$target_ip" --port "$port" --time "$dur" --streams "$streams" "${rargs[@]}"
}

###################################################################
######################### Diagnostics #############################
###################################################################

# Parse `ss -lunp` (or netstat) output and return the local UDP port of a
# process whose name matches 'nebula'. Pure stdin filter -> easy to unit test.
_nebula_port_from_ss() {
    awk '
        /nebula/ {
            p = $4                      # Local Address:Port column
            sub(/.*:/, "", p)
            if (p ~ /^[0-9]+$/ && p != 0) { print p; exit }
        }
    '
}

# Best-effort, non-interactive detection of the running Nebula listen port.
# Process names are hidden from unprivileged `ss`, so we retry with a
# *passwordless* sudo when available. Never prompts.
autodetect_nebula_port() {
    command -v ss >/dev/null 2>&1 || return 1
    local out port
    out="$(ss -lunp 2>/dev/null)"
    if ! printf '%s' "$out" | grep -qi nebula; then
        if is_root || sudo -n true 2>/dev/null; then
            out="$(elevate ss -lunp 2>/dev/null || true)"
        fi
    fi
    port="$(printf '%s\n' "$out" | _nebula_port_from_ss)"
    [[ -n "$port" ]] && printf '%s' "$port"
}

# Explicit, possibly-interactive elevation for auto-detection (used only when
# the user opts in from the diagnostics viewer).
autodetect_nebula_port_elevated() {
    command -v ss >/dev/null 2>&1 || return 1
    elevate ss -lunp 2>/dev/null | _nebula_port_from_ss
}

# resolve_listen_port <config_file> -> prints "<port> <source>" where source is
# one of: config | auto | default.
resolve_listen_port() {
    local config_file="${1:-}" p=""
    if [[ -n "$config_file" && -r "$config_file" ]]; then
        p="$(awk '/listen:/,/port:/{if($1~/^port:/){gsub(/\r|\n|"/,"",$2);print $2}}' "$config_file" | head -n1)"
    fi
    if [[ -n "$p" && "$p" != "0" ]]; then printf '%s config' "$p"; return 0; fi
    local auto; auto="$(autodetect_nebula_port)"
    if [[ -n "$auto" ]]; then printf '%s auto' "$auto"; return 0; fi
    printf '%s default' "${NEBULA_DEFAULT_PORT:-4242}"
}

# List UDP listeners on a port. Tries ss, then netstat, then /proc/net/udp.
udp_listeners_on_port() {
    local port="$1" hex
    hex=$(printf '%04X' "$port" 2>/dev/null)
    if command -v ss >/dev/null 2>&1; then
        ss -lunp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lunp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
    elif [[ -r /proc/net/udp ]]; then
        awk -v h="$hex" 'NR>1 { split($2,a,":"); if (toupper(a[2])==h) print $0 }' /proc/net/udp || true
    fi
}

# diagnostics_view [cert-dir]
# Shows the Nebula TUN interface IP, the listening UDP socket and the
# certificate expiry — the three things you usually want when a tunnel
# "just stopped working". Handles config.yml owned by the service user and
# OS-assigned listen ports (listen.port: 0).
diagnostics_view() {
    local certs_dir="${1:-$(resolve_cert_dir)}"
    local configured_config="${NEBULA_DIR:-}/config.yml"
    local bin_path; bin_path="$(dirname "$(pki_cert_bin 2>/dev/null || echo /usr/bin/nebula-cert)")"

    # The config may be owned by the service user (e.g. nobody); get a copy.
    local cfg_file="" tmp_cfg=""
    if [[ -n "${NEBULA_DIR:-}" && -f "$configured_config" ]]; then
        cfg_file="$(readable_nebula_config "$configured_config")" || cfg_file=""
        [[ -n "$cfg_file" && "$cfg_file" != "$configured_config" ]] && tmp_cfg="$cfg_file"
    fi
    # A successful (possibly elevated) read refreshes the startup-header cache.
    [[ -n "$cfg_file" ]] && { _nebula_info_derive "$cfg_file" "$configured_config" >/dev/null 2>&1 || true; }

    echo -e "${BOLD}${CYAN}Nebula Manager diagnostics${RESET}"
    echo -e "${CYAN}------------------------------------------------------------${RESET}"

    # 1) TUN interface
    local iface=""
    [[ -n "$cfg_file" ]] && iface="$(iface_from_config "$cfg_file")"
    iface="${iface:-nebula1}"
    local ip_addr; ip_addr="$(iface_ip "$iface" 2>/dev/null || true)"
    echo -e "${BOLD}${YELLOW}TUN interface:${RESET}"
    echo -e "    dev:      ${CYAN}${iface}${RESET}"
    if iface_is_up "$iface"; then echo -e "    state:    ${GREEN}up${RESET}"
    else echo -e "    state:    ${RED}down/absent${RESET}"; fi
    echo -e "    ip:       ${CYAN}${ip_addr:-N/A}${RESET}"

    # 2) Listening UDP socket (auto-detects OS-assigned ports)
    local port_src port
    read -r port port_src _ < <(resolve_listen_port "$cfg_file")
    port="${port:-${NEBULA_DEFAULT_PORT:-4242}}"
    # When the port is OS-assigned and we couldn't detect it, offer interactive
    # users a one-shot elevated detection (opt-in; never prompts in scripts).
    if [[ "$port_src" == "default" && -t 0 ]] && ! is_root && command -v sudo >/dev/null 2>&1; then
        read -rp "$(show_status 'question') Listen port is OS-assigned/unknown. Detect it with sudo? [y/N]: " _d
        if [[ "$_d" =~ ^[Yy]$ ]]; then
            local _ep; _ep="$(autodetect_nebula_port_elevated)"
            [[ -n "$_ep" ]] && { port="$_ep"; port_src="auto"; }
        fi
    fi
    echo -e "${BOLD}${YELLOW}UDP listen socket:${RESET} port ${CYAN}${port}${RESET} ${GRAY}(${port_src:-unknown})${RESET}"
    local listeners; listeners="$(udp_listeners_on_port "$port")"
    if [[ -n "$listeners" ]]; then
        echo -e "    ${GREEN}$(echo "$listeners" | head -n1)${RESET}"
    else
        echo -e "    ${ORANGE}no listener detected on UDP ${port}${RESET}"
        if [[ "${port_src:-}" == "default" ]]; then
            echo -e "    ${YELLOW}hint: config listen.port may be 0 (OS-assigned); set ${BOLD}default_port${RESET}${YELLOW} in the conf or run with sudo for auto-detection.${RESET}"
        fi
    fi
    if [[ -n "${NEBULA_DIR:-}" && -f "$configured_config" && -z "$cfg_file" ]]; then
        echo -e "    ${YELLOW}note: $configured_config is not readable (service-owned); using defaults.${RESET}"
    fi

    # 3) Certificate expiration
    echo -e "${BOLD}${YELLOW}Certificate expiration:${RESET}"
    local -a candidates=()
    if [[ -n "$cfg_file" ]]; then
        local cfg_cert
        cfg_cert="$(awk -F: '/^[[:space:]]*cert[[:space:]]*:/ {gsub(/\r|\n|"/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "$cfg_file")"
        # Only use the configured cert when it is readable and not simply the
        # same file/basename we already have in the certificate workspace.
        if [[ -n "$cfg_cert" && -f "$cfg_cert" && -r "$cfg_cert" ]]; then
            local dupe=0 c base
            base="$(basename "$cfg_cert")"
            for c in "$certs_dir"/*.crt; do
                [[ -f "$c" && "$(basename "$c")" == "$base" ]] && { dupe=1; break; }
            done
            (( dupe )) || candidates+=("$cfg_cert")
        fi
    fi
    local cert
    for cert in "$certs_dir"/*.crt; do
        [[ -f "$cert" ]] || continue
        local isca; isca=$(nebula_cert_json "$bin_path" "$cert" | jq -r '.details.isCa // false')
        [[ "$isca" == "true" ]] && continue
        candidates+=("$cert")
    done

    local found=false
    for cert in "${candidates[@]}"; do
        [[ -f "$cert" ]] || continue
        local json name na days color
        json=$(nebula_cert_json "$bin_path" "$cert") || continue
        name=$(jq -r '.details.name' <<<"$json")
        na=$(jq -r '.details.notAfter' <<<"$json")
        days=$(pki_cert_days_left "$cert" 2>/dev/null || echo "?")
        color="$GREEN"
        [[ "$days" =~ ^-?[0-9]+$ ]] && { (( days <= 90 )) && color="$ORANGE"; (( days <= 30 )) && color="$RED"; }
        echo -e "    $name: notAfter ${CYAN}${na}${RESET} (${color}${days} day(s) left${RESET})"
        found=true
    done
    $found || echo -e "    ${ORANGE}no certificates found in $certs_dir${RESET}"

    echo -e "${CYAN}------------------------------------------------------------${RESET}"
    [[ -n "$cfg_file" ]] && echo -e "${GRAY}note: these values are cached for the startup header (no sudo needed next time).${RESET}"
    [[ -n "$tmp_cfg" ]] && rm -f "$tmp_cfg"
    return 0
}

###################################################################
########################### CLI entry ##############################
###################################################################

bench_cli() {
    local mode="${1:-}"; shift || true
    case "$mode" in
        server) bench_server "$@" ;;
        client) bench_client "$@" ;;
        "")     run_benchmark ;;
        *) log_error "Unknown 'bench' mode: $mode (expected 'server' or 'client')"; return 2 ;;
    esac
}

diag_cli() {
    diagnostics_view "${1:-}"
}
