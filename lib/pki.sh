#!/bin/bash
# shellcheck shell=bash
#
# lib/pki.sh - Certificate authority, signing, inspection & bundling
# ----------------------------------------------------------------
# All PKI work happens in a user-selectable "certificate workspace".
# When that workspace is user-owned (the default), none of this needs
# root. Only an explicitly privileged target directory triggers sudo
# (via ensure_dir/elevate from lib/system.sh).
#
# Workspace resolution precedence:
#   1. --cert-dir <path>            (CERT_DIR_OVERRIDE)
#   2. $NEBULA_KEYS_DIR             (environment)
#   3. saved interactive selection  (CERT_DIR_SELECTED / state file)
#   4. legacy per-server dir        ($NEBULA_DIR/$NEBULA_CERT_FOLDER)
#   5. default user directory       ($HOME/.local/share/nebula-manager/keys)

[[ -n "${NEBULA_MANAGER_PKI_SOURCED:-}" ]] && return 0
NEBULA_MANAGER_PKI_SOURCED=1

###################################################################
################### Certificate workspace directory ################
###################################################################

# Default, per-user, non-privileged certificate store.
nebula_keys_default_dir() {
    echo "${XDG_DATA_HOME:-$HOME/.local/share}/nebula-manager/keys"
}

# Where the "active workspace" selection is persisted.
nebula_keys_state_file() {
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/nebula-manager/certdir"
}

save_cert_dir_selection() {
    local dir="$1" f
    f="$(nebula_keys_state_file)"
    mkdir -p "$(dirname "$f")" 2>/dev/null
    printf '%s\n' "$dir" > "$f"
}

load_cert_dir_selection() {
    local f
    f="$(nebula_keys_state_file)"
    [[ -f "$f" ]] && head -n1 "$f"
}

# resolve_cert_dir : print the active certificate workspace directory.
resolve_cert_dir() {
    if [[ -n "${CERT_DIR_OVERRIDE:-}" ]]; then
        printf '%s\n' "$CERT_DIR_OVERRIDE"; return 0
    fi
    if [[ -n "${NEBULA_KEYS_DIR:-}" ]]; then
        printf '%s\n' "$NEBULA_KEYS_DIR"; return 0
    fi
    if [[ -n "${CERT_DIR_SELECTED:-}" ]]; then
        printf '%s\n' "$CERT_DIR_SELECTED"; return 0
    fi
    local saved; saved="$(load_cert_dir_selection)"
    if [[ -n "$saved" ]]; then
        printf '%s\n' "$saved"; return 0
    fi
    if [[ -n "${NEBULA_DIR:-}" ]]; then
        printf '%s\n' "${NEBULA_DIR}/${NEBULA_CERT_FOLDER:-certs}"; return 0
    fi
    nebula_keys_default_dir
}

# The active workspace, materialised (created if missing).
ensure_cert_dir() {
    local dir="${1:-$(resolve_cert_dir)}"
    ensure_dir "$dir" || return 1
    printf '%s\n' "$dir"
}

# Candidate existing stores, most specific first (only dirs that exist).
workspace_candidates() {
    local c
    for c in \
        "${NEBULA_KEYS_DIR:-}" \
        "${CERT_DIR_OVERRIDE:-}" \
        "${HOME:-}/keys/nebula" \
        "$(nebula_keys_default_dir)" \
        "${NEBULA_DIR:-}${NEBULA_DIR:+/${NEBULA_CERT_FOLDER:-certs}}"
    do
        [[ -n "$c" && -d "$c" ]] && printf '%s\n' "$c"
    done
}

# Is a certificate workspace already determined (so we should NOT prompt)?
# An explicit --cert-dir / NEBULA_KEYS_DIR, a saved selection, or a populated
# legacy server cert dir all count as "known".
nebula_keys_known() {
    [[ -n "${CERT_DIR_OVERRIDE:-}" ]] && return 0
    [[ -n "${NEBULA_KEYS_DIR:-}" ]] && return 0
    [[ -n "$(load_cert_dir_selection)" ]] && return 0
    if [[ -n "${NEBULA_DIR:-}" ]]; then
        local legacy="${NEBULA_DIR}/${NEBULA_CERT_FOLDER:-certs}"
        [[ -d "$legacy" ]] && ls "$legacy"/*.crt >/dev/null 2>&1 && return 0
    fi
    return 1
}

# First-run: offer to pick an existing workspace, browse, or keep the default.
# The reason is shown inside the dialog; invalid input loops back to the menu.
first_run_workspace_setup() {
    nebula_keys_known && return 0
    local default_dir suggested="" d
    default_dir="$(nebula_keys_default_dir)"
    while IFS= read -r d; do
        case "$d" in "$default_dir") ;; *) suggested="$d"; break ;; esac
    done < <(workspace_candidates)

    local reason="No certificate workspace selected yet.
Where do your keys/certs (ca.crt, *.crt) live?"
    local choice
    while true; do
        local -a menu=()
        [[ -n "$suggested" ]] && menu+=( "suggested" "Use existing store: $suggested" )
        menu+=( "default" "Use default store: $default_dir" )
        [[ -n "${NEBULA_DIR:-}" ]] && menu+=( "server" "Use server dir: ${NEBULA_DIR}/${NEBULA_CERT_FOLDER:-certs}" )
        menu+=( "browse" "Browse for a directory..." )
        menu+=( "skip"   "Skip for now (use default)" )

        local rc
        choice="$(ui_choose_or_path "Certificate Workspace" "$reason" "${menu[@]}")"; rc=$?
        if (( rc == 2 )); then
            reason="That was not a menu number or a directory.
Pick one of the options, or type a directory path."
            continue
        elif (( rc != 0 )); then
            choice="skip"
        fi
        case "$choice" in
            path:*)    CERT_DIR_SELECTED="${choice#path:}" ;;
            suggested) CERT_DIR_SELECTED="$suggested" ;;
            default)   CERT_DIR_SELECTED="$default_dir" ;;
            server)    CERT_DIR_SELECTED="${NEBULA_DIR}/${NEBULA_CERT_FOLDER:-certs}" ;;
            browse)
                local picked
                picked="$(ui_dselect "Select certificate directory" "Choose the directory containing ca.crt / *.crt" "${suggested:-${HOME:-$PWD}}")"
                if [[ -n "$picked" && -d "$picked" ]]; then
                    CERT_DIR_SELECTED="$picked"
                else
                    reason="No directory selected.
Pick a directory, or one of the options below."
                    continue
                fi
                ;;
            *) return 0 ;;
        esac
        break
    done
    save_cert_dir_selection "$CERT_DIR_SELECTED"
    ensure_dir "$CERT_DIR_SELECTED" || { log_error "Could not create $CERT_DIR_SELECTED"; return 1; }
    log_success "Certificate workspace set to: ${CYAN}$CERT_DIR_SELECTED${RESET}"
}

# Interactive workspace selector. Lists the current store, any detected stores,
# the default and the server dir; also accepts a typed directory (plain mode).
select_cert_workspace() {
    local current default_dir server_dir choice custom
    current="$(resolve_cert_dir)"
    default_dir="$(nebula_keys_default_dir)"
    server_dir="${NEBULA_DIR:-/etc/nebula}/${NEBULA_CERT_FOLDER:-certs}"

    while true; do
        show_menu_header "$MENU_PATH" "Certificates" "Workspaces"
        echo -e "${BOLD}${YELLOW}Active certificate workspace:${RESET} ${CYAN}$current${RESET}\n"

        local -a menu=( "current" "Use current: $current" )
        local c
        while IFS= read -r c; do
            [[ -n "$c" && "$c" != "$current" ]] && menu+=( "pick:$c" "Use detected store: $c" )
        done < <(workspace_candidates)
        menu+=(
            "default" "Use default user store: $default_dir"
            "server"  "Use this server's dir: $server_dir"
            "custom"  "Enter a custom path..."
        )

        local rc
        choice="$(ui_choose_or_path "Certificate Workspace" "Select a workspace (or type a directory):" "${menu[@]}")"; rc=$?
        if (( rc == 2 )); then
            log_error "Invalid choice - enter a menu number or a directory path."
            continue
        elif (( rc != 0 )); then
            return 0
        fi

        case "$choice" in
            path:*)  CERT_DIR_SELECTED="${choice#path:}" ;;
            pick:*)  CERT_DIR_SELECTED="${choice#pick:}" ;;
            current) CERT_DIR_SELECTED="$current" ;;
            default) CERT_DIR_SELECTED="$default_dir" ;;
            server)  CERT_DIR_SELECTED="$server_dir" ;;
            custom)
                custom="$(ui_input "Certificate Workspace" "Path to certificate store:" "${NEBULA_KEYS_DIR:-$default_dir}")" || return 0
                [[ -z "$custom" ]] && continue
                CERT_DIR_SELECTED="$custom"
                ;;
            *) return 0 ;;
        esac
        break
    done

    save_cert_dir_selection "$CERT_DIR_SELECTED"
    ensure_dir "$CERT_DIR_SELECTED" || { log_error "Could not create $CERT_DIR_SELECTED"; return 1; }
    log_success "Active certificate workspace set to: ${CYAN}$CERT_DIR_SELECTED${RESET}"
    if [[ -n "${CERT_DIR_OVERRIDE:-}" || -n "${NEBULA_KEYS_DIR:-}" ]]; then
        log_warn "--cert-dir / NEBULA_KEYS_DIR is set and overrides this saved selection."
    fi
}

###################################################################
########################## Nebula cert bin ########################
###################################################################

pki_cert_bin() {
    local bin="${NEBULA_BIN_PATH:-/usr/local/bin}/nebula-cert"
    if [[ -x "$bin" ]]; then
        printf '%s\n' "$bin"; return 0
    fi
    local resolved
    resolved="$(command -v nebula-cert 2>/dev/null)"
    if [[ -n "$resolved" ]]; then
        # Always hand back an absolute path so callers can dirname it safely.
        printf '%s\n' "$(readlink -f "$resolved")"; return 0
    fi
    log_error "nebula-cert not found (looked at $bin and \$PATH). Install Nebula first."
    return 1
}

# Normalize print -json output to a single object regardless of version
nebula_cert_json() {
    local bin_path="$1"
    local cert_path="$2"
    "$bin_path/nebula-cert" print -json -path "$cert_path" 2>/dev/null | \
        jq -r '
            if type == "array" then .[0] else . end |
            if .details.networks and (.details.ips | not) then .details.ips = .details.networks else . end |
            if .details.ips and (.details.networks | not) then .details.networks = .details.ips else . end |
            if .details.unsafeNetworks and (.details.subnets | not) then .details.subnets = .details.unsafeNetworks else . end |
            if .details.networks      == null then .details.networks      = [] else . end |
            if .details.ips           == null then .details.ips           = [] else . end |
            if .details.subnets       == null then .details.subnets       = [] else . end |
            if .details.groups        == null then .details.groups        = [] else . end
        ' 2>/dev/null
}

# Locate the CA, preferring the workspace itself, then the legacy server dir.
find_ca_crt() {
    local dir="${1:-$(resolve_cert_dir)}"
    for c in "$dir/ca.crt" "${NEBULA_DIR:-}/ca.crt"; do
        [[ -n "$c" && -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

find_ca_key() {
    local dir="${1:-$(resolve_cert_dir)}"
    for k in "$dir/ca.key" "${NEBULA_DIR:-}/ca.key"; do
        [[ -n "$k" && -f "$k" ]] && { printf '%s\n' "$k"; return 0; }
    done
    return 1
}

pki_cert_days_left() {
    local cert="$1" bin na epoch_na now
    bin="$(pki_cert_bin)" || return 1
    na=$(nebula_cert_json "$(dirname "$bin")" "$cert" | jq -r '.details.notAfter // empty')
    [[ -z "$na" ]] && return 1
    epoch_na=$(date -d "$na" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    echo $(( (epoch_na - now) / 86400 ))
}

###################################################################
######################## CA & cert creation ########################
###################################################################

# Non-interactive CA creation. Consumes (via environment):
#   CA_NAME, CA_DURATION, CA_GROUPS, CA_IPS, CA_SUBNETS, CA_ENCRYPT, CERT_DIR
pki_ca_create() {
    local cert_dir="${CERT_DIR:-$(resolve_cert_dir)}"
    local bin; bin="$(pki_cert_bin)" || return 1
    local name="${CA_NAME:?CA name is required}"
    local duration="${CA_DURATION:-999999h}"
    local -a args=("$bin" ca -name "$name" -duration "$duration"
        -out-key "$cert_dir/ca.key" -out-crt "$cert_dir/ca.crt")
    [[ -n "${CA_GROUPS:-}"  ]] && args+=(-groups "$CA_GROUPS")
    [[ -n "${CA_IPS:-}"     ]] && args+=(-ips "$CA_IPS")
    [[ -n "${CA_SUBNETS:-}" ]] && args+=(-subnets "$CA_SUBNETS")
    [[ "${CA_ENCRYPT:-n}" == "y" ]] && args+=(-encrypt)

    ensure_dir "$cert_dir" || return 1
    rm -f "$cert_dir/ca.crt" "$cert_dir/ca.key"
    if "${args[@]}"; then
        log_success "CA generated: $cert_dir/ca.key, $cert_dir/ca.crt"
        return 0
    fi
    log_error "Failed to generate CA."
    return 1
}

# Non-interactive cert signing. Consumes (via environment):
#   SIGN_NAME, SIGN_IP, SIGN_GROUPS, SIGN_SUBNETS, SIGN_DURATION_H, CERT_DIR
#   SIGN_IN_PUB  optional: a device-generated public key. When set the private
#                key stays on the device (mobile apps) and no .key is written.
#   SIGN_QR      optional: path to write a QR-code PNG of the signed cert.
pki_sign() {
    local cert_dir="${CERT_DIR:-$(resolve_cert_dir)}"
    local bin; bin="$(pki_cert_bin)" || return 1
    local name="${SIGN_NAME:?certificate name is required}"
    local ip="${SIGN_IP:?certificate IP is required}"
    local in_pub="${SIGN_IN_PUB:-}"
    local ca_crt ca_key
    ca_crt="$(find_ca_crt "$cert_dir")" || { log_error "CA certificate not found in $cert_dir"; return 1; }
    ca_key="$(find_ca_key "$cert_dir")" || { log_error "CA key not found in $cert_dir"; return 1; }

    if [[ -n "$in_pub" && ! -f "$in_pub" ]]; then
        log_error "Device public key not found: $in_pub"
        return 1
    fi

    local out_crt="$cert_dir/$name.crt"
    local -a args=("$bin" sign -name "$name" -ip "$ip"
        -ca-crt "$ca_crt" -ca-key "$ca_key"
        -out-crt "$out_crt")
    if [[ -n "$in_pub" ]]; then
        args+=(-in-pub "$in_pub")      # no -out-key: the key stays on the device
    else
        args+=(-out-key "$cert_dir/$name.key")
    fi
    [[ -n "${SIGN_DURATION_H:-}" ]] && args+=(-duration "${SIGN_DURATION_H}h")
    [[ -n "${SIGN_GROUPS:-}"     ]] && args+=(-groups "$SIGN_GROUPS")
    [[ -n "${SIGN_SUBNETS:-}"    ]] && args+=(-subnets "$SIGN_SUBNETS")
    [[ -n "${SIGN_QR:-}"         ]] && args+=(-out-qr "$SIGN_QR")

    ensure_dir "$cert_dir" || return 1
    if "${args[@]}"; then
        if [[ -n "$in_pub" ]]; then
            log_success "Certificate signed for device key: $out_crt"
        else
            log_success "Certificate signed: $out_crt and $cert_dir/$name.key"
        fi
        [[ -n "${SIGN_QR:-}" ]] && log_success "QR code written: ${SIGN_QR}"
        return 0
    fi
    log_error "Failed to sign certificate."
    return 1
}

# Interactive CA generation (TUI wrapper)
generate_nebula_ca() {
    local cert_dir; cert_dir="$(resolve_cert_dir)"
    local ca_key="$cert_dir/ca.key" ca_crt="$cert_dir/ca.crt"
    ensure_dir "$cert_dir" || { log_error "Nebula directory $cert_dir does not exist."; return 1; }

    if [[ -f "$ca_key" && -f "$ca_crt" ]]; then
        log_info "CA already exists:"
        "$(pki_cert_bin)" print -path "$ca_crt"
        read -p "$(show_status 'question') CA already exists. Do you want to overwrite it? (y/n): " overwrite
        [[ "$overwrite" != "y" ]] && { log_info "CA generation canceled."; return; }
    fi
    local ca_name
    while [[ -z "$ca_name" ]]; do
        read -p "$(show_status 'question') Enter the CA name (required): " ca_name
    done
    read -p "$(show_status 'question') Enter the duration (default 999999h, press enter to skip): " ca_duration
    read -p "$(show_status 'question') Enter groups (optional, comma-separated, press enter to skip): " ca_groups
    read -p "$(show_status 'question') Enter IPs (optional, comma-separated CIDR, press enter to skip): " ca_ips
    read -p "$(show_status 'question') Enter subnets (optional, comma-separated CIDR, press enter to skip): " ca_subnets
    read -p "$(show_status 'question') Use encryption for the private key? (y/n, default n): " use_encrypt
    [[ "$use_encrypt" == "y" ]] && CA_ENCRYPT="y" || CA_ENCRYPT="n"

    CERT_DIR="$cert_dir" CA_NAME="$ca_name" CA_DURATION="${ca_duration:-999999h}" \
        CA_GROUPS="$ca_groups" CA_IPS="$ca_ips" CA_SUBNETS="$ca_subnets" CA_ENCRYPT="$CA_ENCRYPT" \
        pki_ca_create
}

# --- suggestions for new client certs ----------------------------------------

# _ip4_to_int / _int_to_ip4 : small helpers for address arithmetic.
_ip4_to_int() {
    local IFS=.; local -a o=($1)
    printf '%s' "$(( (${o[0]:-0}<<24) | (${o[1]:-0}<<16) | (${o[2]:-0}<<8) | ${o[3]:-0} ))"
}
_int_to_ip4() {
    local n="$1"
    printf '%s.%s.%s.%s' "$(( (n>>24)&255 ))" "$(( (n>>16)&255 ))" "$(( (n>>8)&255 ))" "$(( n&255 ))"
}

# cert_domain_list <cert_dir> : distinct domains among non-CA cert names, one
# per line as "<domain>\t<count>", ordered by count (desc) then most-recent
# notBefore. The domain is printed WITHOUT the leading dot (e.g. theprof.mesh).
cert_domain_list() {
    local cert_dir="$1" bin bp
    bin="$(pki_cert_bin 2>/dev/null)" || return 0
    bp="$(dirname "$bin")"
    local -A counts=() latest=()
    local cert json name dom nb epoch
    for cert in "$cert_dir"/*.crt; do
        [[ -f "$cert" ]] || continue
        json="$(nebula_cert_json "$bp" "$cert" 2>/dev/null)" || continue
        [[ "$(jq -r '.details.isCa // false' <<<"$json" 2>/dev/null)" == "true" ]] && continue
        name="$(jq -r '.details.name // ""' <<<"$json" 2>/dev/null)"
        [[ "$name" == *.* ]] || continue
        dom="${name#*.}"
        [[ -n "$dom" ]] || continue
        nb="$(jq -r '.details.notBefore // ""' <<<"$json" 2>/dev/null)"
        epoch="$(date -d "$nb" +%s 2>/dev/null || echo 0)"
        counts["$dom"]=$(( ${counts["$dom"]:-0} + 1 ))
        (( epoch > ${latest["$dom"]:-0} )) && latest["$dom"]="$epoch"
    done
    local d
    for d in "${!counts[@]}"; do
        printf '%s\t%s\t%s\n' "$d" "${counts[$d]}" "${latest[$d]:-0}"
    done | sort -t$'\t' -k2,2nr -k3,3nr -k1,1
    return 0
}

# cert_domain_suffix <cert_dir> : the most common ".domain" suffix (with the dot),
# e.g. ".ulno.mesh" from ulno-framework.ulno.mesh, vps.ulno.mesh.
cert_domain_suffix() {
    local best
    best="$(cert_domain_list "$1" | head -n1 | cut -f1)"
    [[ -n "$best" ]] && printf '.%s' "$best"
    return 0
}

# suggest_cert_name <cert_dir> : "<short-hostname><domain>" (e.g. host.ulno.mesh).
suggest_cert_name() {
    local cert_dir="$1" host dom
    # `hostname` is not always installed; fall back to /etc/hostname, then $HOSTNAME.
    host="$(hostname -s 2>/dev/null || true)"
    [[ -n "$host" ]] || host="$(head -n1 /etc/hostname 2>/dev/null || true)"
    [[ -n "$host" ]] || host="${HOSTNAME:-}"
    host="${host%%.*}"                 # keep only the short name
    [[ -n "$host" ]] || return 0
    dom="$(cert_domain_suffix "$cert_dir")"
    printf '%s%s' "$host" "$dom"
}

# suggest_next_cert_ip <cert_dir> : "<ip>/<prefix>" - the next free host address
# in the overlay network used by most existing certs. Prints nothing if unknown.
suggest_next_cert_ip() {
    local cert_dir="$1" bin bp
    bin="$(pki_cert_bin 2>/dev/null)" || return 0
    bp="$(dirname "$bin")"
    local -a entries=()
    local cert json ip
    for cert in "$cert_dir"/*.crt; do
        [[ -f "$cert" ]] || continue
        json="$(nebula_cert_json "$bp" "$cert" 2>/dev/null)" || continue
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && entries+=("$ip")
        done < <(jq -r '.details.ips[]? // empty' <<<"$json" 2>/dev/null)
    done
    (( ${#entries[@]} )) || return 0

    # Group addresses by their network ("/prefix") and pick the most-used one.
    local -A netcount=() used=()
    local addr prefix ipint mask net e
    for e in "${entries[@]}"; do
        addr="${e%%/*}"; prefix="${e#*/}"
        [[ "$prefix" == "$e" ]] && prefix=24
        [[ "$prefix" =~ ^[0-9]+$ ]] || prefix=24
        ipint="$(_ip4_to_int "$addr")"
        mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF ))
        net=$(( ipint & mask ))
        netcount["${net}/${prefix}"]=$(( ${netcount["${net}/${prefix}"]:-0} + 1 ))
    done
    local best="" bestn=0 k
    for k in "${!netcount[@]}"; do
        (( ${netcount["$k"]} > bestn )) && { best="$k"; bestn="${netcount[$k]}"; }
    done
    [[ -n "$best" ]] || return 0
    net="${best%%/*}"; prefix="${best#*/}"
    mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF ))
    local hostcount=$(( 2 ** (32-prefix) ))
    (( hostcount > 65536 )) && return 0     # too large to scan for a free slot

    used["$net"]=1
    (( prefix > 0 && prefix <= 30 )) && used[$(( net | (0xFFFFFFFF >> prefix) ))]=1   # broadcast
    for e in "${entries[@]}"; do
        addr="${e%%/*}"; ipint="$(_ip4_to_int "$addr")"
        (( (ipint & mask) == net )) && used["$ipint"]=1
    done
    local i cand
    for (( i=1; i<hostcount-1; i++ )); do
        cand=$(( net + i ))
        [[ -n "${used[$cand]:-}" ]] && continue
        printf '%s/%s' "$(_int_to_ip4 "$cand")" "$prefix"
        return 0
    done
    return 0
}

# Interactive cert signing (TUI wrapper)
generate_nebula_cert() {
    local cert_dir; cert_dir="$(resolve_cert_dir)"
    local cert_gen_name="" cert_gen_ip="" cert_gen_groups="" include_subnets_choice="" cert_gen_subnets="" cert_gen_duration=""
    ensure_dir "$cert_dir" || { log_error "Failed to create $cert_dir."; return 1; }

    local suggested_name; suggested_name="$(suggest_cert_name "$cert_dir")"
    local name_prompt="Enter the certificate name: "
    [[ -n "$suggested_name" ]] && name_prompt="Enter the certificate name [${suggested_name}]: "
    while [[ -z "$cert_gen_name" ]]; do
        read -p "$(show_status 'question') $name_prompt" cert_gen_name || { log_info "Canceled."; return 1; }
        [[ -z "$cert_gen_name" && -n "$suggested_name" ]] && cert_gen_name="$suggested_name"
    done

    # If the user typed a bare name but existing certs use a mesh domain, offer to
    # append one. Never silently: confirm a single domain, or let them pick from
    # several (with "keep as-is" always available).
    if [[ "$cert_gen_name" != *.* ]]; then
        local -a dom_names=() dom_counts=()
        local d c _nb
        while IFS=$'\t' read -r d c _nb; do
            [[ -n "$d" ]] && { dom_names+=("$d"); dom_counts+=("$c"); }
        done < <(cert_domain_list "$cert_dir")
        if (( ${#dom_names[@]} == 1 )); then
            if ui_yesno "Certificate domain" "Existing certs use '.${dom_names[0]}'. Append it to '${cert_gen_name}'?"; then
                cert_gen_name="${cert_gen_name}.${dom_names[0]}"
            fi
        elif (( ${#dom_names[@]} > 1 )); then
            local -a dmenu=()
            local i
            for i in "${!dom_names[@]}"; do
                dmenu+=( "d$i" "${dom_names[i]} (${dom_counts[i]} certs)" )
            done
            dmenu+=( "keep" "Keep '${cert_gen_name}' as-is (no domain)" )
            local dchoice
            dchoice="$(ui_menu "Certificate domain" "'${cert_gen_name}' has no domain. Which domain should it get?" "${dmenu[@]}")" || dchoice="keep"
            case "$dchoice" in
                d*) cert_gen_name="${cert_gen_name}.${dom_names[${dchoice#d}]}" ;;
            esac
        fi
    fi

    if [[ -f "$cert_dir/$cert_gen_name.crt" ]]; then
        log_info "Certificate $cert_gen_name already exists in $cert_dir"
        "$(pki_cert_bin)" print -path "$cert_dir/$cert_gen_name.crt"
        read -p "$(show_status 'question') Do you want to overwrite this certificate? (y/n): " overwrite_choice
        [[ "$overwrite_choice" != "y" ]] && { log_info "Certificate generation aborted."; return; }
    fi

    # Mobile (Android/iOS): the app generates the keypair and exports only the
    # public key, so we sign that and emit a QR the app can scan. The private key
    # never leaves the device.
    local cert_is_mobile=0 cert_gen_pub="" cert_gen_qr=""
    if ui_yesno "Mobile device" "Is this certificate for a phone/tablet (Mobile Nebula)?"; then
        cert_is_mobile=1
        while [[ -z "$cert_gen_pub" ]]; do
            read -p "$(show_status 'question') Path to the device public key (exported from the app): " cert_gen_pub \
                || { log_info "Canceled."; return 1; }
            [[ -z "$cert_gen_pub" ]] && { log_info "A public key is required for a mobile device."; continue; }
            [[ -f "$cert_gen_pub" ]] || { log_error "File not found: $cert_gen_pub"; cert_gen_pub=""; }
        done
    fi

    local suggested_ip; suggested_ip="$(suggest_next_cert_ip "$cert_dir")"
    while true; do
        local ip_prompt="Enter the IP address (e.g., 192.168.222.16/24): "
        [[ -n "$suggested_ip" ]] && ip_prompt="Enter the IP address [${suggested_ip}]: "
        read -p "$(show_status 'question') $ip_prompt" cert_gen_ip || { log_info "Canceled."; return 1; }
        [[ -z "$cert_gen_ip" && -n "$suggested_ip" ]] && cert_gen_ip="$suggested_ip"
        if [[ "$cert_gen_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]; then
            [[ "$cert_gen_ip" =~ / ]] || cert_gen_ip="${cert_gen_ip}/24"
            local ip_taken=false
            for existing_crt in "$cert_dir"/*.crt; do
                [[ -f "$existing_crt" ]] || continue
                if nebula_cert_json "$(dirname "$(pki_cert_bin)")" "$existing_crt" | jq -e --arg ip "$cert_gen_ip" '.details.ips[]? == $ip' > /dev/null; then
                    log_error "IP $cert_gen_ip is already assigned in ${CYAN}$(basename "$existing_crt")${RED}. Choose another."
                    ip_taken=true
                    break
                fi
            done
            [[ "$ip_taken" == false ]] && break
        else
            log_error "Invalid IP address. Please enter a valid IP (e.g., 192.168.222.16/24)."
        fi
    done
    local groups_hint="servers,desktops"
    (( cert_is_mobile )) && groups_hint="mobile"
    read -p "$(show_status 'question') Enter the groups (optional, e.g., ${groups_hint}): " cert_gen_groups
    read -p "$(show_status 'question') Do you want to include subnets for this certificate? (y/n): " include_subnets_choice
    if [[ "$include_subnets_choice" == "y" ]]; then
        read -p "$(show_status 'question') Enter the subnets in CIDR format (comma-separated, e.g., 192.168.1.0/24,10.0.0.0/16): " cert_gen_subnets
    fi
    while true; do
        read -p "$(show_status 'question') Set certificate duration in hours (press Enter to skip and inherit CA expiration): " cert_gen_duration \
            || break
        [[ -z "$cert_gen_duration" ]] && break
        [[ "$cert_gen_duration" =~ ^[0-9]+$ ]] && break
        log_error "Please enter a whole number of hours (e.g., 720), or press Enter to skip."
    done
    if (( cert_is_mobile )); then
        local qr_default="$cert_dir/$cert_gen_name.png"
        read -p "$(show_status 'question') QR code output path [${qr_default}]: " cert_gen_qr
        [[ -z "$cert_gen_qr" ]] && cert_gen_qr="$qr_default"
    fi
    CERT_DIR="$cert_dir" SIGN_NAME="$cert_gen_name" SIGN_IP="$cert_gen_ip" \
        SIGN_GROUPS="$cert_gen_groups" SIGN_SUBNETS="$cert_gen_subnets" SIGN_DURATION_H="$cert_gen_duration" \
        SIGN_IN_PUB="$cert_gen_pub" SIGN_QR="$cert_gen_qr" \
        pki_sign
}

###################################################################
########################## Cert inspection #########################
###################################################################

list_certs() {
    local certs_dir; certs_dir="$(resolve_cert_dir)"
    local rows=()
    [[ -d "$certs_dir" ]] || { log_error "Certificates dir not found: $certs_dir"; return 1; }
    local bin_path; bin_path="$(dirname "$(pki_cert_bin)")"

    local cert
    for cert in "$certs_dir"/*.crt; do
        [[ -f "$cert" ]] || continue
        local json n t i g s nb na fp
        json=$(nebula_cert_json "$bin_path" "$cert")
        n=$(jq -r '.details.name' <<<"$json")
        t=$(jq -r '.details.isCa' <<<"$json"); t=$([[ $t == true ]] && echo "CA" || echo "Cert")
        i=$(jq -r '.details.ips | join(", ")' <<<"$json"); [[ -z "$i" ]] && i="N/A"
        g=$(jq -r '.details.groups | if length==0 then "None" else join(", ") end' <<<"$json")
        s=$(jq -r '.details.subnets | if length==0 then "None" else join(", ") end' <<<"$json")
        nb=$(jq -r '.details.notBefore' <<<"$json")
        na=$(jq -r '.details.notAfter' <<<"$json")
        fp=$(jq -r '.fingerprint' <<<"$json")
        rows+=("$n|$t|$i|$g|$s|$nb|$na|$fp")
    done

    [[ ${#rows[@]} -eq 0 ]] && { log_warn "No certificates found in $certs_dir."; return; }
    local sorted
    IFS=$'\n' sorted=($(printf "%s\n" "${rows[@]}" | sort -t "|" -k6))

    local border_len=158
    printf "${CYAN}%${border_len}s${RESET}\n" | tr ' ' '-'
    printf "${BOLD}${YELLOW} %-14s ${CYAN}|${YELLOW} %-4s ${CYAN}|${YELLOW} %-18s ${CYAN}|${YELLOW} %-18s ${CYAN}|${YELLOW} %-20s ${CYAN}|${YELLOW} %-20s ${CYAN}|${YELLOW} %-20s ${CYAN}|${YELLOW} %-16s ${RESET}\n" \
        "Name" "Type" "IPs" "Groups" "Subnets" "Not Before" "Not After" "Fingerprint"
    printf "${CYAN}%${border_len}s${RESET}\n" | tr ' ' '-'

    local now; now=$(date -u +%s)
    local row n t i g s nb na fp
    for row in "${sorted[@]}"; do
        IFS="|" read -r n t i g s nb na fp <<< "$row"
        local epoch_nb epoch_na color_nb color_na
        epoch_nb=$(date -d "$nb" +%s 2>/dev/null || echo 0)
        epoch_na=$(date -d "$na" +%s 2>/dev/null || echo 0)
        [[ $epoch_nb -le $now ]] && color_nb="${GREEN}" || color_nb="${WHITE}"
        [[ $epoch_na -le $now ]] && color_na="${RED}" || color_na="${GREEN}"
        printf " ${CYAN}%-14s${RESET} | ${ORANGE}%-4s${RESET} | ${GREEN}%-18s${RESET} | ${MAGENTA}%-18s${RESET} | ${YELLOW}%-20s${RESET} | ${color_nb}%-20s${RESET} | ${color_na}%-20s${RESET} | ${RED}%-16s${RESET}\n" \
            "$(maxlen "$n" 14)" "$t" "$(maxlen "$i" 18)" "$(maxlen "$g" 18)" "$(maxlen "$s" 20)" "$nb" "$na" "$(maxlen "$fp" 20)"
    done
    printf "${CYAN}%${border_len}s${RESET}\n" | tr ' ' '-'
}

# list_certs_expiry [max_days]
list_certs_expiry() {
    local certs_dir; certs_dir="$(resolve_cert_dir)"
    local max_days_filter="${1:-}" rows=()
    [[ -d "$certs_dir" ]] || { log_error "Certificates dir not found: $certs_dir"; return 1; }
    local bin_path; bin_path="$(dirname "$(pki_cert_bin)")"
    local now; now=$(date -u +%s)
    local cert
    for cert in "$certs_dir"/*.crt; do
        [[ -f "$cert" ]] || continue
        local json; json=$(nebula_cert_json "$bin_path" "$cert") || continue
        local name type na epoch_na days_left color
        name=$(jq -r '.details.name' <<<"$json")
        type=$(jq -r '.details.isCa'  <<<"$json"); type=$([[ $type == true ]] && echo "CA" || echo "Cert")
        na=$(jq -r '.details.notAfter'  <<<"$json")
        epoch_na=$(date -d "$na" +%s 2>/dev/null || echo 0)
        days_left=$(( (epoch_na - now) / 86400 ))
        (( days_left < 0 )) && days_left=0
        if [[ -n "$max_days_filter" && "$max_days_filter" =~ ^[0-9]+$ ]]; then
            (( days_left <= max_days_filter )) || continue
        fi
        if (( days_left > 365 )); then color="${GREEN}"
        elif (( days_left >= 181 )); then color="${YELLOW}"
        elif (( days_left >= 91 )); then color="${ORANGE}"
        else color="${RED}"; fi
        local years=$(( days_left / 365 )) rem=$(( days_left % 365 ))
        local months=$(( rem / 30 )) days=$(( rem % 30 )) human=""
        if (( years > 0 )); then human+="$years year$([[ $years -gt 1 ]] && echo "s")"; fi
        if (( months > 0 )); then [[ -n "$human" ]] && human+=", "; human+="$months month$([[ $months -gt 1 ]] && echo "s")"; fi
        if (( days > 0 )); then [[ -n "$human" ]] && human+=", and "; human+="$days day$([[ $days -gt 1 ]] && echo "s")"; fi
        [[ -z "$human" ]] && human="Expired"
        rows+=( "$(printf "%08d|%s|%s|%s|%s%s%s" "$days_left" "$name" "$type" "$na" "$color" "$human" "${RESET}")" )
    done
    [[ ${#rows[@]} -eq 0 ]] && { log_warn "No matching certificates found in $certs_dir."; return 0; }
    local -a sorted
    IFS=$'\n' read -r -d '' -a sorted < <(printf "%s\n" "${rows[@]}" | sort -t '|' -k1,1n && printf '\0')
    local border_len=94
    printf "${CYAN}%${border_len}s${RESET}\n" | tr ' ' '-'
    printf "${BOLD}${YELLOW} %-22s ${CYAN}|${YELLOW} %-4s ${CYAN}|${YELLOW} %-24s ${CYAN}|${YELLOW} %-30s ${RESET}\n" \
        "Name" "Type" "Not After (UTC)" "Expires In"
    printf "${CYAN}%${border_len}s${RESET}\n" | tr ' ' '-'
    local row
    for row in "${sorted[@]}"; do
        local _ name type na human
        IFS='|' read -r _ name type na human <<<"$row"
        printf " ${CYAN}%-22s${RESET} | ${ORANGE}%-4s${RESET} | ${WHITE}%-24s${RESET} | %b\n" \
            "$(maxlen "$name" 22)" "$type" "$na" "$human"
    done
    printf "${CYAN}%${border_len}s${RESET}\n" | tr ' ' '-'
}

# Print details of a single certificate (or a cert + key + CA block, as before)
view_cert_details() {
    local certs_dir; certs_dir="$(resolve_cert_dir)"
    local ca_cert_file cert_name cert_file key_file
    ca_cert_file="$(find_ca_crt "$certs_dir" || true)"
    [[ -d "$certs_dir" ]] || { log_error "Certificates directory $certs_dir does not exist."; return 1; }

    local certs_list="" cert
    for cert in "$certs_dir"/*.crt; do
        [[ -f "$cert" ]] && certs_list+="${CYAN}$(basename "$cert" .crt)${RESET}, "
    done
    certs_list=${certs_list%, }
    echo -e "    ${YELLOW}${BOLD}Certificates:${RESET} ${YELLOW}${certs_list}${RESET}"
    read -p "$(show_status 'question') Enter the name of the certificate to view details: " cert_name
    cert_file="$certs_dir/$cert_name.crt"
    key_file="$certs_dir/$cert_name.key"

    if [[ -f "$cert_file" ]]; then
        echo -e "\n${BG_BLUE}${BOLD}${WHITE} CERTIFICATE — Copy from BEGIN to END ${RESET}"
        echo -e "${YELLOW}File: ${BOLD}${cert_name}.crt${RESET}"
        echo -e "${YELLOW}------------------------------------------------------------${RESET}"
        cat "$cert_file"
        echo -e "${YELLOW}------------------------------------------------------------${RESET}"
    else
        log_error "Missing certificate file: $cert_file"
    fi
    if [[ -f "$key_file" ]]; then
        echo -e "\n${BG_RED}${BOLD}${WHITE} PRIVATE KEY — Copy from BEGIN to END ${RESET}"
        echo -e "${YELLOW}File: ${BOLD}${cert_name}.key${RESET}"
        echo -e "${YELLOW}------------------------------------------------------------${RESET}"
        cat "$key_file"
        echo -e "${YELLOW}------------------------------------------------------------${RESET}"
    else
        log_error "Missing key file: $key_file"
    fi
    if [[ -n "$ca_cert_file" && -f "$ca_cert_file" ]]; then
        echo -e "\n${BG_GREEN}${BOLD}${WHITE} CA CERTIFICATE — Copy from BEGIN to END ${RESET}"
        echo -e "${YELLOW}File: ca.crt${RESET}"
        echo -e "${YELLOW}------------------------------------------------------------${RESET}"
        cat "$ca_cert_file"
        echo -e "${YELLOW}------------------------------------------------------------${RESET}"
    else
        log_warn "CA certificate (ca.crt) not found in $certs_dir."
    fi
}

# remove_cert : interactive
remove_cert() {
    local certs_dir; certs_dir="$(resolve_cert_dir)"
    local cert_name_remove certs="" cert
    for cert in "$certs_dir"/*.crt; do
        [[ -f "$cert" ]] && certs+="${CYAN}$(basename "$cert" .crt)${RESET}, "
    done
    certs=${certs%, }
    echo -e "    $certs"
    read -p "$(show_status 'question') Enter the name of the certificate to remove: " cert_name_remove
    pki_remove "$cert_name_remove"
}

# pki_remove <name> [cert_dir]
pki_remove() {
    local name="$1" certs_dir="${2:-$(resolve_cert_dir)}"
    local crt_file="$certs_dir/$name.crt" key_file="$certs_dir/$name.key"
    if [[ -f "$crt_file" && -f "$key_file" ]]; then
        rm -f "$crt_file" "$key_file" && log_success "Removed $crt_file and $key_file."
    else
        log_error "Certificate $name not found in $certs_dir"
        return 1
    fi
}

# revoke_cert : interactive (blocklist editing lives in config.yml)
revoke_cert() {
    local certs_dir config_file
    certs_dir="$(resolve_cert_dir)"
    config_file="${NEBULA_DIR:-/etc/nebula}/config.yml"
    local bin_path; bin_path="$(dirname "$(pki_cert_bin)")"

    echo -e "$(show_status 'info') ${YELLOW}Current Revoked Certificates:${RESET}"
    local in_blocklist=false i=0 line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*blocklist: ]] && in_blocklist=true && continue
        [[ "$in_blocklist" == true && ! "$line" =~ ^[[:space:]]*-[[:space:]] ]] && in_blocklist=false
        if [[ "$in_blocklist" == true && "$line" =~ -[[:space:]]+([^#[:space:]]+)[[:space:]]*(#.*)?$ ]]; then
            local fp="${BASH_REMATCH[1]}" reason="${BASH_REMATCH[2]}" cert
            [[ $reason =~ ^[[:space:]]*#[[:space:]]*(.*)$ ]] && reason="${BASH_REMATCH[1]}"
            local match="Unknown cert name"
            for cert in "$certs_dir"/*.crt.revoked; do
                [[ -f "$cert" ]] || continue
                local cert_fp; cert_fp=$(nebula_cert_json "$bin_path" "$cert" | jq -r '.fingerprint')
                [[ "$cert_fp" == "$fp" ]] && match=$(basename "$cert" .crt.revoked) && break
            done
            echo -e "    ${YELLOW}[$(($i+1))]${RESET} ${CYAN}$fp${RESET} - $match${reason:+ (${MAGENTA}$reason${RESET})}"
            ((i++))
        fi
    done < "$config_file"
    (( i == 0 )) && printf "%b\n" "    ${ORANGE}No revoked fingerprints found in blocklist.${RESET}"

    local action="" cert_name_or_fingerprint fingerprint cert_file cert_key revoke_choice revoke_by_name=true
    while :; do
        echo -ne "\n$(show_status 'question') What would you like to do? [${YELLOW}a${RESET}]dd / [${YELLOW}r${RESET}]emove / [${YELLOW}b${RESET}]ack: "
        read -r action
        case "${action,,}" in
            a|add|1)    action="add";    break ;;
            r|remove|2) action="remove"; break ;;
            b|back|q|0) log_info "Returning to previous menu."; return ;;
            *) log_error "Invalid choice. Please type a/r/b." ;;
        esac
    done

    if [[ "$action" == "remove" ]]; then
        echo -ne "$(show_status 'question') Enter fingerprint to remove from revocation list: "
        read -r fingerprint
        [[ -z "$fingerprint" ]] && { log_error "No fingerprint provided."; return; }
        sed -i "/- $fingerprint/d" "$config_file"
        log_success "Removed fingerprint ${CYAN}$fingerprint${GREEN} from blocklist."
        local cert
        for cert in "$certs_dir"/*.crt.revoked; do
            [[ -f "$cert" ]] || continue
            local cert_fp; cert_fp=$(nebula_cert_json "$bin_path" "$cert" | jq -r '.fingerprint')
            if [[ "$cert_fp" == "$fingerprint" ]]; then
                local base="${cert%.crt.revoked}"
                mv "$cert" "${base}.crt"
                [[ -f "${base}.key.revoked" ]] && mv "${base}.key.revoked" "${base}.key"
                log_info "Restored certificate: $(basename "$base")"
                break
            fi
        done
        read -p "$(show_status 'question') Reload Nebula service to apply changes? (y/n): " reload_choice
        [[ "$reload_choice" == "y" ]] && elevate systemctl reload "$(basename "${NEBULA_SERVICE:-nebula.service}")" \
            && log_success "Nebula service reloaded."
        return
    fi

    while [[ "$revoke_choice" != "1" && "$revoke_choice" != "2" ]]; do
        echo -ne "$(show_status 'question') Revoke by certificate name (${YELLOW}1${RESET}) or fingerprint (${YELLOW}2${RESET})?: "
        read -r revoke_choice
    done
    if [[ "$revoke_choice" == "1" ]]; then
        echo -e "    ${YELLOW}${BOLD}Certificates:${RESET}"
        local cert
        for cert in "$certs_dir"/*.crt; do
            [[ -f "$cert" ]] && echo "      - $(basename "$cert" .crt)"
        done
        read -p "$(show_status 'question') Enter the certificate name to revoke: " cert_name_or_fingerprint
        cert_file="${certs_dir}/$cert_name_or_fingerprint.crt"
        cert_key="${certs_dir}/$cert_name_or_fingerprint.key"
        if [[ ! -f "$cert_file" || ! -f "$cert_key" ]]; then
            log_error "Certificate not found: $cert_name_or_fingerprint"; return
        fi
        fingerprint=$(nebula_cert_json "$bin_path" "$cert_file" | jq -r '.fingerprint')
    else
        read -p "$(show_status 'question') Enter the full certificate fingerprint to revoke: " fingerprint
        revoke_by_name=false
    fi
    if grep -q "$fingerprint" "$config_file"; then
        log_info "Fingerprint already revoked: ${CYAN}$fingerprint${RESET}"; return
    fi
    local reason
    read -p "$(show_status 'question') Enter a reason for revocation: " reason
    if [[ "$revoke_by_name" == true ]]; then
        mv "$cert_file" "$cert_file.revoked"
        mv "$cert_key" "$cert_key.revoked"
    fi
    sed -i "/^ *blocklist:/a \ \ \ \ - $fingerprint # $reason" "$config_file"
    log_success "Added fingerprint ${CYAN}$fingerprint${GREEN} to blocklist with reason: ${MAGENTA}$reason${RESET}"
    local reload_choice
    read -p "$(show_status 'question') Reload Nebula service to apply changes? (y/n): " reload_choice
    [[ "$reload_choice" == "y" ]] && elevate systemctl reload "$(basename "${NEBULA_SERVICE:-nebula.service}")" \
        && log_success "Nebula service reloaded."
}

###################################################################
######################### Client bundling ##########################
###################################################################

# Write a minimal, ready-to-edit nebula config template for a client bundle.
pki_write_client_config() {
    local outfile="$1" name="$2"
    cat > "$outfile" <<EOF
# Nebula client configuration for '$name'
# Generated by nebula-manager. Adjust static_host_map / lighthouse.hosts
# for your network, then place the referenced files on the client.
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/$name.crt
  key: /etc/nebula/$name.key

static_host_map:
  # "10.42.0.1": ["203.0.113.10:4242"]

lighthouse:
  am_lighthouse: false
  interval: 60
  hosts:
    # - "10.42.0.1"

listen:
  host: 0.0.0.0
  port: 4242

punchy:
  punch: true

tun:
  dev: nebula1
EOF
}

# pki_bundle_client_zip <name> [out_dir] [cert_dir]
# Produces <name>-nebula-bundle.zip containing cert, key, ca.crt and a
# config template. Runs entirely unprivileged.
pki_bundle_client_zip() {
    local name="${1:?client name required}"
    local out_dir="${2:-$PWD}"
    local cert_dir="${3:-$(resolve_cert_dir)}"
    local crt="$cert_dir/$name.crt" key="$cert_dir/$name.key"
    local ca; ca="$(find_ca_crt "$cert_dir" || true)"

    [[ -f "$crt" ]] || { log_error "Certificate not found: $crt"; return 1; }
    [[ -f "$key" ]] || { log_error "Key not found: $key"; return 1; }
    [[ -n "$ca" && -f "$ca" ]] || { log_error "CA certificate not found for $name"; return 1; }

    ensure_dir "$out_dir" || return 1
    local tmp; tmp="$(mktemp -d)"
    cp "$crt" "$tmp/$name.crt"
    cp "$key" "$tmp/$name.key"
    cp "$ca"  "$tmp/ca.crt"
    pki_write_client_config "$tmp/config.yml.template" "$name"

    local zipfile="$out_dir/${name}-nebula-bundle.zip"
    rm -f "$zipfile"
    if command -v zip >/dev/null 2>&1; then
        ( cd "$tmp" && zip -q "$zipfile" "$name.crt" "$name.key" ca.crt config.yml.template ) \
            || { log_error "Failed to create zip bundle."; rm -rf "$tmp"; return 1; }
    else
        local tarball="$out_dir/${name}-nebula-bundle.tar.gz"
        ( cd "$tmp" && tar -czf "$tarball" "$name.crt" "$name.key" ca.crt config.yml.template ) \
            || { log_error "Failed to create tar bundle."; rm -rf "$tmp"; return 1; }
        rm -rf "$tmp"
        log_warn "zip not found; wrote $tarball instead."
        printf '%s\n' "$tarball"
        return 0
    fi
    rm -rf "$tmp"
    log_success "Client bundle created: $zipfile"
    printf '%s\n' "$zipfile"
}

###################################################################
########################### Menus / CLI ############################
###################################################################

manage_nebula_certs() {
    ensure_cert_dir >/dev/null || return 1
    dynamic_menu_title=("$MENU_PATH" "Certificate Management")
    dynamic_menu_options=(
        "$(get_icon 'list')List Certificates"
        "$(get_icon 'create')Generate CA Certificate"
        "$(get_icon 'create')Generate Client Certificate"
        "$(get_icon 'inspect')View Certificate and Key Details"
        "$(get_icon 'hour-glass')Certificate Expiry"
        "$(get_icon 'upload')Bundle Client Zip"
        "$(get_icon 'revoke')Revoke Certificate"
        "$(get_icon 'keys')Switch Certificate Workspace"
        "$(get_icon 'error')Remove Certificate"
    )
    dynamic_menu_functions=(
        "list_certs"
        "generate_nebula_ca"
        "generate_nebula_cert"
        "view_cert_details"
        "list_certs_expiry"
        "pki_bundle_client_menu"
        "revoke_cert"
        "select_cert_workspace"
        "remove_cert"
    )
    dynamic_menu dynamic_menu_title dynamic_menu_options dynamic_menu_functions 1
}

pki_bundle_client_menu() {
    local name out default_out
    read -p "$(show_status 'question') Client certificate name to bundle: " name
    [[ -z "$name" ]] && return
    default_out="$PWD"
    out="$(ui_input "Bundle Client" "Output directory:" "$default_out")" || return
    pki_bundle_client_zip "$name" "${out:-$default_out}"
}

# --- Headless CLI --------------------------------------------------

pki_cli() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        list)   list_certs ;;
        expiry) list_certs_expiry "${1:-}" ;;
        remove|rm) pki_remove "${1:?certificate name required}" ;;
        bundle)
            local name="${1:?client name required}"; shift || true
            pki_bundle_client_zip "$name" "${1:-$PWD}"
            ;;
        workspace)
            select_cert_workspace ;;
        *) log_error "Unknown 'cert' subcommand: $sub"; return 2 ;;
    esac
}

pki_ca_cli() {
    # Entry already stripped the 'ca' command; an optional create/init verb may follow.
    [[ "${1:-}" == "create" || "${1:-}" == "init" ]] && shift
    local name="" duration="" groups="" ips="" subnets="" encrypt="n" cert_dir=""
    while (($#)); do
        case "$1" in
            --name|-n) shift; name="$1" ;;
            --duration|-d) shift; duration="$1" ;;
            --groups|-g) shift; groups="$1" ;;
            --ips|-i) shift; ips="$1" ;;
            --subnets|-s) shift; subnets="$1" ;;
            --encrypt) encrypt="y" ;;
            --cert-dir) shift; cert_dir="$1" ;;
            *) log_warn "Ignoring unknown option for 'ca': $1" ;;
        esac
        shift
    done
    [[ -z "$name" ]] && { echo "Usage: nebula-manager ca [create] --name NAME [--duration 999999h] [--groups a,b] [--ips CIDR] [--subnets CIDR] [--encrypt] [--cert-dir DIR]" >&2; return 2; }
    CERT_DIR="${cert_dir:-$(resolve_cert_dir)}" CA_NAME="$name" CA_DURATION="${duration:-999999h}" \
        CA_GROUPS="$groups" CA_IPS="$ips" CA_SUBNETS="$subnets" CA_ENCRYPT="$encrypt" \
        pki_ca_create
}

pki_sign_cli() {
    local name="" ip="" groups="" subnets="" duration="" cert_dir="" in_pub="" qr=""
    local name_given=0
    while (($#)); do
        case "$1" in
            --name|-n) shift; name="$1"; name_given=1 ;;
            --ip|-i) shift; ip="$1" ;;
            --groups|-g) shift; groups="$1" ;;
            --subnets|-s) shift; subnets="$1" ;;
            --duration|-d) shift; duration="$1" ;;
            --cert-dir) shift; cert_dir="$1" ;;
            --in-pub) shift; in_pub="$1" ;;
            --qr|--out-qr) shift; qr="$1" ;;
            --) shift; break ;;
            *)
                if [[ -z "$name" ]]; then name="$1"; name_given=1
                elif [[ -z "$ip" ]]; then ip="$1"
                else log_warn "Ignoring extra argument: $1"; fi
                ;;
        esac
        shift
    done
    cert_dir="${cert_dir:-$(resolve_cert_dir)}"

    # Fill missing values from suggestions derived from the existing certs, so
    # `nebula-manager sign` alone does the sensible thing (name = <host><domain>,
    # ip = next free overlay address). Explicit flags always win.
    if [[ -z "$name" ]]; then
        name="$(suggest_cert_name "$cert_dir")"
        [[ -n "$name" ]] && log_info "Using suggested name: ${CYAN}$name${RESET}"
    fi
    # A bare name while existing certs use a domain: hint, never change silently.
    if (( name_given )) && [[ -n "$name" && "$name" != *.* ]]; then
        local first_dom
        first_dom="$(cert_domain_list "$cert_dir" | head -n1 | cut -f1)"
        if [[ -n "$first_dom" ]]; then
            log_warn "Certificate name '$name' has no domain; your other certs use '.$first_dom'."
            log_info "Re-run with --name '$name.$first_dom' if that is what you meant (not changed automatically)."
        fi
    fi
    if [[ -z "$ip" ]]; then
        ip="$(suggest_next_cert_ip "$cert_dir")"
        [[ -n "$ip" ]] && log_info "Using suggested IP: ${CYAN}$ip${RESET}"
    fi

    if [[ -z "$name" || -z "$ip" ]]; then
        echo "Usage: nebula-manager sign [--name NAME] [--ip CIDR] [--in-pub KEY.pub] [--qr OUT.png] [--groups a,b] [--subnets CIDR] [--duration HOURS] [--cert-dir DIR]" >&2
        log_error "Could not derive a certificate name/IP automatically; pass --name and/or --ip."
        return 2
    fi
    if [[ -n "$in_pub" && ! -f "$in_pub" ]]; then
        log_error "Device public key not found: $in_pub"
        return 2
    fi
    # strip a trailing 'h' from duration if the user supplied one
    duration="${duration%h}"
    CERT_DIR="$cert_dir" SIGN_NAME="$name" SIGN_IP="$ip" \
        SIGN_GROUPS="$groups" SIGN_SUBNETS="$subnets" SIGN_DURATION_H="$duration" \
        SIGN_IN_PUB="$in_pub" SIGN_QR="$qr" \
        pki_sign
}
