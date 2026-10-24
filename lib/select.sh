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

# _ipv4_network <addr[/prefix]> ; print the network address/prefix (IPv4).
# Non-IPv4 values are returned unchanged.
_ipv4_network() {
    local cidr="$1" ip prefix n mask
    ip="${cidr%%/*}"; prefix="${cidr##*/}"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { printf '%s' "$cidr"; return 0; }
    [[ "$prefix" =~ ^[0-9]+$ ]] || prefix=32
    (( prefix > 32 )) && prefix=32
    n="$(_ip4_to_int "$ip")"
    if (( prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    printf '%s/%s' "$(_int_to_ip4 $(( n & mask )))" "$prefix"
}

# cert_group_counts [cert_dir] ; "group<TAB>cert-count", most-used first.
cert_group_counts() {
    local cert_dir="${1:-$(resolve_cert_dir)}" f have=0 i g
    [[ -d "$cert_dir" ]] || return 0
    for f in "$cert_dir"/*.crt; do [[ -f "$f" ]] && { have=1; break; }; done
    (( have )) || return 0
    declare -F cert_select >/dev/null || return 0
    cert_select "$cert_dir" --select all >/dev/null 2>&1 || return 0
    (
        local IFS=','
        for i in "${!SEL_GROUPS[@]}"; do
            for g in ${SEL_GROUPS[i]}; do
                g="${g#"${g%%[![:space:]]*}"}"
                g="${g%"${g##*[![:space:]]}"}"
                [[ -n "$g" ]] && printf '%s\n' "$g"
            done
        done
    ) | sort | uniq -c | sort -k1,1nr -k2,2 | awk '{ print $2 "\t" $1 }'
}

# cert_group_summary [cert_dir] ; compact "group (count), …" line.
cert_group_summary() {
    cert_group_counts "${1:-$(resolve_cert_dir)}" | awk -F'\t' '
        NF { if (++n <= 10) { printf "%s%s (%s)", sep, $1, $2; sep=", " } }
        END { if (n > 10) printf ", …" }
    '
}

# cert_network_counts [cert_dir] ; "network<TAB>cert-count", most-used first.
# Counts each certificate once per distinct network (multiple IPs in one
# network do not inflate the count).
cert_network_counts() {
    local cert_dir="${1:-$(resolve_cert_dir)}" f have=0 i ip
    [[ -d "$cert_dir" ]] || return 0
    for f in "$cert_dir"/*.crt; do [[ -f "$f" ]] && { have=1; break; }; done
    (( have )) || return 0
    declare -F cert_select >/dev/null || return 0
    cert_select "$cert_dir" --select all >/dev/null 2>&1 || return 0
    (
        local -a ips=() nets=()
        for i in "${!SEL_IPS[@]}"; do
            IFS=',' read -ra ips <<< "${SEL_IPS[i]}"
            nets=()
            for ip in "${ips[@]}"; do
                ip="${ip#"${ip%%[![:space:]]*}"}"
                ip="${ip%"${ip##*[![:space:]]}"}"
                [[ -z "$ip" ]] && continue
                [[ "$ip" == */* ]] || ip+="/32"
                nets+=("$(_ipv4_network "$ip")")
            done
            (( ${#nets[@]} )) || continue
            printf '%s\n' "${nets[@]}" | sort -u
        done
    ) | sort | uniq -c | sort -k1,1nr -k2,2 | awk '{ print $2 "\t" $1 }'
}

# cert_select_filter_prompt [cert_dir]
# Build the multi-line filter prompt from what is actually in the workspace
# (groups and overlay networks), with generic syntax examples.
cert_select_filter_prompt() {
    local cert_dir="${1:-$(resolve_cert_dir)}"
    local groups networks group_list net_list cert_count ip_example prompt

    groups="$(cert_group_counts "$cert_dir")"
    networks="$(cert_network_counts "$cert_dir")"
    group_list="$(printf '%s\n' "$groups" | awk -F'\t' '
        NF { if (++n <= 10) { printf "%s%s (%s)", sep, $1, $2; sep=", " } }
        END { if (n > 10) printf ", …" }
    ')"
    net_list="$(printf '%s\n' "$networks" | awk -F'\t' '
        NF { if (++n <= 6) { printf "%s%s (%s)", sep, $1, $2; sep=", " } }
        END { if (n > 6) printf ", …" }
    ')"
    cert_count="$(find "$cert_dir" -maxdepth 1 -type f -name '*.crt' ! -name 'ca.crt' 2>/dev/null | wc -l | tr -d ' ')"
    [[ -n "$group_list" ]] || group_list="(none yet)"
    [[ -n "$net_list" ]] || net_list="(none yet)"
    ip_example="10.0.0.0/24"
    if [[ -n "$networks" ]]; then
        ip_example="$(printf '%s\n' "$networks" | head -n1 | cut -f1)"
    fi

    printf 'Certificate workspace: %s\n' "$cert_dir"
    printf 'Certificates: %s\n' "$cert_count"
    printf 'Groups: %s\n' "$group_list"
    printf 'Networks: %s\n' "$net_list"
    printf 'Filter: all | group:NAME | without:NAME | name:GLOB | ip:CIDR | cert:NAME\n'
    printf 'Examples: group:example-group  name:example-host-*  ip:%s' "$ip_example"
}

# cert_select_tui [cert_dir]
# Show the workspace's actual groups/networks, ask for a filter, then confirm an
# (all-on) checklist of the matches. Narrows SEL_* to the chosen certificates.
cert_select_tui() {
    local cert_dir="${1:-$(resolve_cert_dir)}"
    local prompt spec chosen

    prompt="$(cert_select_filter_prompt "$cert_dir")"

    while true; do
        spec="$(ui_input "Select certificates" "$prompt" "all")" || return 1
        [[ -z "$spec" ]] && spec="all"
        if cert_select "$cert_dir" --select "$spec"; then
            break
        fi
        log_warn "No certificate matches '$spec' in $cert_dir."
        ui_yesno "Select certificates" "Try a different filter?" || return 1
    done

    local i tag desc
    local -a triples=()
    for i in "${!SEL_FILES[@]}"; do
        tag="c$i"
        desc="${SEL_NAMES[i]}"
        [[ -n "${SEL_IPS[i]}" ]] && desc+=" (${SEL_IPS[i]})"
        local gdisp="${SEL_GROUPS[i]:-no groups}"
        desc+=" [${gdisp//,/:}]"
        triples+=( "$tag" "$desc" "on" )
    done

    local chosen tags_out hint
    hint="$(ui_checklist_hint)"
    chosen="$(ui_checklist "Select certificates" "$hint" "${triples[@]}")" \
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
        groups="${groups//,/:}"
        if declare -F maxlen >/dev/null; then
            name="$(maxlen "$name" 36)"
            ips="$(maxlen "$ips" 20)"
            groups="$(maxlen "$groups" 30)"
        fi
        printf '%-36s | %-20s | %s\n' "$name" "$ips" "$groups"
    done
}
