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
        _nebula_info_derive "$cfg" "$IMP_CONFIG" >/dev/null 2>&1 || true
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
    IMPORT_YES=0 IMPORT_FORCE=0 IMPORT_START=0 IMPORT_FROM="" IMPORT_BUNDLE="" IMPORT_DIR=""
    local dest="" dry=0
    while (($#)); do
        case "$1" in
            --dry-run|-n) dry=1 ;;
            --yes|-y)     IMPORT_YES=1 ;;
            --force|-f)   IMPORT_FORCE=1 ;;
            --start)      IMPORT_START=1 ;;
            --from)       shift; IMPORT_FROM="${1:-}" ;;
            --bundle)     shift; IMPORT_BUNDLE="${1:-}" ;;
            --dir)        shift; IMPORT_DIR="${1:-}" ;;
            --config)     shift; CONF_OVERRIDE="${1:-}" ;;
            *)            dest="$1" ;;
        esac
        shift
    done
    [[ -n "$dest" ]] && CONF_OVERRIDE="$dest"

    if [[ -n "$IMPORT_BUNDLE" ]]; then
        IMPORT_BUNDLE_DRY_RUN="$dry"
        import_bundle_run "$IMPORT_BUNDLE" "${IMPORT_DIR:-/etc/nebula}"
        return
    fi

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

###################################################################
#################### Import a client bundle #######################
###################################################################

# Extract a bundle produced by `nebula-manager cert bundle` into <dest>.
_bundle_extract() {
    local archive="$1" dest="$2"
    case "${archive,,}" in
        *.zip)
            if ! command -v unzip >/dev/null 2>&1; then
                log_error "Cannot extract a .zip bundle: 'unzip' is not installed."
                log_info "Install it (e.g. 'sudo apt install unzip') or ask for a .tar.gz bundle."
                return 1
            fi
            unzip -q "$archive" -d "$dest"
            ;;
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$dest" --no-same-owner --no-same-permissions
            ;;
        *.tar)
            tar -xf "$archive" -C "$dest" --no-same-owner --no-same-permissions
            ;;
        *)
            log_error "Unsupported bundle format: $archive (expected .zip, .tar.gz, .tgz or .tar)."
            return 1
            ;;
    esac
}

_bundle_find_ca() {
    find "$1" -type f -iname 'ca.crt' -print -quit 2>/dev/null
}

# _bundle_find_cert_pair <dir> -> "crt<TAB>key<TAB>name" (first matching pair)
_bundle_find_cert_pair() {
    local dir="$1" crt base key
    while IFS= read -r crt; do
        base="$(basename "$crt")"
        base="${base%.*}"
        [[ "${base,,}" == "ca" ]] && continue
        key="$(dirname "$crt")/$base.key"
        [[ -f "$key" ]] || continue
        printf '%s\t%s\t%s\n' "$crt" "$key" "$base"
        return 0
    done < <(find "$dir" -type f -iname '*.crt' 2>/dev/null | sort)
    return 1
}

_bundle_find_config() {
    local dir="$1" f
    for f in "$dir/config.yml.template" "$dir/config.yml"; do
        [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
    done
    find "$dir" -type f \( -name 'config.yml.template' -o -name 'config.yml' \) -print -quit 2>/dev/null
}

# The exported config hardcodes /etc/nebula; rewrite it when the user installs
# somewhere else. Done without sed to stay safe with special characters.
_bundle_rebase_config() {
    local src="$1" target="$2"
    if [[ "$target" == "/etc/nebula" ]]; then
        cat "$src"
        return 0
    fi
    awk -v old="/etc/nebula" -v new="$target" '{
        while ((i = index($0, old)) > 0)
            $0 = substr($0, 1, i-1) new substr($0, i+length(old))
        print
    }' "$src"
}

_bundle_service() {
    local hit
    hit="$(_imp_scan_unit_files | awk -F'\t' '$1 == "nebula.service" { print; exit }')"
    [[ -z "$hit" ]] && hit="$(_imp_scan_unit_files | awk -F'\t' '$1 !~ /@/ { print; exit }')"
    if [[ -n "$hit" ]]; then printf '%s\n' "${hit%%$'\t'*}"; else printf 'nebula.service\n'; fi
}

# Copy with a timestamped backup of an existing destination, elevating only
# when the destination directory is not writable by the current user.
_bundle_copy_file() {
    local src="$1" dest="$2" dir bak
    dir="$(dirname "$dest")"
    if [[ -e "$dest" ]]; then
        bak="${dest}.bak.$(date +%Y%m%d-%H%M%S)"
        if path_requires_root "$dir"; then
            elevate_why "back up $dest" cp -p "$dest" "$bak" || return 1
        else
            cp -p "$dest" "$bak" || return 1
        fi
        log_info "Backed up existing $(basename "$dest") to $bak"
    fi
    if path_requires_root "$dir"; then
        elevate_why "install $(basename "$src") into $dir" cp -p "$src" "$dest" || return 1
    else
        cp -p "$src" "$dest" || return 1
    fi
    return 0
}

# import_bundle_run <archive> [target_dir]
# Installs a client bundle (cert/key/ca/config template), registers a
# [server.*] entry and (when needed) asks for elevation. Never runs the
# archive's contents.
import_bundle_run() {
    local archive="${1:-}" target="${2:-/etc/nebula}"
    local force="${IMPORT_FORCE:-0}" yes="${IMPORT_YES:-0}" dry="${IMPORT_BUNDLE_DRY_RUN:-0}"
    [[ -n "$archive" ]] || { log_error "Usage: nebula-manager import --bundle FILE [--dir DIR] [--yes]"; return 2; }
    [[ -f "$archive" ]] || { log_error "Bundle not found: $archive"; return 1; }
    target="${target/#\~/$HOME}"
    [[ -z "$target" ]] && target="/etc/nebula"

    local tmp; tmp="$(mktemp -d)"
    _bundle_extract "$archive" "$tmp" || { rm -rf "$tmp"; return 1; }

    local ca pair crt key name cfg_tmpl
    ca="$(_bundle_find_ca "$tmp")" || ca=""
    pair="$(_bundle_find_cert_pair "$tmp")" || pair=""
    if [[ -z "$ca" || -z "$pair" ]]; then
        log_error "This does not look like a nebula-manager client bundle."
        log_info "Expected ca.crt plus a matching <name>.crt and <name>.key."
        rm -rf "$tmp"; return 1
    fi
    IFS=$'\t' read -r crt key name <<< "$pair"
    cfg_tmpl="$(_bundle_find_config "$tmp")" || cfg_tmpl=""
    if [[ -z "$cfg_tmpl" ]]; then
        log_error "Bundle is missing config.yml.template/config.yml."
        rm -rf "$tmp"; return 1
    fi

    # Validate the certificate when nebula-cert is available.
    local nc; nc="$(pki_cert_bin 2>/dev/null || true)"
    if [[ -n "$nc" ]]; then
        local json isca
        json="$(nebula_cert_json "$(dirname "$nc")" "$crt")" || json=""
        if [[ -z "$json" ]]; then
            log_error "The bundle's certificate could not be parsed: $crt"
            rm -rf "$tmp"; return 1
        fi
        isca="$(jq -r '.details.isCa // false' <<<"$json" 2>/dev/null)"
        if [[ "$isca" == "true" ]]; then
            log_error "The bundle contains a CA certificate, not a client certificate."
            rm -rf "$tmp"; return 1
        fi
    fi

    local service conf sname bin_path
    service="$(_bundle_service)"
    conf="$(resolve_server_conf)"
    sname="$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')"
    [[ -z "$sname" ]] && sname="$(hostname 2>/dev/null || echo client)"
    bin_path="${NEBULA_BIN_PATH:-}"
    if [[ ! -x "$bin_path/nebula" ]]; then
        local nb; nb="$(command -v nebula 2>/dev/null || true)"
        [[ -n "$nb" ]] && bin_path="$(dirname "$(readlink -f "$nb")")"
    fi
    [[ -z "$bin_path" ]] && bin_path="/usr/local/bin"

    echo -e "${BOLD}${CYAN}Client bundle${RESET}"
    printf '  archive:     %s\n' "$archive"
    printf '  certificate: %s\n' "$name"
    printf '  target:      %s\n' "$target"
    printf '  service:     %s\n' "$service"
    printf '  manager:     %s\n' "$conf"
    printf '  files:       ca.crt, %s.crt, %s.key, config.yml\n' "$name" "$name"

    if (( dry )); then
        echo
        log_info "Dry run: nothing written."
        rm -rf "$tmp"; return 0
    fi

    if (( yes == 0 && force == 0 )); then
        if [[ ! -t 0 ]]; then
            log_error "Refusing to write without confirmation; re-run with --yes (or --force)."
            rm -rf "$tmp"; return 1
        fi
        if ! ui_yesno "Import client bundle" "Install this client into $target?"; then
            log_info "Aborted."
            rm -rf "$tmp"; return 1
        fi
    fi

    local cfg_dest="$target/config.yml"
    if [[ -e "$cfg_dest" ]] && (( force == 0 )); then
        if [[ -t 0 ]]; then
            if ! ui_yesno "Import client bundle" "$cfg_dest already exists. Replace it (a backup is kept)?"; then
                log_info "Aborted."
                rm -rf "$tmp"; return 1
            fi
        else
            log_error "Refusing to overwrite $cfg_dest (re-run with --force)."
            rm -rf "$tmp"; return 1
        fi
    fi

    ensure_dir "$target" || { rm -rf "$tmp"; return 1; }

    local f
    for f in "$ca" "$crt" "$key"; do
        _bundle_copy_file "$f" "$target/$(basename "$f")" || { rm -rf "$tmp"; return 1; }
    done

    local tmpcfg; tmpcfg="$(mktemp)"
    if ! _bundle_rebase_config "$cfg_tmpl" "$target" > "$tmpcfg"; then
        rm -f "$tmpcfg"; rm -rf "$tmp"; return 1
    fi
    _bundle_copy_file "$tmpcfg" "$cfg_dest" || { rm -f "$tmpcfg"; rm -rf "$tmp"; return 1; }
    rm -f "$tmpcfg"

    SERVER_CONF="$conf"
    if [[ ! -f "$SERVER_CONF" ]]; then
        local tmpconf; tmpconf="$(mktemp)"
        {
            printf '# Generated by "nebula-manager import --bundle".\n'
            printf '[global]\n'
            printf 'bin_path=%s\n' "$bin_path"
            printf 'cert_dir=%s\n' "$target"
            printf '\n[server.%s]\n' "$sname"
            printf 'dir=%s\n' "$target"
            printf 'service=%s\n' "$service"
            printf 'enabled=true\n'
            printf 'role=client\n'
        } > "$tmpconf"
        ensure_dir "$(dirname "$SERVER_CONF")" || { rm -f "$tmpconf"; rm -rf "$tmp"; return 1; }
        if _conf_write "$tmpconf"; then
            log_success "Created $SERVER_CONF"
        else
            rm -f "$tmpconf"; rm -rf "$tmp"; return 1
        fi
        rm -f "$tmpconf"
    else
        server_add_entry "$sname" "$target" "$service" true client "" || { rm -rf "$tmp"; return 1; }
    fi

    if [[ -r "$cfg_dest" ]]; then
        _nebula_info_derive "$cfg_dest" "$cfg_dest" >/dev/null 2>&1 || true
    fi

    rm -rf "$tmp"
    # Offer to enable/start the service when it is installed but not running.
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_info "Service $service is already running."
        else
            local do_start="${IMPORT_START:-0}"
            if ! systemctl cat "$service" >/dev/null 2>&1; then
                log_warn "systemd unit $service not found; install Nebula first, then start it from Maintenance."
            elif (( do_start == 0 )) && [[ -t 0 && "${NEBULA_NO_PROMPT:-0}" != 1 ]]; then
                ui_yesno "Start Nebula" "The service $service is not running. Enable and start it now?" && do_start=1
            fi
            if (( do_start )); then
                if elevate_why "enable and start the Nebula service ($service)" systemctl enable --now "$service"; then
                    log_success "Enabled and started $service."
                else
                    log_error "Could not start $service; check: systemctl status $service"
                fi
            else
                log_info "Start the service from Maintenance when you are ready."
            fi
        fi
    fi

    log_success "Imported client '$name' into $target."
    [[ "$target" != "/etc/nebula" ]] && log_warn "Custom target: ensure $service uses $cfg_dest."
    return 0
}

# Ask where a client bundle should be installed. Explains the two common
# choices, offers a browser/custom path, and defaults to /etc/nebula.
_bundle_target_menu() {
    local home_target="${HOME:-$PWD}/nebula"
    local prompt="Where should the bundle be installed?

/etc/nebula is read by the system Nebula service (writes need sudo).
${home_target} is user-owned (no sudo, but only manual runs use it).
Press Enter for /etc/nebula, or type a path directly."
    local choice rc
    while true; do
        choice="$(ui_menu_or_text "Import client bundle" "$prompt" \
            "system" "/etc/nebula (system service; needs sudo) [default]" \
            "home" "${home_target} (user-owned; no sudo)" \
            "browse" "Browse for a directory..." \
            "custom" "Type a path...")"
        rc=$?
        (( rc == 1 )) && return 1
        (( rc == 2 )) && { printf '%s\n' "/etc/nebula"; return 0; }

        case "$choice" in
            system) printf '%s\n' "/etc/nebula"; return 0 ;;
            home)   printf '%s\n' "$home_target"; return 0 ;;
            text:*) printf '%s\n' "${choice#text:}"; return 0 ;;
            browse)
                local picked
                picked="$(ui_dselect "Import client bundle" "Select the install directory:" "${HOME:-$PWD}")" || continue
                [[ -n "$picked" ]] && { printf '%s\n' "$picked"; return 0; }
                ;;
            custom)
                local typed
                typed="$(ui_input "Import client bundle" "Install directory:" "/etc/nebula")" || continue
                typed="${typed/#\~/$HOME}"
                [[ -n "$typed" ]] && { printf '%s\n' "$typed"; return 0; }
                ;;
        esac
    done
}

# Interactive Setup entry: choose a bundle with a file browser, then a target.
import_bundle_tui() {
    local start="${HOME:-$PWD}/Downloads"
    [[ -d "$start" ]] || start="$PWD"
    local archive; archive="$(ui_fselect "Import client bundle" "Select a client bundle (.zip / .tar.gz):" "$start")" || return 0
    [[ -n "$archive" && -f "$archive" ]] || { log_error "No bundle selected."; return 1; }
    local target; target="$(_bundle_target_menu)" || return 0
    target="${target/#\~/$HOME}"
    [[ -z "$target" ]] && target="/etc/nebula"
    # Interactive TUI: ask for confirmation. In a piped/automated run there is
    # nobody to answer the prompt, so treat the selected paths as confirmation.
    if [[ -t 0 ]]; then IMPORT_YES=0; else IMPORT_YES=1; fi
    IMPORT_FORCE=0 IMPORT_START=0 IMPORT_BUNDLE_DRY_RUN=0
    if import_bundle_run "$archive" "$target"; then
        log_info "Reloading with the imported server..."
        TUI_RESTART=1
    fi
}

import_cli() { import_run "$@"; }
