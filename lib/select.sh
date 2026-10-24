#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/select.sh - reusable certificate selection (filter -> list of certs)
# ========================================================================
# One selector feeds every batch action (group add/remove/move/set, bundles,
# policy export). A spec is a small, greppable expression:
#
#   all                     every non-CA certificate
#   group:G   / has:G       certificates carrying group G
#   without:G / missing:G   certificates that do NOT carry group G
#   name:GLOB               certificate name glob (e.g. name:theprof-*)
#   ip:CIDR | ip:ADDR       an overlay address inside CIDR / exactly ADDR
#   cert:NAME               exact certificate name (case-insensitive)
#   NAME                    bare value = exact certificate name
#
# Multiple --select specs are unioned; --exclude specs are subtracted last.
# The CA certificate is always excluded.

# _ipv4_in_cidr <addr[/prefix]> <network/prefix> ; containment test (IPv4).
_ipv4_in_cidr() {
    local addr="${1%%/*}" cidr="$2" net mask a n bits
    [[ "$cidr" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3})/([0-9]{1,2})$ ]] || return 1
    net="${BASH_REMATCH[1]}"; mask="${BASH_REMATCH[3]}"
    [[ "$addr" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3})$ ]] || return 1
    (( mask > 32 )) && return 1
    a="$(_ip4_to_int "${BASH_REMATCH[1]}")"
    n="$(_ip4_to_int "$net")"
    (( mask == 0 )) && return 0
    bits=$(( 32 - mask ))
    (( (a >> bits) == (n >> bits) ))
}

# _sel_ip_match <needle> <comma-separated cert ips>
_sel_ip_match() {
    local needle="$1" ips="$2" ip
    local -a list=()
    IFS=',' read -ra list <<< "$ips"
    for ip in "${list[@]}"; do
        # trim surrounding whitespace
        ip="${ip#"${ip%%[![:space:]]*}"}"
        ip="${ip%"${ip##*[![:space:]]}"}"
        [[ -z "$ip" ]] && continue
        if [[ "$needle" == */* ]]; then
            _ipv4_in_cidr "$ip" "$needle" && return 0
        else
            [[ "${ip%%/*}" == "${needle%%/*}" ]] && return 0
        fi
    done
    return 1
}

# _sel_match <spec> <name> <ips> <groups>
_sel_match() {
    local spec="$1" name="$2" ips="$3" groups="$4"
    [[ -n "$spec" ]] || return 1
    case "$spec" in
        all) return 0 ;;
        group:*|has:*) _pki_groups_have "$groups" "${spec#*:}" ;;
        without:*|missing:*)
            _pki_groups_have "$groups" "${spec#*:}" && return 1
            return 0
            ;;
        name:*)
            # Glob on the right-hand side is intentional.
            # shellcheck disable=SC2053
            [[ "$name" == ${spec#name:} ]]
            ;;
        cert:*)
            local c="${spec#cert:}"
            [[ "${name,,}" == "${c,,}" ]]
            ;;
        ip:*) _sel_ip_match "${spec#ip:}" "$ips" ;;
        *) [[ "${name,,}" == "${spec,,}" ]] ;;
    esac
}

# cert_select [cert_dir] [--select SPEC]... [--exclude SPEC]...
# Fills SEL_FILES, SEL_NAMES, SEL_IPS and SEL_GROUPS (parallel arrays).
# Returns 0 when at least one certificate matched, 1 when the selection is
# empty, 2 on a usage/setup error.
cert_select() {
    local cert_dir
    if (( $# > 0 )) && [[ "$1" != --* ]]; then
        cert_dir="$1"; shift
    else
        cert_dir="$(resolve_cert_dir)"
    fi
    local -a selects=() excludes=()
    while (( $# )); do
        case "$1" in
            --select)    shift; selects+=("${1:-}") ;;
            --select=*)  selects+=("${1#*=}") ;;
            --exclude)   shift; excludes+=("${1:-}") ;;
            --exclude=*) excludes+=("${1#*=}") ;;
            *) log_error "cert_select: unknown option: $1"; return 2 ;;
        esac
        shift
    done
    (( ${#selects[@]} )) || selects=(all)

    if [[ ! -d "$cert_dir" ]]; then
        log_error "Certificate directory not found: $cert_dir"
        return 2
    fi
    local bin bin_path
    bin="$(pki_cert_bin)" || return 2
    bin_path="$(dirname "$bin")"

    local -a all_files=() all_names=() all_ips=() all_groups=()
    local crt json isca name ips groups
    for crt in "$cert_dir"/*.crt; do
        [[ -f "$crt" ]] || continue
        json="$(nebula_cert_json "$bin_path" "$crt")" || continue
        [[ -n "$json" ]] || continue
        isca="$(jq -r '.details.isCa // false' <<<"$json" 2>/dev/null)"
        [[ "$isca" == "true" ]] && continue
        name="$(jq -r '.details.name // empty' <<<"$json" 2>/dev/null)"
        ips="$(jq -r '(.details.ips // []) | join(",")' <<<"$json" 2>/dev/null)"
        groups="$(jq -r '(.details.groups // []) | join(",")' <<<"$json" 2>/dev/null)"
        all_files+=("$crt")
        all_names+=("$name")
        all_ips+=("$ips")
        all_groups+=("$groups")
    done

    SEL_FILES=(); SEL_NAMES=(); SEL_IPS=(); SEL_GROUPS=()
    local i spec hit excluded
    for i in "${!all_files[@]}"; do
        hit=0
        for spec in "${selects[@]}"; do
            if _sel_match "$spec" "${all_names[i]}" "${all_ips[i]}" "${all_groups[i]}"; then
                hit=1; break
            fi
        done
        (( hit )) || continue
        excluded=0
        for spec in "${excludes[@]}"; do
            if _sel_match "$spec" "${all_names[i]}" "${all_ips[i]}" "${all_groups[i]}"; then
                excluded=1; break
            fi
        done
        (( excluded )) && continue
        SEL_FILES+=("${all_files[i]}")
        SEL_NAMES+=("${all_names[i]}")
        SEL_IPS+=("${all_ips[i]}")
        SEL_GROUPS+=("${all_groups[i]}")
    done
    (( ${#SEL_FILES[@]} > 0 ))
}

# cert_select_tui [cert_dir]
# Ask for a filter, then confirm an (all-on) checklist of the matches. Narrows
# SEL_* to the chosen certificates. Returns 0 when at least one is selected.
cert_select_tui() {
    local cert_dir="${1:-$(resolve_cert_dir)}"
    local spec
    spec="$(ui_input "Select certificates" \
        "Filter (all, group:laptops, without:home, name:theprof-*, ip:10.100.0.0/24):" "all")" \
        || return 1
    [[ -z "$spec" ]] && spec="all"
    if ! cert_select "$cert_dir" --select "$spec"; then
        log_warn "No certificate matches '$spec' in $cert_dir."
        return 1
    fi

    local i tag desc
    local -a triples=()
    for i in "${!SEL_FILES[@]}"; do
        tag="c$i"
        desc="${SEL_NAMES[i]}"
        [[ -n "${SEL_IPS[i]}" ]] && desc+=" (${SEL_IPS[i]})"
        desc+=" [${SEL_GROUPS[i]:-no groups}]"
        triples+=( "$tag" "$desc" "on" )
    done

    local chosen tags_out
    chosen="$(ui_checklist "Select certificates" "Space toggles, Enter confirms." "${triples[@]}")" \
        || { log_info "Canceled."; return 1; }

    local -a files=() names=() ips=() groups=()
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        i="${tag#c}"
        [[ "$i" =~ ^[0-9]+$ ]] || continue
        files+=("${SEL_FILES[i]}")
        names+=("${SEL_NAMES[i]}")
        ips+=("${SEL_IPS[i]}")
        groups+=("${SEL_GROUPS[i]}")
    done <<< "$chosen"

    if (( ${#files[@]} == 0 )); then
        log_warn "No certificates selected."
        return 1
    fi
    SEL_FILES=("${files[@]}")
    SEL_NAMES=("${names[@]}")
    SEL_IPS=("${ips[@]}")
    SEL_GROUPS=("${groups[@]}")
    return 0
}

# cert_group_list [cert_dir] ; compact table of every non-CA certificate.
cert_group_list() {
    local cert_dir="${1:-$(resolve_cert_dir)}"
    cert_select "$cert_dir" --select all || return 1
    local i name ips groups
    printf '%-36s | %-20s | %s\n' "Name" "IPs" "Groups"
    printf '%s\n' "--------------------------------------------------------------------------------------------------"
    for i in "${!SEL_FILES[@]}"; do
        name="${SEL_NAMES[i]}"
        ips="${SEL_IPS[i]:-N/A}"
        groups="${SEL_GROUPS[i]:-None}"
        if declare -F maxlen >/dev/null; then
            name="$(maxlen "$name" 36)"
            ips="$(maxlen "$ips" 20)"
            groups="$(maxlen "$groups" 30)"
        fi
        printf '%-36s | %-20s | %s\n' "$name" "$ips" "$groups"
    done
}
