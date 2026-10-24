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
        debug_info "cert-dir: --cert-dir -> $CERT_DIR_OVERRIDE"
        printf '%s\n' "$CERT_DIR_OVERRIDE"; return 0
    fi
    if [[ -n "${NEBULA_KEYS_DIR:-}" ]]; then
        debug_info "cert-dir: NEBULA_KEYS_DIR -> $NEBULA_KEYS_DIR"
        printf '%s\n' "$NEBULA_KEYS_DIR"; return 0
    fi
    if [[ -n "${CERT_DIR_SELECTED:-}" ]]; then
        debug_info "cert-dir: saved selection -> $CERT_DIR_SELECTED"
        printf '%s\n' "$CERT_DIR_SELECTED"; return 0
    fi
    local saved; saved="$(load_cert_dir_selection)"
    if [[ -n "$saved" ]]; then
        debug_info "cert-dir: saved workspace -> $saved"
        printf '%s\n' "$saved"; return 0
    fi
    if [[ -n "${NEBULA_DIR:-}" ]]; then
        debug_info "cert-dir: legacy server dir -> ${NEBULA_DIR}/${NEBULA_CERT_FOLDER:-certs}"
        printf '%s\n' "${NEBULA_DIR}/${NEBULA_CERT_FOLDER:-certs}"; return 0
    fi
    local fallback; fallback="$(nebula_keys_default_dir)"
    debug_info "cert-dir: default user store -> $fallback"
    printf '%s\n' "$fallback"
}

# The active workspace, materialised (created if missing).
ensure_cert_dir() {
    local dir="${1:-$(resolve_cert_dir)}"
    ensure_dir "$dir" || return 1
    CERT_STORE_AUDIT_DIR="$dir"; export CERT_STORE_AUDIT_DIR
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
    CERT_STORE_AUDIT_DIR="$CERT_DIR_SELECTED"; export CERT_STORE_AUDIT_DIR
    debug_explain "Switching the active workspace changes which .crt/.key files all certificate actions use."
    if declare -F cert_store_log >/dev/null; then
        cert_store_log "$CERT_DIR_SELECTED" "workspace-select dir=\"$CERT_DIR_SELECTED\""
    fi
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
        debug_info "nebula-cert: $bin"
        printf '%s\n' "$bin"; return 0
    fi
    local resolved
    resolved="$(command -v nebula-cert 2>/dev/null)"
    if [[ -n "$resolved" ]]; then
        # Always hand back an absolute path so callers can dirname it safely.
        resolved="$(readlink -f "$resolved")"
        debug_info "nebula-cert: $resolved (from PATH)"
        printf '%s\n' "$resolved"; return 0
    fi
    log_error "nebula-cert not found (looked at $bin and \$PATH). Install Nebula first."
    return 1
}

# Normalize print -json output to a single object regardless of version
nebula_cert_json() {
    local bin_path="$1"
    local cert_path="$2"
    debug_run_quiet "$bin_path/nebula-cert" print -json -path "$cert_path" | \
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
    CERT_STORE_AUDIT_DIR="$cert_dir"; export CERT_STORE_AUDIT_DIR
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
    debug_explain "Creating a certificate authority: ca.crt is the public trust anchor and ca.key signs every client certificate."
    debug_explain "Keep ca.key secret and never copy it to a client; an existing CA is snapshotted first."
    # Preserve the old CA (if any) before regenerating it.
    if declare -F cert_store_snapshot_before >/dev/null; then
        cert_store_snapshot_before "$cert_dir" "ca-create $name" \
            "$cert_dir/ca.crt" "$cert_dir/ca.key" || true
    fi
    rm -f "$cert_dir/ca.crt" "$cert_dir/ca.key"
    if debug_run "${args[@]}"; then
        if declare -F cert_store_log >/dev/null; then
            cert_store_log "$cert_dir" "ca-create name=\"$name\" duration=\"$duration\""
        fi
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
    CERT_STORE_AUDIT_DIR="$cert_dir"; export CERT_STORE_AUDIT_DIR
    local ca_crt ca_key
    ca_crt="$(find_ca_crt "$cert_dir")" || { log_error "CA certificate not found in $cert_dir"; return 1; }
    ca_key="$(find_ca_key "$cert_dir")" || { log_error "CA key not found in $cert_dir"; return 1; }

    if [[ -n "$in_pub" && ! -f "$in_pub" ]]; then
        log_error "Device public key not found: $in_pub"
        return 1
    fi

    local out_crt="$cert_dir/$name.crt"
    local out_key="$cert_dir/$name.key"
    local overwrite=0 used_pub=no
    [[ -f "$out_crt" || -f "$out_key" ]] && overwrite=1
    [[ -n "$in_pub" ]] && used_pub=yes
    if (( overwrite )) && declare -F cert_store_snapshot_before >/dev/null; then
        cert_store_snapshot_before "$cert_dir" "sign $name (overwrite)" "$out_crt" "$out_key" || true
    fi
    debug_explain "Signing '$name' for overlay IP(s) '$ip' with groups '${SIGN_GROUPS:-none}' using the CA in $cert_dir."
    if [[ -n "$in_pub" ]]; then
        debug_explain "Device-generated public key: the private key stays on the device and no .key is written here."
    else
        debug_explain "A new private key (.key) is written next to the certificate; deliver it only to that device."
    fi
    if (( overwrite )); then
        debug_explain "Existing certificate/key files are replaced; the snapshot above keeps the old ones."
    fi
    local tmpdir out_tmp key_tmp
    tmpdir="$(mktemp -d)" || return 1
    out_tmp="$tmpdir/$name.crt"
    key_tmp="$tmpdir/$name.key"
    local -a args=("$bin" sign -name "$name" -ip "$ip"
        -ca-crt "$ca_crt" -ca-key "$ca_key"
        -out-crt "$out_tmp")
    if [[ -n "$in_pub" ]]; then
        args+=(-in-pub "$in_pub")      # no -out-key: the key stays on the device
    else
        args+=(-out-key "$key_tmp")
    fi
    [[ -n "${SIGN_DURATION_H:-}" ]] && args+=(-duration "${SIGN_DURATION_H}h")
    [[ -n "${SIGN_GROUPS:-}"     ]] && args+=(-groups "$SIGN_GROUPS")
    [[ -n "${SIGN_SUBNETS:-}"    ]] && args+=(-subnets "$SIGN_SUBNETS")
    [[ -n "${SIGN_QR:-}"         ]] && args+=(-out-qr "$SIGN_QR")

    ensure_dir "$cert_dir" || { rm -rf "$tmpdir"; return 1; }
    if debug_run "${args[@]}"; then
        # nebula-cert refuses to overwrite an existing crt/key, so sign to a
        # temporary directory and install the result ourselves. The old files
        # (when overwriting) were snapshotted above.
        if ! cp "$out_tmp" "$out_crt"; then
            log_error "Could not write $out_crt"
            rm -rf "$tmpdir"
            return 1
        fi
        chmod 644 "$out_crt" 2>/dev/null || true
        if [[ -z "$in_pub" ]]; then
            if ! cp "$key_tmp" "$out_key"; then
                log_error "Could not write $out_key"
                rm -rf "$tmpdir"
                return 1
            fi
            chmod 600 "$out_key" 2>/dev/null || true
        fi
        rm -rf "$tmpdir"
        if declare -F cert_store_log >/dev/null; then
            cert_store_log "$cert_dir" "sign name=\"$name\" ip=\"$ip\" groups=\"${SIGN_GROUPS:-}\" overwrite=$overwrite in_pub=$used_pub"
        fi
        if [[ -n "$in_pub" ]]; then
            log_success "Certificate signed for device key: $out_crt"
        else
            log_success "Certificate signed: $out_crt and $out_key"
        fi
        [[ -n "${SIGN_QR:-}" ]] && log_success "QR code written: ${SIGN_QR}"
        return 0
    fi
    rm -rf "$tmpdir"
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
        debug_run "$(pki_cert_bin)" print -path "$ca_crt"
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
        debug_run "$(pki_cert_bin)" print -path "$cert_dir/$cert_gen_name.crt"
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
    CERT_STORE_AUDIT_DIR="$certs_dir"; export CERT_STORE_AUDIT_DIR
    debug_explain "Removing '$name' (certificate + private key) from the store; a snapshot/backup is taken first."
    if [[ -f "$crt_file" && -f "$key_file" ]]; then
        if declare -F cert_store_snapshot_before >/dev/null; then
            cert_store_snapshot_before "$certs_dir" "remove $name" "$crt_file" "$key_file" || true
        fi
        rm -f "$crt_file" "$key_file" && log_success "Removed $crt_file and $key_file."
        if declare -F cert_store_log >/dev/null; then
            cert_store_log "$certs_dir" "remove name=\"$name\" snapshot=\"${CERT_STORE_LAST_SNAPSHOT:-none}\""
        fi
    else
        log_error "Certificate $name not found in $certs_dir"
        return 1
    fi
}

# revoke_cert : interactive (blocklist editing lives in config.yml)
revoke_cert() {
    local certs_dir config_file
    certs_dir="$(resolve_cert_dir)"
    CERT_STORE_AUDIT_DIR="$certs_dir"; export CERT_STORE_AUDIT_DIR
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
                if declare -F cert_store_log >/dev/null; then
                    cert_store_log "$certs_dir" "revoke-restore fingerprint=\"$fingerprint\""
                fi
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
        debug_explain "Revocation records the fingerprint in the Nebula blocklist and renames the local cert/key to *.revoked."
        if declare -F cert_store_snapshot_before >/dev/null; then
            cert_store_snapshot_before "$certs_dir" "revoke $cert_name_or_fingerprint" "$cert_file" "$cert_key" || true
        fi
        mv "$cert_file" "$cert_file.revoked"
        mv "$cert_key" "$cert_key.revoked"
    fi
    sed -i "/^ *blocklist:/a \ \ \ \ - $fingerprint # $reason" "$config_file"
    if declare -F cert_store_log >/dev/null; then
        cert_store_log "$certs_dir" "revoke name=\"${cert_name_or_fingerprint:-}\" fingerprint=\"$fingerprint\" reason=\"$reason\""
    fi
    log_success "Added fingerprint ${CYAN}$fingerprint${GREEN} to blocklist with reason: ${MAGENTA}$reason${RESET}"
    local reload_choice
    read -p "$(show_status 'question') Reload Nebula service to apply changes? (y/n): " reload_choice
    [[ "$reload_choice" == "y" ]] && elevate systemctl reload "$(basename "${NEBULA_SERVICE:-nebula.service}")" \
        && log_success "Nebula service reloaded."
}

###################################################################
######################### Client bundling ##########################
###################################################################

###################################################################
############ Network settings for generated client configs ########
###################################################################

# _pki_cfg_scalar <file> <section> <key>
_pki_cfg_scalar() {
    awk -v sec="$2" -v key="$3" '
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { next }
        $0 ~ "^"sec":" { insec=1; next }
        /^[^[:space:]#]/ { insec=0 }
        insec && $0 ~ "^[[:space:]]+"key"[[:space:]]*:" {
            v = $0
            sub(/^[^:]*:[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*$/, "", v)
            gsub(/"/, "", v)
            print v; exit
        }' "$1" 2>/dev/null
}

# _pki_static_hosts <file> -> "ip<TAB>public-host:port" (one per endpoint)
_pki_static_hosts() {
    awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { next }
        /^[^[:space:]]/ { insec = ($0 ~ /^static_host_map:[[:space:]]*$/); key=""; next }
        !insec { next }
        {
            line = $0
            if (line ~ /^[[:space:]]*"?[0-9A-Fa-f:.]+"?[[:space:]]*:/) {
                key = line
                sub(/^[[:space:]]*"/, "", key); sub(/".*/, "", key)
                sub(/[[:space:]]*:.*/, "", key)
                val = line; sub(/^[^:]*:[[:space:]]*/, "", val)
                sub(/[[:space:]]*#.*$/, "", val)
                gsub(/\[|\]/, "", val)
                n = split(val, a, ",")
                for (i=1; i<=n; i++) {
                    v = a[i]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                    gsub(/"/, "", v)
                    if (v != "") print key "\t" v
                }
                next
            }
            if (key != "" && line ~ /^[[:space:]]*-[[:space:]]*/) {
                v = line; sub(/^[[:space:]]*-[[:space:]]*/, "", v)
                sub(/[[:space:]]*#.*$/, "", v)
                gsub(/\"/, "", v)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                if (v != "") print key "\t" v
            }
        }' "$1" 2>/dev/null
}

# _pki_lh_hosts <file> -> one lighthouse overlay IP per line
_pki_lh_hosts() {
    awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { next }
        /^[^[:space:]]/ { inlh = ($0 ~ /^lighthouse:[[:space:]]*$/); inhosts=0; next }
        !inlh { next }
        /^[[:space:]]*hosts:[[:space:]]*\[/ {
            line = $0; sub(/.*\[/, "", line); sub(/\].*/, "", line)
            n = split(line, a, ",")
            for (i=1; i<=n; i++) {
                v = a[i]; gsub(/"/, "", v)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                if (v != "") print v
            }
            inhosts=0; next
        }
        /^[[:space:]]*hosts:[[:space:]]*$/ { inhosts=1; next }
        /^[[:space:]]*[A-Za-z_]+[[:space:]]*:/ { inhosts=0 }
        inhosts && /^[[:space:]]*-[[:space:]]*/ {
            v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*$/, "", v)
            gsub(/\"/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (v != "") print v
        }' "$1" 2>/dev/null
}

_pki_add_lh_ip() {
    local ip="$1" e
    [[ -n "$ip" ]] || return 0
    for e in "${PKI_NET_LH_IPS[@]}"; do [[ "$e" == "$ip" ]] && return 0; done
    PKI_NET_LH_IPS+=("$ip")
}

_pki_add_static() {
    local ip="$1" ep="$2" e
    [[ -n "$ip" && -n "$ep" ]] || return 0
    for e in "${PKI_NET_STATIC[@]}"; do [[ "$e" == "$ip $ep" ]] && return 0; done
    PKI_NET_STATIC+=("$ip $ep")
}

_pki_static_for_ip() {
    local ip="$1" e
    for e in "${PKI_NET_STATIC[@]}"; do
        [[ "${e%% *}" == "$ip" ]] && { printf '%s' "${e#* }"; return 0; }
    done
    return 1
}

# _pki_firewall_block <file> -> the verbatim top-level firewall: block
_pki_firewall_block() {
    awk '
        { sub(/\r$/, "") }
        /^firewall:[[:space:]]*$/ { infw=1; print; next }
        infw {
            if ($0 ~ /^[^[:space:]]/) exit
            print
        }' "$1" 2>/dev/null
}

# Candidate Nebula configs, most specific first. Never writes; unreadable files
# are handled by readable_nebula_config (cached sudo or a reasoned prompt).
_pki_local_config_candidates() {
    local conf n d sv en ro ho
    [[ -n "${NEBULA_LOCAL_CONFIG:-}" ]] && printf '%s\n' "${NEBULA_LOCAL_CONFIG/#\~/$HOME}"
    # Scripts/tests can disable automatic discovery (the explicit override above
    # is still honoured).
    [[ "${NEBULA_NO_LOCAL_CONFIG:-0}" == 1 ]] && return 0
    [[ -n "${NEBULA_DIR:-}" ]] && printf '%s\n' "${NEBULA_DIR%/}/config.yml"
    conf="$(resolve_server_conf)"
    if [[ -f "$conf" ]]; then
        while IFS='|' read -r n d sv en ro ho; do
            [[ -n "$d" ]] && printf '%s\n' "${d%/}/config.yml"
        done < <(SERVER_CONF="$conf" server_entries 2>/dev/null || true)
    fi
    printf '%s\n' "/etc/nebula/config.yml"
}

# [server.*] entries from the manager config (name|dir|service|enabled|role|host).
_pki_server_entries() {
    local conf; conf="$(resolve_server_conf)"
    [[ -f "$conf" ]] || return 0
    SERVER_CONF="$conf" server_entries 2>/dev/null || true
}

# _pki_cert_path_for_name <name> <cert_dir> -> certificate path
# Exact match first, then a '<name>.<domain>' prefix, then a unique substring.
_pki_cert_path_for_name() {
    local name="$1" dir="$2" cert base
    [[ -n "$name" && -d "$dir" ]] || return 0
    local -a exact=() pref=() subs=()
    for cert in "$dir"/*.crt; do
        [[ -f "$cert" ]] || continue
        base="$(basename "$cert" .crt)"
        [[ "$base" == "ca" ]] && continue
        if [[ "$base" == "$name" ]]; then exact+=("$cert")
        elif [[ "$base" == "$name".* ]]; then pref+=("$cert")
        elif [[ "${base,,}" == *"${name,,}"* ]]; then subs+=("$cert")
        fi
    done
    if (( ${#exact[@]} == 1 )); then printf '%s\n' "${exact[0]}"
    elif (( ${#pref[@]} == 1 )); then printf '%s\n' "${pref[0]}"
    elif (( ${#subs[@]} == 1 )); then printf '%s\n' "${subs[0]}"
    fi
}

# _pki_cert_ip_for_name <name> <cert_dir> -> first overlay IP (no prefix)
_pki_cert_ip_for_name() {
    local name="$1" dir="$2" cert nc json ip isca
    cert="$(_pki_cert_path_for_name "$name" "$dir")"
    [[ -n "$cert" ]] || return 0
    nc="${NEBULA_BIN_PATH:-/usr/local/bin}/nebula-cert"
    [[ -x "$nc" ]] || nc="$(command -v nebula-cert 2>/dev/null || true)"
    [[ -n "$nc" ]] || return 0
    json="$(nebula_cert_json "$(dirname "$nc")" "$cert")"
    isca="$(jq -r '.details.isCa // false' <<<"$json" 2>/dev/null)"
    [[ "$isca" == "true" ]] && return 0
    ip="$(jq -r '.details.ips[0] // empty' <<<"$json" 2>/dev/null)"
    ip="${ip%%/*}"
    [[ -n "$ip" ]] && printf '%s\n' "$ip"
}

# Add the default port unless the value already looks like host:port.
_pki_endpoint_with_port() {
    local host="$1" port="${2:-${NEBULA_DEFAULT_PORT:-4242}}"
    [[ -n "$host" ]] || return 0
    if [[ "$host" =~ ^[^:]+:[0-9]+$ || "$host" =~ ^\[[^]]+\]:[0-9]+$ ]]; then
        printf '%s' "$host"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

# pki_detect_network_config [cert_dir]
# Populates PKI_NET_* for pki_write_client_config. Prefers the local Nebula
# config (authoritative), then derives missing lighthouses/endpoints from the
# [server.*] entries + the certificate workspace. Never fails hard; records
# anything it cannot determine in PKI_NET_MISSING so the caller can flag it.
PKI_NET_READY=0
PKI_NET_CERT_DIR=""
PKI_NET_SOURCE=""
PKI_NET_TUN="nebula1"
PKI_NET_LISTEN_PORT=""
PKI_NET_INTERVAL=""
PKI_NET_AM_LH="false"
PKI_NET_PUNCH="true"
PKI_NET_RESPOND="true"
PKI_NET_DELAY="1s"
PKI_NET_LH_IPS=()
PKI_NET_STATIC=()
PKI_NET_FIREWALL=()
PKI_NET_MISSING=()

pki_detect_network_config() {
    local cert_dir="${1:-$(resolve_cert_dir)}"
    # No cross-call cache: the local config, [server.*] entries or the cert
    # workspace may change between bundles. Re-detection is cheap, and sudo
    # credentials stay cached for the unavoidable privileged config read.
    PKI_NET_CERT_DIR="$cert_dir"
    PKI_NET_SOURCE=""
    PKI_NET_TUN="nebula1"
    PKI_NET_LISTEN_PORT=""
    PKI_NET_INTERVAL=""
    PKI_NET_AM_LH="false"
    PKI_NET_PUNCH="true"
    PKI_NET_RESPOND="true"
    PKI_NET_DELAY="1s"
    PKI_NET_LH_IPS=()
    PKI_NET_STATIC=()
    PKI_NET_FIREWALL=()
    PKI_NET_MISSING=()

    # 1) Local Nebula config (read-only; may use cached sudo or ask once).
    local cand r src="" cfg=""
    while IFS= read -r cand; do
        [[ -n "$cand" && -f "$cand" ]] || continue
        r="$(readable_nebula_config "$cand")" || r=""
        if [[ -n "$r" ]]; then cfg="$r"; src="$cand"; break; fi
    done < <(_pki_local_config_candidates)
    if [[ -n "$cfg" ]]; then
        PKI_NET_SOURCE="$src"
        local v ip ep line last
        v="$(_pki_cfg_scalar "$cfg" tun dev)";              [[ -n "$v" ]] && PKI_NET_TUN="$v"
        v="$(_pki_cfg_scalar "$cfg" listen port)";          [[ -n "$v" ]] && PKI_NET_LISTEN_PORT="$v"
        v="$(_pki_cfg_scalar "$cfg" lighthouse am_lighthouse)"; [[ -n "$v" ]] && PKI_NET_AM_LH="$v"
        v="$(_pki_cfg_scalar "$cfg" lighthouse interval)";  [[ -n "$v" ]] && PKI_NET_INTERVAL="$v"
        v="$(_pki_cfg_scalar "$cfg" punchy punch)";         [[ -n "$v" ]] && PKI_NET_PUNCH="$v"
        v="$(_pki_cfg_scalar "$cfg" punchy respond)";       [[ -n "$v" ]] && PKI_NET_RESPOND="$v"
        v="$(_pki_cfg_scalar "$cfg" punchy delay)";         [[ -n "$v" ]] && PKI_NET_DELAY="$v"
        while IFS=$'\t' read -r ip ep; do _pki_add_static "$ip" "$ep"; done < <(_pki_static_hosts "$cfg")
        while IFS= read -r ip; do _pki_add_lh_ip "$ip"; done < <(_pki_lh_hosts "$cfg")
        while IFS= read -r line; do PKI_NET_FIREWALL+=("$line"); done < <(_pki_firewall_block "$cfg")
        # Drop trailing blank lines so the rendered template stays tidy.
        last=$(( ${#PKI_NET_FIREWALL[@]} - 1 ))
        while (( last >= 0 )) && [[ -z "${PKI_NET_FIREWALL[last]}" ]]; do
            unset "PKI_NET_FIREWALL[$last]"
            last=$(( last - 1 ))
        done
        [[ "$cfg" != "$src" ]] && rm -f "$cfg"
    fi

    # 2) [server.*] entries. If the local config already named the lighthouses,
    # treat them as authoritative and only use these entries to fill a missing
    # public endpoint. Otherwise derive the lighthouses from the entries.
    local n d sv en ro ho role_lc entry have_local_lh=0 known l
    (( ${#PKI_NET_LH_IPS[@]} )) && have_local_lh=1
    local -a entries=()
    while IFS= read -r entry; do [[ -n "$entry" ]] && entries+=("$entry"); done < <(_pki_server_entries)
    for entry in "${entries[@]}"; do
        IFS='|' read -r n d sv en ro ho <<<"$entry"
        [[ -n "$n" ]] || continue
        [[ "${en:-true}" == "false" ]] && continue
        role_lc="${ro,,}"
        if [[ "$role_lc" == *lighthouse* || ( -z "$ro" && -n "$ho" ) ]]; then
            local cip; cip="$(_pki_cert_ip_for_name "$n" "$cert_dir")"
            if [[ -z "$cip" ]]; then
                (( have_local_lh )) || \
                    PKI_NET_MISSING+=("overlay IP for lighthouse '$n' (no matching certificate in $cert_dir)")
                continue
            fi
            if (( have_local_lh )); then
                known=0
                for l in "${PKI_NET_LH_IPS[@]}"; do [[ "$l" == "$cip" ]] && { known=1; break; }; done
                (( known )) || continue
            else
                _pki_add_lh_ip "$cip"
            fi
            if [[ -z "$(_pki_static_for_ip "$cip")" && -n "$ho" ]]; then
                _pki_add_static "$cip" "$(_pki_endpoint_with_port "$ho")"
            fi
        fi
    done

    # 3) Every lighthouse needs a public endpoint; flag the ones without one.
    local lh
    for lh in "${PKI_NET_LH_IPS[@]}"; do
        [[ -n "$(_pki_static_for_ip "$lh")" ]] && continue
        PKI_NET_MISSING+=("static_host_map entry for lighthouse $lh (set host= in [server.*] or in the local config)")
    done
    if (( ${#PKI_NET_LH_IPS[@]} == 0 )); then
        if [[ -n "$PKI_NET_SOURCE" ]]; then
            PKI_NET_MISSING+=("lighthouse overlay IP (none listed in $PKI_NET_SOURCE)")
        else
            PKI_NET_MISSING+=("lighthouse overlay IP (no readable local config and no lighthouse [server.*] entry)")
        fi
    fi

    [[ -z "$PKI_NET_INTERVAL" ]] && PKI_NET_INTERVAL="60"
    [[ -z "$PKI_NET_LISTEN_PORT" ]] && PKI_NET_LISTEN_PORT="0"
    PKI_NET_READY=1
    debug_info "client config: source=${PKI_NET_SOURCE:-[server.*]/defaults} lighthouses=${PKI_NET_LH_IPS[*]:-none} missing=${#PKI_NET_MISSING[@]}"
}

# Is this certificate a lighthouse? Checks its groups, then [server.*] role.
pki_cert_is_lighthouse() {
    local name="$1" cert_dir="$2" cert nc json groups n d sv en ro ho
    cert="$(_pki_cert_path_for_name "$name" "$cert_dir")"
    if [[ -n "$cert" ]]; then
        nc="${NEBULA_BIN_PATH:-/usr/local/bin}/nebula-cert"
        [[ -x "$nc" ]] || nc="$(command -v nebula-cert 2>/dev/null || true)"
        if [[ -n "$nc" ]]; then
            json="$(nebula_cert_json "$(dirname "$nc")" "$cert")"
            groups="$(jq -r '.details.groups | join(",")' <<<"$json" 2>/dev/null)"
            [[ ",${groups,,}," == *",lighthouse,"* ]] && return 0
        fi
    fi
    while IFS='|' read -r n d sv en ro ho; do
        [[ -n "$n" ]] || continue
        if [[ "$n" == "$name" || "$name" == "$n".* ]] && [[ "${ro,,}" == *lighthouse* ]]; then
            return 0
        fi
    done < <(_pki_server_entries)
    return 1
}

# Write a ready-to-use Nebula config for a client bundle. Network settings are
# detected (local config -> [server.*] + certs) instead of leaving placeholders;
# anything undetermined is flagged in the comments and on stderr. An optional
# policy-pack path (4th arg) replaces the firewall section.
pki_write_client_config() {
    local outfile="$1" name="$2" cert_dir="${3:-$(resolve_cert_dir)}" policy_path="${4:-}"
    pki_detect_network_config "$cert_dir"
    if [[ -n "$policy_path" ]]; then
        [[ -f "$policy_path" ]] || { log_error "Policy pack not found: $policy_path"; return 1; }
        command -v yq >/dev/null 2>&1 || { log_error "yq is required to embed a firewall policy pack."; return 1; }
        debug_explain "Using firewall policy pack '$(basename "$policy_path" .yml)' instead of the detected firewall."
    fi

    local is_lh=0 am_lh="false"
    pki_cert_is_lighthouse "$name" "$cert_dir" && { is_lh=1; am_lh="true"; }
    local interval="${PKI_NET_INTERVAL:-60}"
    local port="${PKI_NET_LISTEN_PORT:-0}"
    if (( is_lh )) && [[ "$port" == "0" || -z "$port" ]]; then
        port="${NEBULA_DEFAULT_PORT:-4242}"
    fi
    local tun="${PKI_NET_TUN:-nebula1}"

    if [[ -n "$PKI_NET_SOURCE" ]]; then
        log_info "Client config: network settings from $PKI_NET_SOURCE"
    fi
    if (( ${#PKI_NET_MISSING[@]} )); then
        log_warn "Generated client config is incomplete - could not determine:"
        local m
        for m in "${PKI_NET_MISSING[@]}"; do log_warn "  - $m"; done
        log_warn "Review config.yml.template in the bundle before installing it."
    fi

    {
        printf '# Nebula client configuration for %s\n' "'$name'"
        printf '# Generated by nebula-manager'
        [[ -n "$PKI_NET_SOURCE" ]] && printf ' (network settings from %s)' "$PKI_NET_SOURCE"
        printf '.\n'
        if [[ -n "$policy_path" ]]; then
            printf '# Firewall policy pack: %s\n' "$(basename "$policy_path" .yml)"
        fi
        if (( ${#PKI_NET_MISSING[@]} )); then
            printf '#\n# WARNING: incomplete - review the commented sections below:\n'
            local m
            for m in "${PKI_NET_MISSING[@]}"; do printf '#   - %s\n' "$m"; done
        fi
        printf '\npki:\n  ca: /etc/nebula/ca.crt\n  cert: /etc/nebula/%s.crt\n  key: /etc/nebula/%s.key\n\n' "$name" "$name"

        if (( ${#PKI_NET_STATIC[@]} )); then
            printf 'static_host_map:\n'
            local entry ip ep
            for entry in "${PKI_NET_STATIC[@]}"; do
                ip="${entry%% *}"; ep="${entry#* }"
                printf '  "%s": ["%s"]\n' "$ip" "$ep"
            done
        else
            printf '# WARNING: could not determine a lighthouse endpoint.\n'
            printf '# static_host_map:\n#   "10.42.0.1": ["203.0.113.10:4242"]\n'
        fi

        if (( ${#PKI_NET_LH_IPS[@]} )); then
            printf '\nlighthouse:\n  am_lighthouse: %s\n  interval: %s\n  hosts:\n' "$am_lh" "$interval"
            local lh
            for lh in "${PKI_NET_LH_IPS[@]}"; do printf '    - "%s"\n' "$lh"; done
        else
            printf '\n# WARNING: could not determine the lighthouse overlay IP.\n'
            printf '# lighthouse:\n#   am_lighthouse: false\n#   interval: 60\n#   hosts:\n#     - "10.42.0.1"\n'
        fi

        printf '\nlisten:\n  host: 0.0.0.0\n  port: %s\n' "$port"
        printf '\npunchy:\n  punch: %s\n  respond: %s\n  delay: %s\n' \
            "${PKI_NET_PUNCH:-true}" "${PKI_NET_RESPOND:-true}" "${PKI_NET_DELAY:-1s}"

        if [[ -n "$policy_path" ]]; then
            local fw
            fw="$(yq '.firewall // {}' "$policy_path" 2>/dev/null)"
            if [[ -z "$fw" || "$fw" == "{}" ]]; then
                printf '\nfirewall: {}\n'
            else
                printf '\nfirewall:\n'
                printf '%s\n' "$fw" | sed 's/^/  /'
            fi
        elif (( ${#PKI_NET_FIREWALL[@]} )); then
            local fl
            printf '\n'
            for fl in "${PKI_NET_FIREWALL[@]}"; do printf '%s\n' "$fl"; done
        else
            printf '\n# Nebula denies all traffic by default when firewall: is omitted.\n'
            printf '# This bundle is permissive so it works out of the box - tighten it.\n'
            printf 'firewall:\n  outbound:\n    - port: any\n      proto: any\n      host: any\n'
            printf '  inbound:\n    - port: any\n      proto: any\n      host: any\n'
        fi

        printf '\ntun:\n  dev: %s\n' "$tun"
    } > "$outfile"
}

# Default place to write exported client bundles. In order of preference:
#   $NEBULA_BUNDLE_DIR -> the directory nebula-manager was started in ->
#   ~/Downloads -> ~/tmp -> $HOME -> $TMPDIR
# Only user-writable locations are chosen; nothing is created here.
pki_default_bundle_dir() {
    local d
    if [[ -n "${NEBULA_BUNDLE_DIR:-}" ]]; then
        d="${NEBULA_BUNDLE_DIR/#\~/$HOME}"
        debug_info "bundle-dir: NEBULA_BUNDLE_DIR -> $d"
        printf '%s\n' "$d"; return 0
    fi
    if [[ -n "${PWD:-}" && -d "$PWD" && -w "$PWD" ]]; then
        debug_info "bundle-dir: current directory -> $PWD"
        printf '%s\n' "$PWD"; return 0
    fi
    for d in "${HOME:-}/Downloads" "${HOME:-}/tmp" "${HOME:-}"; do
        if [[ -n "$d" && -d "$d" && -w "$d" ]]; then
            debug_info "bundle-dir: user directory -> $d"
            printf '%s\n' "$d"; return 0
        fi
    done
    d="${TMPDIR:-/tmp}"
    debug_info "bundle-dir: temporary fallback -> $d"
    printf '%s\n' "$d"
}

# pki_bundle_candidates [cert_dir]
# Prints "<name>\t<ips>\t<groups>" for every certificate that can actually be
# exported: a matching <name>.crt and <name>.key, not a CA and not revoked.
# Mobile certificates signed with --in-pub have no local key and are skipped.
pki_bundle_candidates() {
    local dir="${1:-$(resolve_cert_dir)}"
    local nc cert base key json isca ips groups
    [[ -d "$dir" ]] || return 0
    nc="${NEBULA_BIN_PATH:-/usr/local/bin}/nebula-cert"
    [[ -x "$nc" ]] || nc="$(command -v nebula-cert 2>/dev/null || true)"

    for cert in "$dir"/*.crt; do
        [[ -f "$cert" ]] || continue
        base="$(basename "$cert" .crt)"
        [[ "$base" == "ca" ]] && continue
        key="$dir/$base.key"
        [[ -f "$key" ]] || continue
        ips="" groups=""
        if [[ -n "$nc" && -x "$nc" ]]; then
            json="$(nebula_cert_json "$(dirname "$nc")" "$cert")"
            isca="$(jq -r '.details.isCa // false' <<<"$json" 2>/dev/null)"
            [[ "$isca" == "true" ]] && continue
            ips="$(jq -r '.details.ips // [] | join(",")' <<<"$json" 2>/dev/null)"
            groups="$(jq -r '.details.groups // [] | join(",")' <<<"$json" 2>/dev/null)"
        fi
        printf '%s\t%s\t%s\n' "$base" "$ips" "$groups"
    done | sort
}

# Human-readable list of exportable certificates (stdout).
pki_bundle_list() {
    local dir="${1:-$(resolve_cert_dir)}"
    local name ips groups found=0
    while IFS=$'\t' read -r name ips groups; do
        [[ -n "$name" ]] || continue
        found=1
        printf '  - %s' "$name"
        [[ -n "$ips" ]] && printf '  (%s)' "$ips"
        [[ -n "$groups" ]] && printf '  [%s]' "$groups"
        printf '\n'
    done < <(pki_bundle_candidates "$dir")
    (( found )) || printf '  (none - a bundle needs both <name>.crt and <name>.key)\n'
}

# pki_resolve_bundle_name <query> [cert_dir]
# Finds an exportable certificate by exact name, case-insensitive name, or a
# unique substring (also accepts a pasted path like .../host1.crt).
# On success sets PKI_BUNDLE_RESOLVED. On ambiguity sets PKI_BUNDLE_MATCHES and
# returns 2; returns 1 when nothing matches.
PKI_BUNDLE_RESOLVED=""
PKI_BUNDLE_MATCHES=()
pki_resolve_bundle_name() {
    local query="${1:-}" dir="${2:-$(resolve_cert_dir)}"
    PKI_BUNDLE_RESOLVED=""; PKI_BUNDLE_MATCHES=()
    [[ -n "$query" ]] || return 1
    query="${query##*/}"
    query="${query%.crt}"; query="${query%.key}"

    local name _ips _groups
    local -a all=() exact=() folded=() hits=()
    while IFS=$'\t' read -r name _ips _groups; do
        [[ -n "$name" ]] && all+=("$name")
    done < <(pki_bundle_candidates "$dir")
    (( ${#all[@]} )) || return 1

    for name in "${all[@]}"; do
        [[ "$name" == "$query" ]] && exact+=("$name")
    done
    if (( ${#exact[@]} == 1 )); then
        PKI_BUNDLE_RESOLVED="${exact[0]}"; return 0
    fi

    local qfold="${query,,}"
    for name in "${all[@]}"; do
        [[ "${name,,}" == "$qfold" ]] && folded+=("$name")
    done
    if (( ${#folded[@]} == 1 )); then
        PKI_BUNDLE_RESOLVED="${folded[0]}"; return 0
    fi

    for name in "${all[@]}"; do
        [[ "${name,,}" == *"$qfold"* ]] && hits+=("$name")
    done
    if (( ${#hits[@]} == 1 )); then
        PKI_BUNDLE_RESOLVED="${hits[0]}"; return 0
    fi
    if (( ${#hits[@]} > 1 )); then
        PKI_BUNDLE_MATCHES=("${hits[@]}"); return 2
    fi
    return 1
}

# pki_bundle_client_zip <name> [out_dir] [cert_dir] [policy_path]
pki_bundle_client_zip() {
    local name="${1:?client name required}"
    local out_dir="${2:-$(pki_default_bundle_dir)}"
    local cert_dir="${3:-$(resolve_cert_dir)}"
    local policy_path="${4:-}"
    CERT_STORE_AUDIT_DIR="$cert_dir"; export CERT_STORE_AUDIT_DIR
    local crt="$cert_dir/$name.crt" key="$cert_dir/$name.key"
    local ca; ca="$(find_ca_crt "$cert_dir" || true)"

    out_dir="${out_dir/#\~/$HOME}"
    [[ -f "$crt" ]] || { log_error "Certificate not found: $crt"; return 1; }
    [[ -f "$key" ]] || { log_error "Key not found: $key"; return 1; }
    [[ -n "$ca" && -f "$ca" ]] || { log_error "CA certificate not found for $name"; return 1; }
    if [[ -n "$policy_path" ]]; then
        [[ -f "$policy_path" ]] || { log_error "Policy pack not found: $policy_path"; return 1; }
        if declare -F policy_validate >/dev/null; then
            policy_validate "$policy_path" || return 1
        fi
        log_info "Using firewall policy pack: $(basename "$policy_path" .yml)"
    fi
    debug_explain "Bundling the client certificate, private key, ca.crt and a config template; the archive is mode 0600 because it contains the key."
    [[ -n "$policy_path" ]] && debug_explain "Embedding firewall policy pack '$(basename "$policy_path" .yml)' in the config template."

    ensure_dir "$out_dir" || return 1
    if [[ "$out_dir" == "$cert_dir" ]]; then
        log_warn "Writing the bundle into the certificate store itself - consider another directory."
    fi
    local tmp; tmp="$(mktemp -d)"
    cp "$crt" "$tmp/$name.crt"
    cp "$key" "$tmp/$name.key"
    cp "$ca"  "$tmp/ca.crt"
    pki_write_client_config "$tmp/config.yml.template" "$name" "$cert_dir" "$policy_path"

    local zipfile="$out_dir/${name}-nebula-bundle.zip"
    rm -f "$zipfile"
    if command -v zip >/dev/null 2>&1; then
        ( cd "$tmp" && zip -q "$zipfile" "$name.crt" "$name.key" ca.crt config.yml.template ) \
            || { log_error "Failed to create zip bundle."; rm -rf "$tmp"; return 1; }
        chmod 600 "$zipfile" 2>/dev/null || true
    else
        local tarball="$out_dir/${name}-nebula-bundle.tar.gz"
        ( cd "$tmp" && tar -czf "$tarball" "$name.crt" "$name.key" ca.crt config.yml.template ) \
            || { log_error "Failed to create tar bundle."; rm -rf "$tmp"; return 1; }
        chmod 600 "$tarball" 2>/dev/null || true
        rm -rf "$tmp"
        if declare -F cert_store_log >/dev/null; then
            cert_store_log "$cert_dir" "bundle name=\"$name\" out=\"$tarball\" policy=\"${policy_path:+$(basename "$policy_path" .yml)}\""
        fi
        log_warn "zip not found; wrote $tarball instead."
        printf '%s\n' "$tarball"
        return 0
    fi
    rm -rf "$tmp"
    if declare -F cert_store_log >/dev/null; then
        cert_store_log "$cert_dir" "bundle name=\"$name\" out=\"$zipfile\" policy=\"${policy_path:+$(basename "$policy_path" .yml)}\""
    fi
    log_success "Client bundle created: $zipfile"
    log_info "Contains: ${name}.crt, ${name}.key, ca.crt, config.yml.template (keep it safe - it holds the private key)."
    printf '%s\n' "$zipfile"
}

###################################################################
######################## Group migration ##########################
###################################################################

# _pki_groups_have <comma-list> <group> ; exact membership test (no globbing).
_pki_groups_have() {
    local list="$1" want="$2" IFS=',' g
    for g in $list; do
        [[ "$g" == "$want" ]] && return 0
    done
    return 1
}

# _pki_groups_normalize <comma-list> ; trim, drop empties and duplicates.
_pki_groups_normalize() {
    local csv="$1"
    local IFS=',' p acc=""
    for p in $csv; do
        # trim surrounding whitespace
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [[ -z "$p" ]] && continue
        case ",$acc," in *",$p,"*) continue ;; esac
        acc="${acc:+$acc,}$p"
    done
    printf '%s' "$acc"
}

# _pki_groups_replace <comma-list> <old> <new>
# Replace <old> with <new> in place, drop duplicates, preserve the group order.
_pki_groups_replace() {
    local csv="$1" old="$2" new="$3"
    local IFS=',' p acc=""
    for p in $csv; do
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [[ -z "$p" ]] && continue
        [[ "$p" == "$old" ]] && p="$new"
        [[ -z "$p" ]] && continue
        case ",$acc," in *",$p,"*) continue ;; esac
        acc="${acc:+$acc,}$p"
    done
    printf '%s' "$acc"
}

# _pki_groups_add <comma-list> <group> ; union (idempotent, order preserved).
_pki_groups_add() {
    local csv="$1" new="$2" norm
    [[ -z "$new" ]] && { printf '%s' "$csv"; return 0; }
    norm="$(_pki_groups_normalize "$csv")"
    _pki_groups_have "$norm" "$new" && { printf '%s' "$norm"; return 0; }
    if [[ -z "$norm" ]]; then printf '%s' "$new"; else printf '%s,%s' "$norm" "$new"; fi
}

# _pki_groups_remove <comma-list> <group> ; subtract (idempotent).
_pki_groups_remove() {
    local csv="$1" drop="$2"
    local IFS=',' p acc=""
    for p in $csv; do
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [[ -z "$p" ]] && continue
        [[ "$p" == "$drop" ]] && continue
        case ",$acc," in *",$p,"*) continue ;; esac
        acc="${acc:+$acc,}$p"
    done
    printf '%s' "$acc"
}

# _pki_groups_move <comma-list> <from> <to>
# Replace <from> in place (order preserved, deduplicated); if the certificate
# does not carry <from>, simply add <to> (the selection is explicit).
_pki_groups_move() {
    local csv="$1" from="$2" to="$3"
    if _pki_groups_have "$csv" "$from"; then
        _pki_groups_replace "$csv" "$from" "$to"
    else
        _pki_groups_add "$csv" "$to"
    fi
}

# _pki_group_name_valid <name> ; no commas or whitespace, non-empty.
_pki_group_name_valid() {
    local g="$1"
    [[ -n "$g" && "$g" != *,* && ! "$g" =~ [[:space:]] ]]
}

_pki_groups_validate_list() {
    local csv="$1"
    local IFS=',' g
    for g in $csv; do
        g="${g#"${g%%[![:space:]]*}"}"
        g="${g%"${g##*[![:space:]]}"}"
        [[ -z "$g" ]] && return 1
        _pki_group_name_valid "$g" || return 1
    done
    return 0
}

# pki_group_plan <add|remove|move|set|rename> [args]
# Turn the current SEL_* selection (from cert_select) into a re-sign plan:
# fills PKI_RENAME_* with one entry per certificate whose groups change.
# Returns 0 when something changes, 1 when the selection is already in the
# desired state, 2 on invalid arguments.
pki_group_plan() {
    local action="${1:-}"; shift || true
    PKI_RENAME_FILES=()
    PKI_RENAME_NAMES=()
    PKI_RENAME_IPS=()
    PKI_RENAME_OLDGROUPS=()
    PKI_RENAME_NEWGROUPS=()
    local a="${1:-}" b="${2:-}" setlist=""
    case "$action" in
        add|remove)
            _pki_group_name_valid "$a" || { log_error "Invalid group name: '$a'"; return 2; }
            ;;
        move|rename)
            _pki_group_name_valid "$a" || { log_error "Invalid old group name: '$a'"; return 2; }
            _pki_group_name_valid "$b" || { log_error "Invalid new group name: '$b'"; return 2; }
            ;;
        set)
            if [[ -n "$a" && "$a" != "-" ]]; then
                _pki_groups_validate_list "$a" || { log_error "Invalid group list: '$a'"; return 2; }
                setlist="$(_pki_groups_normalize "$a")"
            fi
            ;;
        *) log_error "Unknown group action: '$action'"; return 2 ;;
    esac
    PKI_GROUP_ACTION="$action"

    if (( ${#SEL_FILES[@]} == 0 )); then
        log_warn "No certificates selected."
        return 1
    fi

    local i old new
    for i in "${!SEL_FILES[@]}"; do
        old="${SEL_GROUPS[i]}"
        case "$action" in
            add)    new="$(_pki_groups_add    "$old" "$a")" ;;
            remove) new="$(_pki_groups_remove "$old" "$a")" ;;
            move)   new="$(_pki_groups_move   "$old" "$a" "$b")" ;;
            set)    new="$setlist" ;;
            rename) new="$(_pki_groups_replace "$old" "$a" "$b")" ;;
        esac
        [[ "$new" == "$old" ]] && continue
        PKI_RENAME_FILES+=("${SEL_FILES[i]}")
        PKI_RENAME_NAMES+=("${SEL_NAMES[i]}")
        PKI_RENAME_IPS+=("${SEL_IPS[i]}")
        PKI_RENAME_OLDGROUPS+=("$old")
        PKI_RENAME_NEWGROUPS+=("$new")
    done
    (( ${#PKI_RENAME_FILES[@]} > 0 ))
}

# pki_group_scan <old> <new> [cert_dir]
# Backwards-compatible rename scan: select every certificate carrying <old>
# and plan replacing it with <new>.
pki_group_scan() {
    local old="${1:-}" new="${2:-}" cert_dir="${3:-$(resolve_cert_dir)}"
    if [[ -z "$old" || -z "$new" ]]; then
        log_error "Both the old and the new group name are required."
        return 2
    fi
    cert_select "$cert_dir" --select "group:$old"
    local rc=$?
    (( rc == 0 )) || return $rc
    pki_group_plan rename "$old" "$new"
}

# pki_group_diff_text <summary> ; aligned per-certificate preview.
pki_group_diff_text() {
    local summary="$1"
    local i base width=0 out line
    for i in "${!PKI_RENAME_FILES[@]}"; do
        base="$(basename "${PKI_RENAME_FILES[i]}")"
        (( ${#base} > width )) && width=${#base}
    done
    # printf -v keeps the newlines (a $(...) capture would strip them).
    printf -v out '%s\n' "$summary"
    out+=$'Originals are backed up as *.crt.bak; private keys are not touched.\n\n'
    for i in "${!PKI_RENAME_FILES[@]}"; do
        base="$(basename "${PKI_RENAME_FILES[i]}")"
        printf -v line '%-*s (%s): [%s] -> [%s]\n' "$width" "$base" "${PKI_RENAME_IPS[i]}" \
            "${PKI_RENAME_OLDGROUPS[i]}" "${PKI_RENAME_NEWGROUPS[i]}"
        out+="$line"
    done
    printf '%s' "$out"
}

# pki_group_preview_text <old> <new> ; rename preview (kept for callers/tests).
pki_group_preview_text() {
    local old="$1" new="$2"
    pki_group_diff_text "Group \"$old\" will be replaced by \"$new\" in ${#PKI_RENAME_FILES[@]} certificate(s)."
}

# pki_group_apply [cert_dir]
# Re-sign every certificate selected by pki_group_scan, preserving name, IPs,
# subnets and expiry. Unprivileged: the CA key living in cert_dir is used.
# Each original certificate is backed up to <name>.crt.bak (only once).
pki_group_apply() {
    local cert_dir="${1:-$(resolve_cert_dir)}"
    CERT_STORE_AUDIT_DIR="$cert_dir"; export CERT_STORE_AUDIT_DIR
    if (( ${#PKI_RENAME_FILES[@]} == 0 )); then
        log_warn "Nothing to re-sign - run pki_group_scan first."
        return 1
    fi
    local bin bin_path ca_crt ca_key
    bin="$(pki_cert_bin)" || return 1
    bin_path="$(dirname "$bin")"
    ca_crt="$(find_ca_crt "$cert_dir")" || { log_error "CA certificate not found in $cert_dir"; return 1; }
    ca_key="$(find_ca_key "$cert_dir")" || { log_error "CA key not found in $cert_dir"; return 1; }

    debug_explain "Re-signing ${#PKI_RENAME_FILES[@]} certificate(s) for group action '${PKI_GROUP_ACTION:-resign}'."
    debug_explain "Groups are embedded in the certificate, so it must be re-issued. Name, networks, subnets and expiry are preserved; device private keys are not touched."
    debug_explain "A throwaway public key is used for each re-sign, so the existing device key keeps working."

    # Snapshot the old certificates/keys once, before re-signing any of them.
    if declare -F cert_store_snapshot_before >/dev/null; then
        local -a snapfiles=()
        local k
        for i in "${!PKI_RENAME_FILES[@]}"; do
            snapfiles+=("${PKI_RENAME_FILES[i]}")
            k="${PKI_RENAME_FILES[i]%.crt}.key"
            [[ -f "$k" ]] && snapfiles+=("$k")
        done
        cert_store_snapshot_before "$cert_dir" "group-${PKI_GROUP_ACTION:-resign}" "${snapfiles[@]}" || true
    fi

    local tmp; tmp="$(mktemp -d)" || return 1
    # A user-owned workspace needs no privileges at all. Only if the store (or
    # its CA key) lives in a root-owned location do we route the write steps
    # through elevate(), which announces the reason and command.
    local -a asroot=()
    local prev_reason="${ELEVATE_REASON:-}"
    if declare -F path_requires_root >/dev/null && path_requires_root "$cert_dir"; then
        asroot=(elevate)
        ELEVATE_REASON="re-sign certificates and write backups in $cert_dir"
    fi
    local i crt json name ips subnets newgroups na epoch_na secs bak out_tmp
    local ok=0 failed=0
    for i in "${!PKI_RENAME_FILES[@]}"; do
        crt="${PKI_RENAME_FILES[i]}"
        newgroups="${PKI_RENAME_NEWGROUPS[i]}"
        json="$(nebula_cert_json "$bin_path" "$crt")" || {
            log_error "Cannot inspect $(basename "$crt")"; failed=$((failed+1)); continue; }
        name="$(jq -r '.details.name // empty' <<<"$json" 2>/dev/null)"
        ips="$(jq -r '(.details.ips // []) | join(",")' <<<"$json" 2>/dev/null)"
        subnets="$(jq -r '(.details.subnets // []) | join(",")' <<<"$json" 2>/dev/null)"
        na="$(jq -r '.details.notAfter // empty' <<<"$json" 2>/dev/null)"
        if [[ -z "$name" || -z "$ips" ]]; then
            log_error "Skipping $(basename "$crt"): certificate has no name or network."
            failed=$((failed+1)); continue
        fi

        local -a args=("$bin" sign -name "$name" -networks "$ips"
            -groups "$newgroups" -ca-crt "$ca_crt" -ca-key "$ca_key")
        [[ -n "$subnets" ]] && args+=(-unsafe-networks "$subnets")
        # Preserve the original expiry: re-signing must not silently extend it.
        if [[ -n "$na" ]]; then
            epoch_na="$(date -d "$na" +%s 2>/dev/null || echo 0)"
            secs=$(( epoch_na - $(date +%s) ))
            if (( secs <= 0 )); then
                log_error "Skipping $(basename "$crt"): certificate already expired."
                failed=$((failed+1)); continue
            fi
            args+=(-duration "${secs}s")
        fi
        # A throwaway public key lets us re-issue the certificate without
        # touching the private key that is already on the device.
        if ! debug_run_quiet "$bin" keygen -out-key "$tmp/sign.key" -out-pub "$tmp/sign.pub"; then
            log_error "Could not generate a temporary key pair for $(basename "$crt")."
            failed=$((failed+1)); continue
        fi
        out_tmp="$tmp/$name.crt"
        rm -f "$out_tmp"
        if ! debug_run "${asroot[@]}" "${args[@]}" -in-pub "$tmp/sign.pub" -out-crt "$out_tmp" \
            || [[ ! -s "$out_tmp" ]]; then
            log_error "Failed to re-sign $(basename "$crt")."
            failed=$((failed+1)); continue
        fi

        bak="$crt.bak"
        if [[ ! -f "$bak" ]]; then
            debug_run "${asroot[@]}" cp -p "$crt" "$bak" || {
                log_error "Could not back up $crt"; failed=$((failed+1)); continue; }
        fi
        if debug_run "${asroot[@]}" cp "$out_tmp" "$crt"; then
            ok=$((ok+1))
            log_success "Re-signed $(basename "$crt"): [${PKI_RENAME_OLDGROUPS[i]}] -> [$newgroups]"
        else
            log_error "Could not replace $crt"
            failed=$((failed+1))
        fi
    done
    ELEVATE_REASON="$prev_reason"
    rm -rf "$tmp"
    if declare -F cert_store_log >/dev/null; then
        cert_store_log "$cert_dir" "group-${PKI_GROUP_ACTION:-resign} changed=$ok failed=$failed snapshot=\"${CERT_STORE_LAST_SNAPSHOT:-none}\""
    fi
    log_info "Re-signed ${ok} certificate(s); ${failed} failed."
    (( failed == 0 ))
}

# Interactive TUI entry: Certificates > Rename Group in Certificates.
pki_rename_group_tui() {
    local cert_dir; cert_dir="$(resolve_cert_dir)"
    ensure_cert_dir >/dev/null || return 1
    local old new
    old="$(ui_input "Rename group" "Group to rename (e.g. laptops):")" || { log_info "Canceled."; return 0; }
    [[ -z "$old" ]] && { log_info "Canceled."; return 0; }
    new="$(ui_input "Rename group" "New group name (e.g. theprof):")" || { log_info "Canceled."; return 0; }
    [[ -z "$new" ]] && { log_info "Canceled."; return 0; }
    if [[ "$old" == "$new" ]]; then
        log_warn "Old and new group names are identical - nothing to do."
        return 0
    fi
    if ! pki_group_scan "$old" "$new" "$cert_dir"; then
        log_warn "No certificate in $cert_dir carries group '$old'."
        return 1
    fi
    local preview
    preview="$(pki_group_preview_text "$old" "$new")"
    ui_textbox "Rename group: $old -> $new" "$preview"
    if ! ui_yesno "Rename group" \
        "Proceed with re-signing ${#PKI_RENAME_FILES[@]} certificate(s)? The CA key in ${cert_dir} will be used."; then
        log_info "Canceled - no certificates were changed."
        return 0
    fi
    pki_group_apply "$cert_dir"
}

# Interactive TUI entry: Certificates > Edit Groups (Batch).
pki_group_edit_tui() {
    local cert_dir; cert_dir="$(resolve_cert_dir)"
    ensure_cert_dir >/dev/null || return 1
    if ! cert_select_tui "$cert_dir"; then
        return 0
    fi
    local count="${#SEL_FILES[@]}" action a b summary preview rc n
    while true; do
        action="$(ui_menu "Edit groups" "Action for ${count} selected certificate(s):" \
            add    "Add a group" \
            remove "Remove a group" \
            move   "Move a group (add B, remove A)" \
            set    "Replace the whole group list" \
            rename "Rename a group (replace A with B)" \
            list   "Show the current groups")" || return 0
        a=""; b=""; summary=""
        case "$action" in
            list)
                local i
                for i in "${!SEL_FILES[@]}"; do
                    printf '  %-36s [%s]\n' "$(basename "${SEL_FILES[i]}")" "${SEL_GROUPS[i]:-}"
                done
                continue
                ;;
            add)
                a="$(ui_input "Add group" "Group to add:")" || return 0 ;;
            remove)
                a="$(ui_input "Remove group" "Group to remove:")" || return 0 ;;
            move)
                a="$(ui_input "Move group" "Group to remove:")" || return 0
                [[ -z "$a" ]] && { log_info "Canceled."; return 0; }
                b="$(ui_input "Move group" "Group to add (replaces '$a'):")" || return 0 ;;
            rename)
                a="$(ui_input "Rename group" "Old group:")" || return 0
                [[ -z "$a" ]] && { log_info "Canceled."; return 0; }
                b="$(ui_input "Rename group" "New group name:")" || return 0 ;;
            set)
                a="$(ui_input "Set groups" "New group list (comma-separated, empty clears):")" || return 0 ;;
        esac
        if [[ "$action" != set && -z "$a" ]]; then log_info "Canceled."; return 0; fi
        if [[ "$action" == move || "$action" == rename ]] && [[ -z "$b" ]]; then
            log_info "Canceled."; return 0
        fi

        rc=0
        case "$action" in
            move|rename) pki_group_plan "$action" "$a" "$b" || rc=$? ;;
            *)           pki_group_plan "$action" "$a" || rc=$? ;;
        esac
        (( rc == 2 )) && continue
        if (( ${#PKI_RENAME_FILES[@]} == 0 )); then
            log_info "No changes needed for the selected certificate(s)."
        else
            case "$action" in
                add)    summary="Add group \"$a\" to ${#PKI_RENAME_FILES[@]} certificate(s)." ;;
                remove) summary="Remove group \"$a\" from ${#PKI_RENAME_FILES[@]} certificate(s)." ;;
                move)   summary="Move group \"$a\" -> \"$b\" on ${#PKI_RENAME_FILES[@]} certificate(s)." ;;
                set)    summary="Set groups to [${a:-none}] on ${#PKI_RENAME_FILES[@]} certificate(s)." ;;
                rename) summary="Group \"$a\" will be replaced by \"$b\" in ${#PKI_RENAME_FILES[@]} certificate(s)." ;;
            esac
            preview="$(pki_group_diff_text "$summary")"
            ui_textbox "Edit groups" "$preview"
            if ui_yesno "Edit groups" \
                "Proceed with re-signing ${#PKI_RENAME_FILES[@]} certificate(s)? The CA key in ${cert_dir} will be used."; then
                if pki_group_apply "$cert_dir"; then
                    # The groups on disk changed: refresh the selection so a
                    # follow-up action previews against the new state.
                    local -a refresh=()
                    for n in "${SEL_NAMES[@]}"; do refresh+=(--select "cert:$n"); done
                    cert_select "$cert_dir" "${refresh[@]}" || true
                fi
            else
                log_info "Canceled - no certificates were changed."
            fi
        fi
        ui_yesno "Edit groups" "Apply another action to the same selection?" || break
    done
}

# Headless CLI: nebula-manager group <command> ...
group_usage() {
    cat <<'EOF'
Usage: nebula-manager group <command> [options]

Commands:
  list                                    Show certificate names, IPs and groups
  add    <group>     --select SPEC [...]  Add a group (union, idempotent)
  remove <group>     --select SPEC [...]  Remove a group (idempotent)
  move   <old> <new> --select SPEC [...]  Add <new> and remove <old> in one re-sign
  set    <g1,g2>     --select SPEC [...]  Replace the whole group list ('' clears)
  prune  <group>     --when SPEC [...]    Remove <group> only from matches
  rename <old> <new> [--select SPEC]      Rename a group (default: group:<old>)

Selector specs (repeatable --select = union, --exclude = subtract):
  all | group:G | without:G | name:GLOB | ip:CIDR|ADDR | cert:NAME | NAME
  Shortcut: --when-group G  ==  --when group:G

Options:
  --cert-dir DIR   Certificate workspace (default: resolved workspace)
  --dry-run, -n    Show the preview; change nothing
  --yes, -y        Do not ask (required when stdin is not a TTY)
  -h, --help       This help

Examples:
  nebula-manager group add home --select group:laptops
  nebula-manager group move laptops home --select group:laptops
  nebula-manager group prune laptops --when group:home
  nebula-manager group set "home,admin" --select name:theprof-*
  nebula-manager group rename laptops home --yes
EOF
}

group_cli() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
        group_usage
        return 0
    fi
    local sub="${1:-list}"; shift || true
    local cert_dir="" dry=0 assume_yes=0 when="" when_group=""
    local -a selects=() excludes=() pos=()
    while (( $# )); do
        case "$1" in
            --cert-dir)       shift; cert_dir="${1:-}" ;;
            --cert-dir=*)     cert_dir="${1#*=}" ;;
            --select)         shift; selects+=("${1:-}") ;;
            --select=*)       selects+=("${1#*=}") ;;
            --exclude)        shift; excludes+=("${1:-}") ;;
            --exclude=*)      excludes+=("${1#*=}") ;;
            --when)           shift; when="${1:-}" ;;
            --when=*)         when="${1#*=}" ;;
            --when-group)     shift; when_group="${1:-}" ;;
            --when-group=*)   when_group="${1#*=}" ;;
            --dry-run|-n)     dry=1 ;;
            --yes|-y)         assume_yes=1 ;;
            -h|--help)        group_usage; return 0 ;;
            -*) log_error "Unknown option for 'group $sub': $1"; return 2 ;;
            *) pos+=("$1") ;;
        esac
        shift
    done
    cert_dir="${cert_dir:-$(resolve_cert_dir)}"

    case "$sub" in
        list) cert_group_list "$cert_dir"; return ;;
        add|remove|move|set|prune|rename) ;;
        *) log_error "Unknown 'group' subcommand: $sub"; group_usage >&2; return 2 ;;
    esac

    local a="${pos[0]:-}" b="${pos[1]:-}"
    local have_a=0
    (( ${#pos[@]} >= 1 )) && have_a=1
    case "$sub" in
        add|remove|prune)
            [[ -n "$a" ]] || { log_error "group $sub: missing group argument"; group_usage >&2; return 2; }
            ;;
        set)
            (( have_a )) || { log_error "group set: missing group list (pass '' to clear all groups)"; group_usage >&2; return 2; }
            ;;
        move|rename)
            [[ -n "$a" && -n "$b" ]] || { log_error "group $sub: expected <old> <new>"; group_usage >&2; return 2; }
            ;;
    esac

    if [[ "$sub" == prune ]]; then
        if [[ -n "$when" && -n "$when_group" ]]; then
            log_error "Use either --when or --when-group, not both."; return 2
        fi
        if (( ${#selects[@]} > 0 )); then
            log_error "group prune takes its selection from --when; do not also pass --select."; return 2
        fi
        [[ -n "$when_group" ]] && when="group:$when_group"
        [[ -n "$when" ]] || { log_error "group prune requires --when <spec> (e.g. --when group:home)."; return 2; }
        if [[ "$when" != *:* && "$when" != all ]]; then when="group:$when"; fi
        selects=("$when")
    fi

    if [[ "$sub" == rename ]] && (( ${#selects[@]} == 0 )); then
        selects=("group:$a")
    fi
    if (( ${#selects[@]} == 0 )); then
        log_error "group $sub requires --select <spec> (example: --select group:laptops)."
        return 2
    fi

    local -a selargs=()
    local s
    for s in "${selects[@]}"; do selargs+=(--select "$s"); done
    for s in "${excludes[@]}"; do selargs+=(--exclude "$s"); done
    cert_select "$cert_dir" "${selargs[@]}"
    local rc=$?
    (( rc == 2 )) && return 2
    if (( rc != 0 )); then
        log_warn "No certificate matched the selection in $cert_dir."
        return 1
    fi

    local prc=0 plan_action="$sub"
    [[ "$sub" == prune ]] && plan_action=remove
    case "$plan_action" in
        move|rename) pki_group_plan "$plan_action" "$a" "$b" || prc=$? ;;
        *)           pki_group_plan "$plan_action" "$a" || prc=$? ;;
    esac
    (( prc == 2 )) && return 2
    if (( ${#PKI_RENAME_FILES[@]} == 0 )); then
        log_info "No changes needed - the selected certificate(s) already match."
        return 0
    fi

    local summary
    case "$sub" in
        add)    summary="Add group \"$a\" to ${#PKI_RENAME_FILES[@]} certificate(s)." ;;
        remove) summary="Remove group \"$a\" from ${#PKI_RENAME_FILES[@]} certificate(s)." ;;
        move)   summary="Move group \"$a\" -> \"$b\" on ${#PKI_RENAME_FILES[@]} certificate(s)." ;;
        set)    summary="Set groups to [${a:-none}] on ${#PKI_RENAME_FILES[@]} certificate(s)." ;;
        rename) summary="Group \"$a\" will be replaced by \"$b\" in ${#PKI_RENAME_FILES[@]} certificate(s)." ;;
        prune)  summary="Remove group \"$a\" from the ${#PKI_RENAME_FILES[@]} certificate(s) matching '$when'." ;;
    esac
    pki_group_diff_text "$summary"
    printf '\n'

    if (( dry )); then
        log_info "Dry run - nothing was changed."
        return 0
    fi
    if (( ! assume_yes )); then
        if [[ -t 0 ]]; then
            local answer
            read -rp "$(show_status 'question') Proceed with re-signing? [y/N]: " answer
            [[ "$answer" =~ ^[Yy]$ ]] || { log_info "Canceled - no certificates were changed."; return 0; }
        else
            log_error "Refusing to re-sign without confirmation; re-run with --yes."
            return 2
        fi
    fi
    pki_group_apply "$cert_dir"
}

# Headless CLI: nebula-manager rename-group <old> <new> [--cert-dir DIR] [--yes]
rename_group_cli() {
    local old="" new="" cert_dir="" assume_yes=0
    while (($#)); do
        case "$1" in
            --cert-dir)   shift; cert_dir="${1:-}" ;;
            --cert-dir=*) cert_dir="${1#*=}" ;;
            --yes|-y)     assume_yes=1 ;;
            -h|--help)
                echo "Usage: nebula-manager rename-group <old> <new> [--cert-dir DIR] [--yes]" >&2
                echo "  Re-signs every certificate that carries group <old>, replacing it with <new>." >&2
                echo "  Originals are kept as <name>.crt.bak; private keys are untouched." >&2
                return 0 ;;
            -*) log_error "Unknown option for 'rename-group': $1"; return 2 ;;
            *)
                if [[ -z "$old" ]]; then old="$1"
                elif [[ -z "$new" ]]; then new="$1"
                else log_error "Unexpected argument for 'rename-group': $1"; return 2
                fi ;;
        esac
        shift
    done
    if [[ -z "$old" || -z "$new" ]]; then
        echo "Usage: nebula-manager rename-group <old> <new> [--cert-dir DIR] [--yes]" >&2
        return 2
    fi
    cert_dir="${cert_dir:-$(resolve_cert_dir)}"

    if ! pki_group_scan "$old" "$new" "$cert_dir"; then
        log_warn "No certificate in $cert_dir carries group '$old'."
        return 1
    fi
    pki_group_preview_text "$old" "$new"
    printf '\n'

    if (( ! assume_yes )); then
        if [[ -t 0 ]]; then
            local answer
            read -rp "$(show_status 'question') Proceed with re-signing? [y/N]: " answer
            [[ "$answer" =~ ^[Yy]$ ]] || { log_info "Canceled - no certificates were changed."; return 0; }
        else
            log_error "Refusing to re-sign without confirmation; re-run with --yes."
            return 2
        fi
    fi
    pki_group_apply "$cert_dir"
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
        "$(get_icon 'edit')Rename Group in Certificates"
        "$(get_icon 'edit')Edit Groups (Batch)…"
        "$(get_icon 'inspect')View Certificate and Key Details"
        "$(get_icon 'hour-glass')Certificate Expiry"
        "$(get_icon 'upload')Bundle / Export Client Certificate"
        "$(get_icon 'revoke')Revoke Certificate"
        "$(get_icon 'keys')Switch Certificate Workspace"
        "$(get_icon 'backup')Store Backup / Git"
        "$(get_icon 'error')Remove Certificate"
    )
    dynamic_menu_functions=(
        "list_certs"
        "generate_nebula_ca"
        "generate_nebula_cert"
        "pki_rename_group_tui"
        "pki_group_edit_tui"
        "view_cert_details"
        "list_certs_expiry"
        "pki_bundle_client_menu"
        "revoke_cert"
        "select_cert_workspace"
        "cert_store_menu"
        "remove_cert"
    )
    dynamic_menu dynamic_menu_title dynamic_menu_options dynamic_menu_functions 1
}

# Interactive bundle/export: pick from the existing certificates (rather than
# typing a name from memory), then choose the destination directory.
pki_bundle_client_menu() {
    local cert_dir; cert_dir="$(resolve_cert_dir)"
    local name ips groups desc
    local -a pairs=()
    while IFS=$'\t' read -r name ips groups; do
        [[ -n "$name" ]] || continue
        desc="$name"
        [[ -n "$ips" ]] && desc+="  ($ips)"
        [[ -n "$groups" ]] && desc+="  [$groups]"
        pairs+=( "$name" "$desc" )
    done < <(pki_bundle_candidates "$cert_dir")

    if (( ${#pairs[@]} == 0 )); then
        log_warn "No exportable certificates found in $cert_dir (a bundle needs <name>.crt and <name>.key; mobile certs have no local key)."
        log_info "Create one first: Certificates > Generate Client Certificate."
        return 1
    fi
    # Curses menus can only pick an entry; plain menus also accept a typed name
    # (or path) directly at the selection prompt, so the extra entry is unneeded.
    if [[ "$(ui_backend)" != "plain" ]]; then
        pairs+=( "__custom__" "Type a certificate name manually..." )
    fi

    local choice
    choice="$(ui_menu_or_text "Bundle / Export Client" "Select the certificate to export:" "${pairs[@]}")" || return 0
    case "$choice" in
        text:*)  choice="${choice#text:}" ;;
        __custom__)
            read -p "$(show_status 'question') Certificate name (or path): " choice
            [[ -z "$choice" ]] && return 0
            ;;
    esac

    pki_resolve_bundle_name "$choice" "$cert_dir"
    case $? in
        0) name="$PKI_BUNDLE_RESOLVED" ;;
        2) log_error "Ambiguous certificate name '$choice'. Matches: ${PKI_BUNDLE_MATCHES[*]}"; return 1 ;;
        *) log_error "No exportable certificate matching '$choice' in $cert_dir."; return 1 ;;
    esac
    [[ "$name" != "$choice" ]] && log_info "Matched '$choice' -> '$name'"

    # Suggest a policy pack whose target groups intersect this cert's groups.
    # Never applied silently: it is a menu with an explicit "none" entry.
    local policy_path="" pchoice s
    local -a sugg=() ppairs=( none "No policy pack (use the detected firewall)" )
    if declare -F policy_suggest_for_cert >/dev/null; then
        mapfile -t sugg < <(policy_suggest_for_cert "$name" "$cert_dir")
    fi
    if (( ${#sugg[@]} > 0 )); then
        for s in "${sugg[@]}"; do ppairs+=( "$s" "Use policy pack '$s'" ); done
        pchoice="$(ui_menu "Policy pack" "Suggested for $name (matches its groups):" "${ppairs[@]}")" || pchoice=none
        if [[ -n "$pchoice" && "$pchoice" != none ]]; then
            policy_path="$(policy_resolve "$pchoice")" || policy_path=""
        fi
    fi

    local default_out out
    default_out="$(pki_default_bundle_dir)"
    out="$(ui_dselect "Bundle / Export Client" "Output directory [${default_out}]:" "$default_out")" || return 0
    out="${out/#\~/$HOME}"
    [[ -z "$out" ]] && out="$default_out"
    pki_bundle_client_zip "$name" "$out" "$cert_dir" "$policy_path"
}

# --- Headless CLI --------------------------------------------------

pki_cli() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        list)   list_certs ;;
        expiry) list_certs_expiry "${1:-}" ;;
        remove|rm) pki_remove "${1:?certificate name required}" ;;
        bundle|export|zip)
            local name="" out="" policy=""
            while (($#)); do
                case "$1" in
                    --out=*) out="${1#*=}" ;;
                    --out|-o)
                        shift
                        [[ $# -gt 0 && -n "$1" ]] || { log_error "'cert bundle --out' requires a directory"; return 2; }
                        out="$1"
                        ;;
                    --policy=*) policy="${1#*=}" ;;
                    --policy|-P)
                        shift
                        [[ $# -gt 0 && -n "$1" ]] || { log_error "'cert bundle --policy' requires a pack name (or 'none')"; return 2; }
                        policy="$1"
                        ;;
                    -h|--help)
                        echo "Usage: nebula-manager cert bundle <name|match> [--out DIR] [--policy NAME|none] [--cert-dir DIR]" >&2
                        echo "       omitting <name> lists the certificates that can be exported" >&2
                        return 0 ;;
                    -*) log_error "Unknown option for 'cert bundle': $1"; return 2 ;;
                    *)
                        if [[ -z "$name" ]]; then
                            name="$1"
                        elif [[ -z "$out" ]]; then
                            out="$1"   # backwards-compatible positional output dir
                        else
                            log_error "Unexpected argument for 'cert bundle': $1"; return 2
                        fi
                        ;;
                esac
                shift
            done
            local cert_dir; cert_dir="$(resolve_cert_dir)"
            if [[ -z "$name" ]]; then
                log_error "cert bundle: certificate name required."
                echo "Exportable certificates in $cert_dir:" >&2
                pki_bundle_list "$cert_dir" >&2
                echo "Usage: nebula-manager cert bundle <name|match> [--out DIR] [--cert-dir DIR]" >&2
                return 2
            fi
            pki_resolve_bundle_name "$name" "$cert_dir"
            case $? in
                0) [[ "$PKI_BUNDLE_RESOLVED" != "$name" ]] && log_info "Matched '$name' -> '$PKI_BUNDLE_RESOLVED'"; name="$PKI_BUNDLE_RESOLVED" ;;
                2) log_error "Ambiguous certificate name '$name'. Matches: ${PKI_BUNDLE_MATCHES[*]}"; return 2 ;;
                *)
                    log_error "No exportable certificate matching '$name' in $cert_dir."
                    echo "Exportable certificates:" >&2
                    pki_bundle_list "$cert_dir" >&2
                    return 1
                    ;;
            esac
            out="${out/#\~/$HOME}"
            local policy_path="" sugg
            if [[ "$policy" == "none" ]]; then
                :   # explicit opt-out
            elif [[ -n "$policy" ]]; then
                policy_path="$(policy_resolve "$policy")" || return 1
            elif declare -F policy_suggest_for_cert >/dev/null; then
                sugg="$(policy_suggest_for_cert "$name" "$cert_dir" | paste -sd, -)"
                if [[ -n "$sugg" ]]; then
                    log_info "Suggested policy pack(s) for $name: ${CYAN}$sugg${RESET}"
                    log_info "Embed one with --policy <name> (nothing is applied automatically)."
                fi
            fi
            pki_bundle_client_zip "$name" "${out:-$(pki_default_bundle_dir)}" "$cert_dir" "$policy_path"
            ;;
        workspace)
            select_cert_workspace ;;
        rename-group|rename_group|group-rename)
            rename_group_cli "$@" ;;
        group|groups)
            group_cli "$@" ;;
        store|history)
            cert_store_cli "$@" ;;
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
