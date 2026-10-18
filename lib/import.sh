#!/bin/bash
# shellcheck shell=bash
#
# lib/import.sh - discover an existing Nebula installation and generate
# nebula-manager.conf (see docs/user-stories.md, Story 1 / Phase 0).
#
# Discovery is READ-ONLY. If a file is privileged (owned by the service user or
# root) we read it through read_nebula_config/readable_nebula_config, which asks
# before prompting for a password and shows the exact command it will run.

[[ -n "${NEBULA_MANAGER_IMPORT_SOURCED:-}" ]] && return 0
NEBULA_MANAGER_IMPORT_SOURCED=1

# --- tiny YAML helpers (top-level sections, unindented) -----------------------

# _imp_section_key <file> <section> <key> -> value
_imp_section_key() {
    awk -v sec="$2" -v key="$3" '
        $0 ~ "^"sec":" { insec=1; next }
        /^[^[:space:]#]/ { insec=0 }
        insec && $0 ~ "^[[:space:]]+"key"[[:space:]]*:" {
            v = $0
            sub(/^[^:]*:[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*$/, "", v)
            gsub(/"/, "", v)
            sub(/[[:space:]]+$/, "", v)
            print v; exit
        }' "$1" 2>/dev/null
}

# _imp_static_host <file> -> "10.100.0.1 vps.example:4545" (first entry)
_imp_static_host() {
    awk '
        /^[[:space:]]*"[^"]+"/ {
            line = $0
            k = line; sub(/^[[:space:]]*"/, "", k); sub(/".*/, "", k)
            v = line; sub(/.*\[[[:space:]]*"/, "", v); sub(/".*/, "", v)
            if (k ~ /^[0-9]/) { print k " " v; exit }
        }' "$1" 2>/dev/null
}

# --- detection ---------------------------------------------------------------

# Print "<unit>\t<path>" for nebula*.service unit files found on disk. Works
# without a D-Bus session (containers, `sudo -i`, restricted shells) where
# `systemctl` cannot connect to the system bus.
_imp_scan_unit_files() {
    local d f
    for d in \
        /etc/systemd/system \
        /run/systemd/system \
        /usr/lib/systemd/system \
        /lib/systemd/system \
        "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" \
        "${HOME:-}/.config/systemd/user"
    do
        [[ -d "$d" ]] || continue
        for f in "$d"/nebula*.service; do
            [[ -f "$f" ]] || continue
            printf '%s\t%s\n' "$(basename "$f")" "$f"
        done
    done
}

# First ExecStart line of a unit file (without the key).
_imp_unit_execstart() {
    awk '
        /^[[:space:]]*ExecStart[[:space:]]*=/ {
            line = $0
            sub(/^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*/, "", line)
            print line; exit
        }' "$1" 2>/dev/null
}

# import_detect [config_path_override]
# Populates IMP_* globals from the environment (best effort, never fails hard).
import_detect() {
    local cfg_override="${1:-}"
    IMP_UNITS="" IMP_SERVICE="" IMP_SERVICE_PATH="" IMP_BIN_PATH=""
    IMP_CONFIG="" IMP_CONFIG_DIR="" IMP_TUN="nebula1" IMP_PORT=""
    IMP_IS_LH="" IMP_STATIC="" IMP_CERTS_DIR="" IMP_CERT_COUNT=0

    # binaries
    local neb
    neb="$(command -v nebula 2>/dev/null || true)"
    [[ -n "$neb" ]] && IMP_BIN_PATH="$(dirname "$(readlink -f "$neb")")"

    # systemd units: prefer systemctl, but fall back to scanning unit files on
    # disk so detection still works without a D-Bus session.
    local units="" unit_path=""
    if command -v systemctl >/dev/null 2>&1; then
        units="$(systemctl list-units --type=service --all --no-legend 'nebula*' 2>/dev/null | awk 'NF{print $1}')"
        [[ -z "$units" ]] && units="$(systemctl list-unit-files --no-legend 'nebula*' 2>/dev/null | awk 'NF{print $1}')"
    fi
    local u; u="$(printf '%s\n' "$units" | sed '/^$/d' | head -n1)"
    if [[ -n "$u" ]] && command -v systemctl >/dev/null 2>&1; then
        unit_path="$(systemctl show -p FragmentPath --value "$u" 2>/dev/null)"
    fi
    if [[ -z "$u" || -z "$unit_path" || ! -f "$unit_path" ]]; then
        local hit; hit="$(_imp_scan_unit_files | head -n1)"
        if [[ -n "$hit" ]]; then
            u="${hit%%$'\t'*}"
            unit_path="${hit#*$'\t'}"
            units="$u"
        fi
    fi
    IMP_UNITS="$units"
    IMP_SERVICE="${u:-nebula.service}"
    IMP_SERVICE_PATH="$unit_path"

    # ExecStart -> config path + binary path
    local exec=""
    if [[ -n "$unit_path" && -f "$unit_path" ]]; then
        exec="$(_imp_unit_execstart "$unit_path")"
    elif [[ -n "$u" ]] && command -v systemctl >/dev/null 2>&1; then
        exec="$(systemctl show -p ExecStart --value "$u" 2>/dev/null)"
    fi
    if [[ -n "$exec" ]]; then
        IMP_CONFIG="$(printf '%s' "$exec" | grep -oE -- '-config[= ][^ ;]+' | head -n1 | sed -E 's/^-config[= ]//')"
        local exe=""
        if [[ "$exec" == *path=* ]]; then
            exe="$(printf '%s' "$exec" | sed -E 's/.*path=([^ ;}]+).*/\1/')"
        else
            exe="$(printf '%s' "$exec" | awk '{print $1}')"
        fi
        if [[ -n "$exe" && -x "$exe" ]]; then
            IMP_BIN_PATH="$(dirname "$(readlink -f "$exe")")"
        fi
    fi

    # config path: override -> ExecStart -> default
    if [[ -n "$cfg_override" ]]; then
        IMP_CONFIG="$cfg_override"
    fi
    [[ -z "$IMP_CONFIG" ]] && IMP_CONFIG="/etc/nebula/config.yml"
    IMP_CONFIG_DIR="$(dirname "$IMP_CONFIG")"

    # parse the config (a readable copy; may prompt for sudo)
    local cfg=""
    if [[ -f "$IMP_CONFIG" ]]; then
        cfg="$(readable_nebula_config "$IMP_CONFIG" 2>/dev/null)" || cfg=""
    fi
    if [[ -n "$cfg" ]]; then
        local d p lh pki_ca
        d="$(_imp_section_key "$cfg" tun dev)";        [[ -n "$d"  ]] && IMP_TUN="$d"
        p="$(_imp_section_key "$cfg" listen port)";    [[ -n "$p"  ]] && IMP_PORT="$p"
        lh="$(_imp_section_key "$cfg" lighthouse am_lighthouse)"; IMP_IS_LH="$lh"
        IMP_STATIC="$(_imp_static_host "$cfg")"
        pki_ca="$(_imp_section_key "$cfg" pki ca)"
        [[ -n "$pki_ca" ]] && IMP_CERTS_DIR="$(dirname "$pki_ca")"
        # Refresh the startup-header cache from this (possibly elevated) read.
        _nebula_info_derive "$cfg" >/dev/null 2>&1 || true
    fi
    [[ -z "$IMP_PORT" || "$IMP_PORT" == "0" ]] && IMP_PORT="$(autodetect_nebula_port 2>/dev/null)"

    # certificate workspace: pki dir -> detected candidates -> default
    if [[ -z "$IMP_CERTS_DIR" ]]; then
        local c
        while IFS= read -r c; do [[ -n "$c" ]] && { IMP_CERTS_DIR="$c"; break; }; done < <(workspace_candidates)
    fi
    [[ -z "$IMP_CERTS_DIR" ]] && IMP_CERTS_DIR="$(nebula_keys_default_dir)"
    if [[ -d "$IMP_CERTS_DIR" ]]; then
        IMP_CERT_COUNT="$(ls "$IMP_CERTS_DIR"/*.crt 2>/dev/null | wc -l | tr -d ' ')"
    fi

    [[ -z "$IMP_BIN_PATH" ]] && [[ -x /usr/local/bin/nebula ]] && IMP_BIN_PATH=/usr/local/bin
    [[ -z "$IMP_BIN_PATH" ]] && IMP_BIN_PATH="${NEBULA_BIN_PATH:-/usr/local/bin}"
}

# import_found : did we detect anything worth importing?
import_found() {
    [[ -n "$IMP_UNITS" ]] && return 0
    command -v nebula >/dev/null 2>&1 && return 0
    [[ -f "$IMP_CONFIG" ]] && return 0
    return 1
}

# import_server_name : a sane [server.NAME] label
import_server_name() {
    local base="${IMP_SERVICE:-nebula.service}"
    base="${base%.service}"; base="${base#nebula-}"; base="${base#nebula}"
    [[ -z "$base" ]] && base="$(hostname 2>/dev/null || echo default)"
    printf '%s' "$base" | tr -c 'A-Za-z0-9_.-' '_'
}

# import_render_conf : print a proposed nebula-manager.conf
import_render_conf() {
    local name; name="$(import_server_name)"
    printf '# Generated by "nebula-manager import".\n'
    printf '# Review [server.*] entries before relying on them.\n'
    printf '\n[global]\n'
    printf 'bin_path=%s\n' "${IMP_BIN_PATH:-/usr/local/bin}"
    printf 'cert_dir=%s\n' "${IMP_CERTS_DIR:-$(nebula_keys_default_dir)}"
    [[ -n "$IMP_PORT" ]] && printf 'default_port=%s\n' "$IMP_PORT"
    printf '\n[server.%s]\n' "$name"
    printf 'dir=%s\n' "${IMP_CONFIG_DIR:-/etc/nebula}"
    printf 'service=%s\n' "${IMP_SERVICE:-nebula.service}"
    printf 'enabled=true\n'
}

# import_write_conf <dest>
import_write_conf() {
    local dest="$1"
    ensure_dir "$(dirname "$dest")" || return 1
    if [[ -e "$dest" ]]; then
        # Non-interactive callers must opt in explicitly (--yes/--force).
        if [[ "${IMPORT_FORCE:-0}" != 1 && "${IMPORT_YES:-0}" != 1 && ! -t 0 ]]; then
            log_error "Config already exists: $dest (use --force to overwrite)"
            return 1
        fi
        # Keep a backup before overwriting.
        local bak; bak="${dest}.bak.$(date +%Y%m%d-%H%M%S)"
        if path_requires_root "$dest"; then
            elevate cp "$dest" "$bak" 2>/dev/null && log_info "Backed up existing config to $bak"
        else
            cp "$dest" "$bak" 2>/dev/null && log_info "Backed up existing config to $bak"
        fi
    fi
    if path_requires_root "$dest"; then
        import_render_conf | elevate_why "write nebula-manager.conf to $dest" tee "$dest" >/dev/null
    else
        import_render_conf > "$dest" || { log_error "Failed to write $dest"; return 1; }
    fi
    log_success "Wrote $dest"
}

# import_run [--dry-run] [--yes] [--force] [--from CONFIG] [--config OUT] [OUT]
import_run() {
    IMPORT_YES=0 IMPORT_FORCE=0 IMPORT_FROM=""
    local dest="" dry=0
    while (($#)); do
        case "$1" in
            --dry-run|-n) dry=1 ;;
            --yes|-y)     IMPORT_YES=1 ;;
            --force|-f)   IMPORT_FORCE=1 ;;
            --from)       shift; IMPORT_FROM="${1:-}" ;;
            --config)     shift; CONF_OVERRIDE="${1:-}" ;;
            *)            dest="$1" ;;
        esac
        shift
    done
    [[ -n "$dest" ]] && CONF_OVERRIDE="$dest"

    import_detect "$IMPORT_FROM"
    if ! import_found; then
        log_warn "No existing Nebula installation detected."
        log_info "Start fresh with: nebula-manager config init"
        return 1
    fi

    echo -e "${BOLD}${CYAN}Detected Nebula installation${RESET}"
    printf '  service:      %s%s\n' "$IMP_SERVICE" "$([[ -z "$IMP_UNITS" ]] && echo ' (no systemd unit found)')"
    printf '  config:       %s\n' "$IMP_CONFIG"
    printf '  tun:          %s\n' "$IMP_TUN"
    printf '  listen port:  %s\n' "${IMP_PORT:-auto}"
    printf '  lighthouse:   %s%s\n' "${IMP_IS_LH:-?}" "$([[ -n "$IMP_STATIC" ]] && echo " (first peer: $IMP_STATIC)")"
    printf '  certs:        %s (%s .crt)\n' "$IMP_CERTS_DIR" "$IMP_CERT_COUNT"
    printf '  bin_path:     %s\n' "$IMP_BIN_PATH"

    local target; target="$(resolve_server_conf)"
    [[ -n "${CONF_OVERRIDE:-}" ]] && target="$CONF_OVERRIDE"
    printf '\n'
    echo -e "${BOLD}Proposed $target:${RESET}"
    import_render_conf
    printf '\n'

    (( dry )) && return 0

    local verb="Write"; [[ -e "$target" ]] && verb="Overwrite"
    if [[ "${IMPORT_YES:-0}" != 1 ]]; then
        if [[ ! -t 0 ]]; then
            log_error "Refusing to write without confirmation; re-run with --yes (or --force)."
            return 1
        fi
        local a
        read -rp "$(show_status 'question') $verb this config to $target?$([[ -e "$target" ]] && echo ' (a backup will be kept)') [Y/n]: " a
        [[ "$a" =~ ^[Nn] ]] && { log_info "Aborted."; return 1; }
    fi
    import_write_conf "$target"
}

import_cli() { import_run "$@"; }
