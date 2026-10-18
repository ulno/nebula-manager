#!/bin/bash
# shellcheck shell=bash
#
# lib/system.sh - Privileged and host-system actions
# -------------------------------------------------
# This module owns everything that touches the host system: the on-demand
# sudo wrapper (elevate), systemd unit control, writing under /etc/nebula,
# interface inspection, dependency handling and the installer/updater.
#
# Least-privilege rule for the whole project: nothing here runs as root
# unless a specific, unavoidable privileged action is requested. Every
# privileged call goes through elevate().

[[ -n "${NEBULA_MANAGER_SYSTEM_SOURCED:-}" ]] && return 0
NEBULA_MANAGER_SYSTEM_SOURCED=1

###################################################################
####################### Privilege helpers #########################
###################################################################

# are we effectively root already?
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

# elevate <cmd> [args...]
# Runs the command directly when already root, otherwise via sudo. Before any
# password prompt it explains *why* privileges are needed (set ELEVATE_REASON,
# or use elevate_why) and shows the exact command being run. Prints a clear
# error if sudo is unavailable or fails.
elevate() {
    if (( $# == 0 )); then
        log_error "elevate() called without a command"
        return 2
    fi
    if is_root; then
        debug_print_cmd "$@"
        "$@"
        return $?
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        log_error "This action requires root privileges, but 'sudo' is not installed."
        return 1
    fi
    debug_print_cmd sudo "$@"
    # Announce the reason + command when a password is likely required
    # (i.e. no cached credentials). Uses sudo -n so nothing is prompted here.
    if ! sudo -n true 2>/dev/null; then
        local why="${ELEVATE_REASON:-}"
        if [[ -n "$why" ]]; then
            log_warn "Administrator privileges required: ${BOLD}$why${RESET}"
        else
            log_warn "Administrator privileges required for: ${BOLD}$1${RESET}"
        fi
        # DEBUG=learn already printed the exact command above.
        debug_want learn || echo -e "    ${CYAN}command:${RESET} ${RESET}sudo $*" >&2
    fi
    if ! sudo "$@"; then
        log_error "Elevation failed (or was declined) for: sudo $*"
        return 1
    fi
    return 0
}

# elevate_why "<purpose>" <cmd> [args...]
# Same as elevate(), but states the purpose for the privilege request.
elevate_why() {
    local why="$1"; shift
    ELEVATE_REASON="$why" elevate "$@"
}

# path_requires_root <path>
# Returns 0 (true) when the nearest existing ancestor of <path> is not
# writable by the current user, i.e. the write needs elevation.
path_requires_root() {
    local target="$1" dir="$1" parent
    while [[ ! -e "$dir" ]]; do
        parent="$(dirname "$dir")"
        [[ "$parent" == "$dir" ]] && break   # reached the filesystem root
        dir="$parent"
    done
    [[ -e "$dir" ]] || return 0              # nothing exists yet -> most likely privileged
    is_root && return 1
    [[ ! -w "$dir" ]]
}

# ensure_dir <path> [mode]
# Creates <path> and any missing parents, elevating only when required.
ensure_dir() {
    local dir="$1" mode="${2:-}"
    if [[ -d "$dir" ]]; then
        [[ -n "$mode" ]] && safe_chmod "$mode" "$dir"
        return 0
    fi
    if path_requires_root "$dir"; then
        elevate mkdir -p "$dir" || return 1
    else
        mkdir -p "$dir" || { log_error "Failed to create directory: $dir"; return 1; }
    fi
    [[ -n "$mode" ]] && safe_chmod "$mode" "$dir"
    return 0
}

# chmod that elevates only if the current user cannot change the path
safe_chmod() {
    local mode="$1" path="$2"
    if [[ -e "$path" && -w "$path" ]] && ! is_root; then
        chmod "$mode" "$path" 2>/dev/null && return 0
    fi
    if path_requires_root "$path" || ! chmod "$mode" "$path" 2>/dev/null; then
        elevate chmod "$mode" "$path"
    fi
}

# need_root_for <path> : friendly guard used before privileged work.
need_root_for() {
    local path="$1"
    if path_requires_root "$path" && ! is_root && ! command -v sudo >/dev/null 2>&1; then
        log_error "Writing to '$path' requires root and 'sudo' is not available."
        return 1
    fi
    return 0
}

###################################################################
##################### Arch / packages / deps ######################
###################################################################

declare -gA PKG_BASE=(
  [awk]="gawk"
  [curl]="curl"
  [find]="findutils"
  [grep]="grep"
  [jq]="jq"
  [ping]="iputils-ping"
  [sed]="sed"
  [sudo]="sudo"
  [systemctl]="systemd"
  [tar]="tar"
  [wget]="wget"
  [yq]="yq"
  [sha256sum]="coreutils"
  [iperf3]="iperf3"
)
declare -gA PKG_RH_OVERRIDE=(
  [ping]="iputils"
)
# Arch/CachyOS package names that differ from the Debian defaults.
declare -gA PKG_ARCH_OVERRIDE=(
  [ping]="iputils"
  [whiptail]="libnewt"
  [yq]="go-yq"
)

# Function to detect architecture
detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        arm64|aarch64) echo "arm64" ;;
        *) echo -e "$(show_status 'error') Unsupported architecture" >&2; return 1 ;;
    esac
}

# detect_distro -> debian | redhat | arch | unknown
# Prefers /etc/os-release (covers Arch, CachyOS and other derivatives), then
# falls back to the classic marker files.
detect_distro() {
    local id="" id_like="" token
    if [[ -r /etc/os-release ]]; then
        id="$(awk -F= '/^ID=/{gsub(/"/,"",$2);print $2}' /etc/os-release 2>/dev/null)"
        id_like="$(awk -F= '/^ID_LIKE=/{gsub(/"/,"",$2);print $2}' /etc/os-release 2>/dev/null)"
    fi
    token="${id} ${id_like}"
    case "$token" in
        *cachyos*|*arch*)                              echo arch;   return 0 ;;
        *debian*|*ubuntu*|*mint*|*pop*)                echo debian; return 0 ;;
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) echo redhat; return 0 ;;
    esac
    [[ -f /etc/arch-release ]]   && { echo arch;   return 0; }
    [[ -f /etc/debian_version ]] && { echo debian; return 0; }
    [[ -f /etc/redhat-release ]] && { echo redhat; return 0; }
    echo unknown
}

# install_cmd_for <distro> -> printable install command (may be empty)
install_cmd_for() {
    case "$1" in
        debian) echo "apt install" ;;
        redhat) echo "dnf install" ;;
        arch)   echo "pacman -S --needed" ;;
        *)      echo "" ;;
    esac
}

# Helper: resolve package for current distro
pkg_for() {
  local bin="$1" distro
  distro="$(detect_distro)"
  case "$distro" in
    redhat) [[ -n "${PKG_RH_OVERRIDE[$bin]:-}" ]]   && { printf '%s' "${PKG_RH_OVERRIDE[$bin]}";   return 0; } ;;
    arch)   [[ -n "${PKG_ARCH_OVERRIDE[$bin]:-}" ]] && { printf '%s' "${PKG_ARCH_OVERRIDE[$bin]}"; return 0; } ;;
  esac
  printf '%s' "${PKG_BASE[$bin]}"
}

# yq is only used by the firewall editor, and it must be mikefarah's v4.
# The `yq` in the Ubuntu/Mint/Debian archives is the incompatible Python v3.
yq_is_v4() {
  command -v yq >/dev/null 2>&1 || return 1
  yq --version 2>/dev/null | grep -qiE 'mikefarah|version v?4\.'
}

# Function to check required packages. Returns 0 when nothing is missing (even
# on an unknown distro) and 1 only when required tools are actually absent.
check_dependencies() {
  [[ "${IGNORE_DEPENDENCY_CHECK:-false}" == true ]] && return 0
  local distro install_cmd
  distro="$(detect_distro)"
  install_cmd="$(install_cmd_for "$distro")"
  local missing=() bin pkg
  for bin in "${!PKG_BASE[@]}"; do
    # optional tools are not startup blockers
    [[ "$bin" == "iperf3" || "$bin" == "yq" ]] && continue
    command -v "$bin" &>/dev/null && continue
    pkg="$(pkg_for "$bin")"
    [[ " ${missing[*]} " == *" $pkg "* ]] || missing+=("$pkg")
  done
  if (( ${#missing[@]} )); then
    log_error "Missing dependencies:"
    printf '  - %s\n' "${missing[@]}" >&2
    if [[ -n "$install_cmd" ]]; then
      echo -e "\nInstall with:\n  ${YELLOW}sudo $install_cmd ${missing[*]}${RESET}" >&2
    else
      echo -e "\nInstall these with your distribution's package manager." >&2
    fi
    return 1
  fi
  return 0
}

###################################################################
####################### Nebula binary mgmt ########################
###################################################################

NEBULA_VERSION=""

# Path to the nebula binary: the configured bin_path if present, else $PATH.
nebula_bin() {
    local bin="${NEBULA_BIN_PATH:-/usr/local/bin}/nebula"
    [[ -x "$bin" ]] || bin="$(command -v nebula 2>/dev/null || true)"
    printf '%s' "$bin"
}

# Function to check installed version of Nebula
check_nebula_installed() {
    # Prefer the configured bin path, but fall back to whatever is on $PATH so a
    # distro-installed nebula (e.g. /usr/bin/nebula) is still recognised.
    local bin; bin="$(nebula_bin)"
    [[ -n "$bin" && -x "$bin" ]] || return 1
    debug_info "Nebula binary: $bin"
    NEBULA_VERSION="$(debug_run_quiet "$bin" --version | grep -i "version" | awk '{print $2}')"
    return 0
}

# Function to check nebula config file for errors
check_nebula_config() {
    local config_file="${1:-${NEBULA_DIR:-/etc/nebula}/config.yml}"
    local filter="${2:-}"
    if [[ ! -f "$config_file" ]]; then
        log_error "Nebula config file not found at $config_file."
        return 1
    fi
    # The config is often owned by the service user (nobody); test a readable copy
    # (asking for elevation with the reason shown when needed).
    local r; r="$(readable_nebula_config "$config_file")" || r=""
    if [[ -z "$r" ]]; then
        log_error "Cannot read Nebula config at $config_file (permission denied)."
        return 1
    fi
    local cfg="$r" tmp=""
    [[ "$cfg" != "$config_file" ]] && tmp="$cfg"
    # Refresh the header cache from this successful read.
    _nebula_info_derive "$cfg" >/dev/null 2>&1 || true

    echo -e "$(show_status 'info') ${CYAN}Testing Nebula config: ${config_file}${RESET}"
    local output status
    # Print separately: command substitution captures stderr, which must stay
    # free of debug lines (it becomes the diagnostic output below).
    debug_print_cmd "$(nebula_bin)" -test -config "$cfg"
    output="$("$(nebula_bin)" -test -config "$cfg" 2>&1)"
    status=$?
    [[ -n "$tmp" ]] && rm -f "$tmp"
    if [[ $status -eq 0 ]]; then
        echo -e "$(show_status 'success') ${GREEN}Nebula config is valid${RESET} $(get_icon 'validate')"
        return 0
    fi
    log_error "Nebula config is invalid. Details:"
    if [[ "$filter" == "error" ]]; then
        echo "$output" | grep -Ei 'error|failed'
    else
        echo -e "    ${YELLOW}$output${RESET}"
    fi
    return 1
}

# Function to get the latest version from GitHub
get_latest_version() {
    local cache_file="/tmp/nebula_latest_version.cache"
    local cache_ttl=$((60 * 60))
    local now ts
    if [[ -f "$cache_file" ]]; then
        ts=$(stat -c %Y "$cache_file" 2>/dev/null)
        now=$(date +%s)
        if (( now - ts < cache_ttl )); then
            cat "$cache_file"
            return 0
        fi
    fi
    local latest_version
    latest_version=$(curl -s "$NEBULA_API_RELEASES_URL" | jq -r ".tag_name")
    latest_version=${latest_version#v}
    [[ -z "$latest_version" || "$latest_version" == "null" ]] && return 1
    echo -n "$latest_version" > "$cache_file"
    echo -n "$latest_version"
}

# Function to compare versions and ask if they want to update
check_for_nebula_update() {
    local installed_version="$NEBULA_VERSION"
    local latest_version
    latest_version="$(get_latest_version)" || { log_warn "Could not determine latest Nebula version."; return; }
    if [[ "$installed_version" == "$latest_version" ]]; then
        log_success "You already have the latest version of Nebula installed ($latest_version)"
    else
        echo -e "$(show_status 'info') ${YELLOW}A newer version of Nebula is available: $latest_version (Installed: $installed_version)${RESET}"
        read -p "$(show_status 'question') Do you want to update Nebula to the latest version? (y/n): " answer
        if [[ "$answer" == "y" ]]; then
            install_nebula "$latest_version"
        else
            IGNORE_NEBULA_UPDATE=true
            log_warn "Update canceled."
        fi
    fi
}

# Function to install a specific version of Nebula from official GitHub repo
install_nebula() {
    local latest_version="${1:-$(get_latest_version)}"
    local os="" arch tmp_dir="/tmp/nebula_install" download_url
    arch="$(detect_arch)" || return 1
    local first_install=false
    check_nebula_installed || first_install=true
    case "$OSTYPE" in
        linux-gnu*) os="linux" ;;
        darwin*) os="darwin" ;;
        msys*) os="windows"; arch="amd64.zip" ;;
        *) log_error "Unsupported OS."; return 1 ;;
    esac
    mkdir -p "$tmp_dir"
    cd "$tmp_dir" || { log_error "Failed to switch to $tmp_dir."; return 1; }
    download_url=$(curl -s "$NEBULA_API_RELEASES_URL" \
        | jq -r ".assets[] | select(.browser_download_url | contains(\"${os}\") and contains(\"${arch}\")) | .browser_download_url")
    if [ -z "$download_url" ]; then
        log_error "Failed to find a matching Nebula release."
        return 1
    fi
    log_info "Downloading Nebula version $latest_version from $download_url..."
    wget -q "$download_url" -O nebula.tar.gz || { log_error "Download failed."; return 1; }
    log_info "Extracting Nebula version $latest_version..."
    if [[ "$os" == "windows" ]]; then
        unzip nebula.tar.gz -d nebula || { log_error "Failed to extract."; return 1; }
    else
        tar -xzf nebula.tar.gz || { log_error "Failed to extract."; return 1; }
    fi
    if [[ ! -x "nebula" || ! -x "nebula-cert" ]]; then
        log_error "Nebula binaries are not executable or missing."
        return 1
    fi
    local backup_dir="/tmp/nebula-temp-backup"
    mkdir -p "$backup_dir"
    for binary in nebula nebula-cert; do
        if [[ -f "${NEBULA_BIN_PATH:-/usr/local/bin}/$binary" ]]; then
            cp "${NEBULA_BIN_PATH:-/usr/local/bin}/$binary" "$backup_dir/$binary.bak"
            log_info "Backed up $binary to $backup_dir/$binary.bak"
        fi
    done
    log_info "Installing Nebula version $latest_version..."
    elevate_why "install the Nebula binaries into ${NEBULA_BIN_PATH:-/usr/local/bin}" mv nebula nebula-cert "${NEBULA_BIN_PATH:-/usr/local/bin}" || { log_error "Failed to move binaries."; return 1; }
    elevate_why "make the Nebula binaries executable" chmod +x "${NEBULA_BIN_PATH:-/usr/local/bin}/nebula" "${NEBULA_BIN_PATH:-/usr/local/bin}/nebula-cert" \
        || { log_error "Failed to set executable permissions."; return 1; }
    if [[ -z "${AUTO_UPDATE:-}" ]]; then
        setup_nebula_config
        setup_nebula_service
    fi
    log_info "Cleaning up temporary files..."
    rm -rf "$tmp_dir"
    log_success "Nebula version $latest_version installed successfully."
    check_nebula_installed
    if [[ "$first_install" == false ]]; then
        restart_nebula_servers
        restore_nebula_backup_if_failed
    fi
    if [[ -z "${AUTO_UPDATE:-}" ]]; then
        banner
        top_header
        main_menu
    fi
}

# Function to restore backup of nebula/nebula-cert if failures happen on upgrade
restore_nebula_backup_if_failed() {
    local backup_dir="/tmp/nebula-temp-backup"
    local has_failure=false failure_flag
    for failure_flag in /tmp/nebula_failed_*; do
        [[ -e "$failure_flag" ]] || continue
        has_failure=true
        break
    done
    if [[ "$has_failure" == true ]]; then
        log_warn "One or more Nebula restarts failed. Restoring previous binaries..."
        for binary in nebula nebula-cert; do
            if [[ -f "$backup_dir/$binary.bak" ]]; then
                elevate mv "${NEBULA_BIN_PATH:-/usr/local/bin}/$binary" "/tmp/${binary}.old"
                elevate cp "$backup_dir/$binary.bak" "${NEBULA_BIN_PATH:-/usr/local/bin}/$binary"
                elevate chmod +x "${NEBULA_BIN_PATH:-/usr/local/bin}/$binary"
                log_success "Restored $binary from backup."
                elevate rm -rf "/tmp/${binary}.old"
            else
                log_error "Backup for $binary not found in $backup_dir"
            fi
        done
        restart_nebula_servers
    else
        log_success "No service failures detected. No need to restore."
    fi
}

# Function to auto update Nebula and restart all servers services
auto_update_nebula() {
    local latest_version
    latest_version="$(get_latest_version)" || { log_error "Could not determine latest Nebula version."; return 1; }
    check_nebula_installed
    if [[ "$NEBULA_VERSION" != "$latest_version" ]]; then
        log_info "Updating Nebula to version $latest_version..."
        install_nebula "$latest_version"
    else
        log_success "Nebula is already at the latest version ($latest_version)"
        return 0
    fi
}

# Function to remove Nebula with confirmation
remove_nebula() {
    echo -e -n "$(show_status 'question') ${RED}Are you sure you want to remove Nebula? This action cannot be undone.${RESET} (y/n): "
    read -p "" confirmation
    if [[ "$confirmation" != "y" ]]; then
        log_warn "Nebula removal canceled"
        return
    fi
    log_info "Removing Nebula..."
    if [[ -f "${NEBULA_BIN_PATH:-/usr/local/bin}/nebula" || -f "${NEBULA_BIN_PATH:-/usr/local/bin}/nebula-cert" ]]; then
        elevate_why "remove the Nebula binaries from ${NEBULA_BIN_PATH:-/usr/local/bin}" rm -f "${NEBULA_BIN_PATH:-/usr/local/bin}/nebula" "${NEBULA_BIN_PATH:-/usr/local/bin}/nebula-cert" \
        && log_success "Nebula removed successfully." \
        || log_error "Failed to remove Nebula binaries."
        remove_nebula_service
        return 0
    else
        log_warn "Nebula is not installed."
    fi
}

# Function to install this script (+ lib/) to bin_path
ensure_installed_to_bin_path() {
    local bindir="${NEBULA_BIN_PATH:-/usr/local/bin}"
    local target="$bindir/nebula-manager"
    local libbase="${NEBULA_MANAGER_LIB_BASE:-$(dirname "$bindir")/lib/nebula-manager}"
    local current_script current_lib
    current_script="$(readlink -f "$0")"
    current_lib="${MANAGER_ROOT:-$(dirname "$current_script")}/lib"

    if [[ "$current_script" == "$target" ]]; then
        log_info "Script is running from $target"
        read -p "$(show_status 'question') Do you want to remove it? [y/N]: " remove_answer
        case "$remove_answer" in
            [yY][eE][sS]|[yY])
                elevate rm -f "$target" && log_success "Removed $target" || log_error "Failed to remove $target"
                ;;
            *) log_info "Keeping installed script." ;;
        esac
        return 0
    fi

    if [[ -f "$target" ]]; then
        log_info "$target already exists but is not this script."
    else
        log_info "Script is not installed at $target"
    fi
    read -p "$(show_status 'question') Do you want to install this script there? [y/N]: " install_answer
    case "$install_answer" in
        [yY][eE][sS]|[yY])
            elevate mkdir -p "$bindir" "$libbase/lib" || { log_error "Failed to create install directories."; return 1; }
            elevate cp "$current_script" "$target" && elevate chmod +x "$target" \
                && log_success "Installed as $target" || log_error "Failed to install to $target"
            if [[ -d "$current_lib" ]]; then
                elevate cp -r "$current_lib/." "$libbase/lib/" \
                    && log_success "Installed modules to $libbase/lib" || log_error "Failed to install modules"
            fi
            ;;
        *) log_info "Skipped installation." ;;
    esac
}

###################################################################
##################### systemd service control #####################
###################################################################
# TODO(pod): today we assume Nebula runs as a host systemd unit (as the
# original tool did). Some users run Nebula inside a container/pod; detect
# that (e.g. `podman ps` / `docker ps` matching nebula) and route
# start/stop/exec through the container runtime instead of systemctl.

# Function to check if the Nebula service is setup
check_nebula_service() {
    local svc="${NEBULA_SERVICE:-nebula.service}"; svc=$(basename "$svc")
    local state
    state=$(systemctl show -p LoadState --value "$svc" 2>/dev/null)
    if [[ "$state" == "loaded" ]]; then
        return 0
    fi
    state=$(systemctl --user show -p LoadState --value "$svc" 2>/dev/null)
    [[ "$state" == "loaded" ]] && return 0
    return 1
}

# Function to set up /etc/nebula and download config.yml template
setup_nebula_config() {
    local config_file="${NEBULA_DIR}/config.yml"
    if [ ! -d "$NEBULA_DIR" ]; then
        log_info "Creating $NEBULA_DIR directory..."
        ensure_dir "$NEBULA_DIR" || { log_error "Failed to create $NEBULA_DIR."; return 1; }
    fi
    if [ ! -f "$config_file" ]; then
        log_info "Downloading Nebula config.yml template..."
        ensure_dir "$(dirname "$config_file")"
        if path_requires_root "$config_file"; then
            elevate wget -q "$NEBULA_TEMPLATE_URL" -O "$config_file" || { log_error "Failed to download config.yml."; return 1; }
        else
            wget -q "$NEBULA_TEMPLATE_URL" -O "$config_file" || { log_error "Failed to download config.yml."; return 1; }
        fi
    else
        log_info "config.yml already exists in $NEBULA_DIR. Skipping template download."
    fi
    safe_chmod 755 "$NEBULA_DIR"
    safe_chmod 644 "$config_file"
    log_success "Nebula configuration setup complete."
}

# Resolve the systemd unit file path for $NEBULA_SERVICE, accepting either an
# absolute path (as in the bundled template) or a bare unit name (as emitted by
# `import`). Bare names map under /etc/systemd/system so we never write a unit
# file into the current working directory.
resolve_service_path() {
    local s="${NEBULA_SERVICE:-nebula.service}"
    if [[ "$s" == */* ]]; then printf '%s' "$s"; else printf '%s' "/etc/systemd/system/$s"; fi
}

# Function to set up Nebula systemd service
setup_nebula_service() {
    local service_path; service_path="$(resolve_service_path)"
    local service_name; service_name=$(basename "$service_path")
    local service_template_url="https://raw.githubusercontent.com/slackhq/nebula/refs/heads/master/examples/service_scripts/nebula.service"
    local nebula_config_path="${NEBULA_DIR}/config.yml"
    if check_nebula_service; then
        log_info "Nebula service already exists. Skipping installation."
        return
    fi
    log_info "Downloading Nebula service file..."
    ensure_dir "$(dirname "$service_path")"
    if path_requires_root "$service_path"; then
        elevate wget -q "$service_template_url" -O "$service_path" || { log_error "Failed to download nebula.service file."; return 1; }
        elevate sed -i "s|/etc/nebula/config.yml|${nebula_config_path}|g" "$service_path"
        elevate chmod 644 "$service_path"
    else
        wget -q "$service_template_url" -O "$service_path" || { log_error "Failed to download nebula.service file."; return 1; }
        sed -i "s|/etc/nebula/config.yml|${nebula_config_path}|g" "$service_path"
        chmod 644 "$service_path"
    fi
    elevate systemctl daemon-reload
    log_info "Enabling Nebula service...(${YELLOW}$service_name${CYAN})${RESET}"
    elevate systemctl enable "$service_name" >/dev/null 2>&1 || { log_error "Failed to enable $service_name"; return; }
    log_warn "Please configure Nebula config file before starting service."
    echo -e "    ${BOLD}${CYAN}Config File:${RESET} ${NEBULA_DIR}/config.yml"
    echo -e "    To start the service go to ${ORANGE}Maintenance${RESET} > ${ORANGE}Toggle Nebula Service${RESET}"
}

# Function to remove Nebula systemd service
remove_nebula_service() {
    local service_name; service_name=$(basename "${NEBULA_SERVICE:-nebula.service}")
    if check_nebula_service; then
        echo -e -n "$(show_status 'question') ${RED}Nebula service found ($service_name). Disable and remove it?${RESET} (y/n): "
        read -p "" confirm
        [[ "$confirm" != "y" ]] && { log_info "Service removal canceled."; return; }
        log_info "Stopping and removing Nebula service..."
        for action in stop disable; do
            elevate systemctl "$action" "$service_name" >/dev/null 2>&1 || log_error "Failed to $action $service_name"
        done
        elevate rm -f "$(resolve_service_path)" && elevate systemctl daemon-reload >/dev/null 2>&1 \
            && log_success "Nebula service ($service_name) successfully removed" \
            || log_error "Failed to remove Nebula service file"
    else
        log_info "No Nebula service found. Nothing to remove"
    fi
}

# Function to restart service with a prompt before doing so
restart_service_prompt() {
    local service_name; service_name=$(basename "${NEBULA_SERVICE:-nebula.service}")
    read -p "$(show_status 'question') Do you want to restart the $service_name? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        if ! check_nebula_config "${NEBULA_DIR}/config.yml"; then
            return
        fi
        log_info "Restarting $service_name service..."
        elevate systemctl restart "$service_name" --no-block
        for _ in {1..10}; do
            systemctl is-active --quiet "$service_name" && { log_success "Nebula service restarted successfully"; return; }
            sleep 1
        done
        log_error "Failed to restart Nebula service"
    else
        log_error "Nebula service restart canceled"
    fi
}

# Function to restart all enabled Nebula servers
restart_nebula_servers() {
    rm -f /tmp/nebula_failed_*
    local -a servers
    mapfile -t servers < <(
        awk '
            { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
            /^[[:space:]]*#/ { next }
            { sub(/[[:space:]]*#.*$/, "") }
            /^[[:space:]]*$/ { next }
            /^\[server\.[^]]+\][[:space:]]*$/ {
                line = $0
                sub(/^\[server\./, "", line)
                sub(/\][[:space:]]*$/, "", line)
                server = line
                next
            }
            /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$/ {
                if (server != "") print server
            }
        ' "$SERVER_CONF"
    )

    local server
    for server in "${servers[@]}"; do
        local SERVER_NAME_TEMP="$server" NEBULA_SERVICE_TEMP NEBULA_DIR_TEMP
        eval "$(
            awk -F= -v s="server.$SERVER_NAME_TEMP" '
                { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
                /^[[:space:]]*#/ { next }
                { sub(/[[:space:]]*#.*$/, "") }
                /^[[:space:]]*$/ { next }
                /^\[server\.[^]]+\]/ {
                    in_server = ($0 == "[" s "]"); next
                }
                in_server && NF == 2 {
                    gsub(/^[ \t]+|[ \t]+$/, "", $1)
                    gsub(/^[ \t]+|[ \t]+$/, "", $2)
                    key = "NEBULA_TEMP_" toupper($1)
                    gsub("-", "_", key)
                    printf "%s=\"%s\"; export %s\n", key, $2, key
                }
            ' "$SERVER_CONF"
        )"
        NEBULA_SERVICE_TEMP="${NEBULA_TEMP_SERVICE:-$GLOBAL_SERVICE}"
        NEBULA_DIR_TEMP="${NEBULA_TEMP_DIR:-$GLOBAL_DIR}"
        local serviceName; serviceName=$(basename "$NEBULA_SERVICE_TEMP")

        if ! check_nebula_config "$NEBULA_DIR_TEMP/config.yml" "error"; then
            touch "/tmp/nebula_failed_${SERVER_NAME_TEMP}"
            continue
        fi
        printf "    ${BOLD}Restarting service for %-20s...${RESET} " "$SERVER_NAME_TEMP"
        if elevate_why "restart the Nebula service ($serviceName)" systemctl restart "$serviceName" &>/dev/null && systemctl is-active --quiet "$serviceName"; then
            echo -e "${GREEN}Success${RESET}"
        else
            touch "/tmp/nebula_failed_${SERVER_NAME_TEMP}"
            echo -e "${RED}Failed${RESET}"
        fi
    done
}

# Function to toggle the Nebula service
toggle_nebula_service() {
    local service_name; service_name=$(basename "$NEBULA_SERVICE")
    check_nebula_config "$NEBULA_DIR/config.yml" || return
    local cur; systemctl is-active --quiet "$service_name" && cur=active || cur=inactive
    log_info "Current state: ${YELLOW}${cur}${RESET}"
    local action target new
    if [[ $cur == active ]]; then action=stop; target=inactive; else action=start; target=active; fi
    echo -ne "$(show_status 'question') ${CYAN}Do you want to ${YELLOW}${action}${CYAN} the service? [y/N]: ${RESET}"
    read -r r
    [[ $r =~ ^[Yy]$ ]] || { log_info "Canceled."; return; }
    if [[ $action == start ]]; then
        elevate_why "start the Nebula service ($service_name)" systemctl start "$service_name" --no-block
    else
        elevate_why "stop the Nebula service ($service_name)" systemctl stop "$service_name"
    fi
    for _ in {1..10}; do
        systemctl is-active --quiet "$service_name" && new=active || new=inactive
        [[ $new == "$target" ]] && break
        sleep 1
    done
    show_system_info
    [[ $new == "$target" ]] || { log_warn "Did not reach expected state '${target}'."; return 1; }
}

# Function to print service status with color
print_service_status() {
    local service_name="$1"
    local status color
    status=$(systemctl is-active "$service_name" 2>/dev/null)
    case "$status" in
        active)        color="${GREEN}" ;;
        activating)    color="${YELLOW}" ;;
        inactive)      color="${GRAY}" ;;
        deactivating)  color="${GRAY}" ;;
        failed)        color="${RED}" ;;
        *)             color="${MAGENTA}" ;;
    esac
    echo -e "${color}${status^}${RESET}"
}

# Interface helpers -------------------------------------------------
iface_from_config() {
    local config_file="$1"
    awk -F: '/^[[:space:]]*dev[[:space:]]*:/ {gsub(/\r|\n/,"",$2);gsub(/^[ \t]+|[ \t]+$/,"",$2);print $2;exit}' "$config_file" 2>/dev/null
}

iface_ip() {
    local iface="$1"
    [[ -z "$iface" ]] && return 1
    ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

iface_is_up() {
    local iface="$1"
    [[ -z "$iface" ]] && return 1
    local link_out addr_out
    link_out="$(ip -o link show "$iface" 2>/dev/null)"
    addr_out="$(ip -o -4 addr show dev "$iface" 2>/dev/null)"
    [[ -n "$link_out" && ( "$link_out" == *UP* || -n "$addr_out" ) ]]
}

# Read a Nebula config file. Files under /etc/nebula are frequently owned by
# the service user (e.g. nobody) and unreadable without elevation, so fall back
# to a passwordless elevated read when possible. Prints nothing on failure.
read_nebula_config() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 1
    if [[ -r "$config_file" ]]; then
        cat "$config_file"
        return 0
    fi
    if is_root || sudo -n true 2>/dev/null; then
        elevate cat "$config_file" 2>/dev/null && return 0
    fi
    # Unreadable and no cached credentials: ask before prompting for a password
    # (skipped when NEBULA_NO_PROMPT=1, e.g. during menu-state detection).
    if [[ "${NEBULA_NO_PROMPT:-0}" != 1 && -t 0 && -t 1 ]] && command -v sudo >/dev/null 2>&1; then
        local a
        read -rp "$(show_status 'question') ${config_file} is service-owned and not readable. Read it once with temporary sudo? [y/N]: " a
        [[ "$a" =~ ^[Yy] ]] && { elevate_why "read the Nebula service config $config_file" cat "$config_file" && return 0; }
    fi
    return 1
}

# Materialise a readable copy of a possibly-privileged config file. Echoes the
# original path when readable, or a temp-file path the caller must delete.
readable_nebula_config() {
    local config_file="$1" tmp
    [[ -f "$config_file" ]] || return 1
    if [[ -r "$config_file" ]]; then printf '%s\n' "$config_file"; return 0; fi
    tmp="$(mktemp)"
    if read_nebula_config "$config_file" > "$tmp" && [[ -s "$tmp" ]]; then
        printf '%s\n' "$tmp"; return 0
    fi
    rm -f "$tmp"; return 1
}

###################################################################
############### Nebula config-derived info cache ##################
###################################################################
# The Nebula config is commonly owned by the service user (e.g. nobody) and is
# not readable by us. Cache the few values the startup header needs in a
# user-owned file, so later runs show them without needing sudo. The cache is
# refreshed whenever the config is read (import, diag, validate) or readable.

nebula_info_cache_file() {
    printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/nebula-manager/system-info"
}

# _nebula_info_save <source_config> <tun> <bind_host> <bind_port> <is_lh>
_nebula_info_save() {
    local cfg="$1" tun="$2" host="$3" port="$4" is_lh="$5"
    local f; f="$(nebula_info_cache_file)"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    {
        printf 'config=%s\n'    "$cfg"
        printf 'tun=%s\n'       "$tun"
        printf 'bind_host=%s\n' "$host"
        printf 'bind_port=%s\n' "$port"
        printf 'is_lh=%s\n'     "$is_lh"
    } > "$f" 2>/dev/null || return 0
}

# _nebula_info_load : populate NEBULA_INFO_* from the cache; 1 if absent/empty.
_nebula_info_load() {
    local f; f="$(nebula_info_cache_file)"
    [[ -f "$f" ]] || return 1
    NEBULA_INFO_CONFIG="" NEBULA_INFO_TUN="" NEBULA_INFO_BIND_HOST=""
    NEBULA_INFO_BIND_PORT="" NEBULA_INFO_IS_LH=""
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            config)    NEBULA_INFO_CONFIG="$v" ;;
            tun)       NEBULA_INFO_TUN="$v" ;;
            bind_host) NEBULA_INFO_BIND_HOST="$v" ;;
            bind_port) NEBULA_INFO_BIND_PORT="$v" ;;
            is_lh)     NEBULA_INFO_IS_LH="$v" ;;
        esac
    done < "$f" 2>/dev/null
    [[ -n "$NEBULA_INFO_TUN" || -n "$NEBULA_INFO_BIND_PORT" || -n "$NEBULA_INFO_IS_LH" ]]
}

# _nebula_info_fresh <config_file> : cache is for THIS config and not older.
_nebula_info_fresh() {
    local cfg="$1" f; f="$(nebula_info_cache_file)"
    [[ -f "$f" ]] || return 1
    local cached_cfg
    cached_cfg="$(awk -F= '$1 == "config" { sub(/^config=/, ""); print; exit }' "$f" 2>/dev/null)"
    [[ "$cached_cfg" == "$cfg" ]] || return 1
    [[ -f "$cfg" ]] || return 0
    local ctm mtm
    ctm="$(stat -c %Y "$cfg" 2>/dev/null)" || return 0
    mtm="$(stat -c %Y "$f" 2>/dev/null)" || return 1
    (( mtm >= ctm ))
}

# _nebula_info_derive <readable_config> : parse the values, refresh the cache,
# and print "tun|bind_host|bind_port|is_lh".
_nebula_info_derive() {
    local cfg="$1" tun host port is_lh
    tun="$(iface_from_config "$cfg")"
    host="$(awk '/listen:/,/port:/{if($1~/^host:/){gsub(/\r|\n|"/,"",$2);print $2}}' "$cfg")"
    port="$(awk '/listen:/,/port:/{if($1~/^port:/){gsub(/\r|\n|"/,"",$2);print $2}}' "$cfg")"
    [[ -z "$host" ]] && host="0.0.0.0"
    if [[ -z "$port" || "$port" == "0" ]]; then
        local _p _s
        read -r _p _s _ < <(resolve_listen_port "$cfg")
        [[ -n "$_p" ]] && port="$_p"
    fi
    if grep -q '^ *am_lighthouse: true' "$cfg"; then is_lh="true"; else is_lh="false"; fi
    _nebula_info_save "$cfg" "$tun" "$host" "$port" "$is_lh"
    printf '%s|%s|%s|%s' "$tun" "$host" "$port" "$is_lh"
}

# Guess the Nebula TUN interface/address from the system (no config needed).
_nebula_iface_guess() {
    command -v ip >/dev/null 2>&1 || return 1
    ip -o -4 addr show 2>/dev/null | awk '
        $2 ~ /^nebula/ && $3 == "inet" { print $2 " " $4; exit }'
}

# Function to show system information related to the Nebula service
show_system_info() {
    local service_name; service_name=$(basename "${NEBULA_SERVICE:-nebula.service}")
    local nebula_config="${NEBULA_DIR:-}/config.yml"

    if ! systemctl is-active --quiet "$service_name"; then
        if check_nebula_installed; then
            echo -e "$(show_status 'error') ${BOLD}${YELLOW}Service: ${RESET}Not Running ($(print_service_status "$service_name"))"
        fi
        return 0
    fi

    echo -e "$(show_status 'success') ${BOLD}${YELLOW}Service: ${RESET}$(print_service_status "$service_name")"
    echo -e "$(show_status 'success') ${BOLD}${YELLOW}Uptime:${RESET} $(date -ud@$(($(date +%s) - $(date -d"$(systemctl show "$service_name" --property=ActiveEnterTimestamp | cut -d'=' -f2)" +%s))) +%T | awk -F: '{print $1" hrs, "$2" min, "$3" sec"}')"

    local tun="" host="" port="" is_lh="" src=""

    # 1) A readable config: use it live and refresh the cache.
    if [[ -n "${NEBULA_DIR:-}" && -f "$nebula_config" && -r "$nebula_config" ]]; then
        local derived; derived="$(_nebula_info_derive "$nebula_config")"
        IFS='|' read -r tun host port is_lh <<< "$derived"
        src="live"
    # 2) Otherwise a fresh cache avoids any privileged read (and any sudo prompt).
    elif _nebula_info_fresh "$nebula_config" && _nebula_info_load; then
        tun="$NEBULA_INFO_TUN"; host="$NEBULA_INFO_BIND_HOST"
        port="$NEBULA_INFO_BIND_PORT"; is_lh="$NEBULA_INFO_IS_LH"; src="cache"
    # 3) A stale cache is still better than nothing, but only for the same config
    #    (multi-server safety: never show another server's values).
    elif _nebula_info_load && [[ "$NEBULA_INFO_CONFIG" == "$nebula_config" ]]; then
        tun="$NEBULA_INFO_TUN"; host="$NEBULA_INFO_BIND_HOST"
        port="$NEBULA_INFO_BIND_PORT"; is_lh="$NEBULA_INFO_IS_LH"; src="cache"
    fi

    if [[ -n "$tun" || -n "$port" || -n "$is_lh" ]]; then
        local ip_addr; ip_addr="$(iface_ip "$tun" 2>/dev/null || true)"
        local note=""
        [[ "$src" == "cache" ]] && note=" ${GRAY}[cached]${RESET}"
        echo -e "$(show_status 'success') ${BOLD}${YELLOW}Network:${RESET} ${ip_addr:-?} - ${tun:-?} (${host:-?}:${port:-?})$note"
        echo -e -n "$(show_status 'success') ${BOLD}${YELLOW}State:${RESET} "
        [[ "$is_lh" == "true" ]] && echo -e "Lighthouse" || echo -e "Client"
        return 0
    fi

    # 4) Last resort: guess the interface/IP from the system (no config needed).
    local guess; guess="$(_nebula_iface_guess)"
    if [[ -n "$guess" ]]; then
        local gif="${guess%% *}" gip="${guess#* }"
        echo -e "$(show_status 'success') ${BOLD}${YELLOW}Network:${RESET} ${gip%%/*} - $gif ${GRAY}(port not shown; see Diagnostics)${RESET}"
        return 0
    fi

    # 5) Nothing available: a notice (not an error) pointing at the in-app action.
    echo -e "$(show_status 'info') ${BOLD}${YELLOW}Network:${RESET} ${GRAY}not shown yet - choose Diagnostics to read the service config once with temporary sudo${RESET}"
    return 0
}

###################################################################
############################## cron ###############################
###################################################################

cron_add() {
    echo -e "$(show_status 'info') ${CYAN}Choose how often to run the Nebula auto-update:${RESET}"
    echo -e "  ${YELLOW}1${RESET}) At boot (${CYAN}@reboot${RESET})"
    echo -e "  ${YELLOW}2${RESET}) Hourly"
    echo -e "  ${YELLOW}3${RESET}) Daily"
    echo -e "  ${YELLOW}4${RESET}) Custom crontab expression"
    read -rp "$(show_status 'question') Enter choice [1-4]: " choice
    local cron_schedule
    case "$choice" in
        1) cron_schedule="@reboot" ;;
        2) cron_schedule="0 * * * *" ;;
        3) cron_schedule="0 0 * * *" ;;
        4) read -rp "$(show_status 'question') Enter custom cron expression: " cron_schedule ;;
        *) log_error "Invalid choice. Aborting."; return 1 ;;
    esac
    local cron_line="$cron_schedule $AUTO_UPDATE_CMD" tmp
    tmp=$(mktemp)
    crontab -l 2>/dev/null > "$tmp" || touch "$tmp"
    if grep -Fq "$AUTO_UPDATE_CMD" "$tmp"; then
        log_warn "Cron entry already exists."
        rm -f "$tmp"
        return 0
    fi
    if [[ -s "$tmp" && -n $(tail -n 1 "$tmp") ]]; then
        echo "" >> "$tmp"
    fi
    { echo "$CRON_COMMENT"; echo "$cron_line"; } >> "$tmp"
    crontab "$tmp"
    rm -f "$tmp"
    log_success "Cron entry added with schedule: ${CYAN}$cron_schedule${RESET}"
}

cron_remove() {
    local tmp
    tmp=$(mktemp)
    crontab -l 2>/dev/null > "$tmp" || touch "$tmp"
    if grep -qF "$CRON_COMMENT" "$tmp"; then
        sed -i "/$(printf '%q' "$CRON_COMMENT")/,+1d" "$tmp"
        crontab "$tmp"
        log_success "Cron entry removed."
    else
        log_warn "No matching cron entry found."
    fi
    rm -f "$tmp"
}

cron_status() {
    if crontab -l 2>/dev/null | grep -qF "$CRON_COMMENT"; then
        log_success "Cron entry for auto-update is present."
    else
        log_warn "Cron entry for auto-update is NOT present."
    fi
}

auto_update_cron_menu() {
    show_menu_header "$MENU_PATH" "Maintenance" "Auto-Update Scheduler"
    echo -e "${ORANGE}Automatically checks for new Nebula releases and updates the installed version if needed.${RESET}"
    echo -e "${BOLD}Cron Job:${RESET} ${YELLOW}$SCRIPT_PATH --auto-update-nebula${RESET}"
    local status_msg cron_present
    if crontab -l 2>/dev/null | grep -qF "$CRON_COMMENT"; then
        status_msg="${GREEN}✔ Present${RESET}"; cron_present=true
    else
        status_msg="${RED}✘ Not Present${RESET}"; cron_present=false
    fi
    echo -e "${BOLD}Cron Status:${RESET} $status_msg"
    local menu_index=1 option_add option_remove option_status option_back
    if [[ "$cron_present" == false ]]; then
        echo -e "        ${BOLD}${YELLOW}${menu_index}.${RESET} $(get_icon 's_success')Add Auto-Update Cron Job"
        option_add=$menu_index; ((menu_index++))
    fi
    if [[ "$cron_present" == true ]]; then
        echo -e "        ${BOLD}${YELLOW}${menu_index}.${RESET} $(get_icon 's_error')Remove Auto-Update Cron Job"
        option_remove=$menu_index; ((menu_index++))
    fi
    echo -e "        ${YELLOW}${BOLD}${menu_index}.${RESET} i Show Cron Status"
    option_status=$menu_index; ((menu_index++))
    echo -e "        ${YELLOW}${BOLD}${menu_index}.${RESET} $(get_icon 'back')${BOLD}Go Back${RESET}"
    option_back=$menu_index
    read -rp "$(show_status 'question') Choose an option [1-$menu_index]: " choice
    case "$choice" in
        $option_add) cron_add ;;
        $option_remove) cron_remove ;;
        $option_status) cron_status ;;
        $option_back) return ;;
        *) log_error "Invalid option." ;;
    esac
    auto_update_cron_menu
}

###################################################################
#################### Config loaders / selection ###################
###################################################################

# System-wide config location (only used when it already exists).
: "${SYSTEM_SERVER_CONF:=/etc/nebula/nebula-manager.conf}"

# Resolve the nebula-manager.conf path (least privilege):
#   --config / $NEBULA_MANAGER_CONF  ->  existing /etc config  ->  per-user config
# The per-user default means a first run never needs root just to get a config.
resolve_server_conf() {
    if [[ -n "${CONF_OVERRIDE:-}" ]]; then
        debug_info "config: --config/NEBULA_MANAGER_CONF -> $CONF_OVERRIDE"
        printf '%s' "$CONF_OVERRIDE"; return 0
    fi
    if [[ -f "$SYSTEM_SERVER_CONF" ]]; then
        debug_info "config: using existing system config -> $SYSTEM_SERVER_CONF"
        printf '%s' "$SYSTEM_SERVER_CONF"; return 0
    fi
    debug_info "config: per-user default -> ${XDG_CONFIG_HOME:-$HOME/.config}/nebula-manager/nebula-manager.conf"
    printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/nebula-manager/nebula-manager.conf"
}

# Locate a bundled config template next to the code (no network required).
find_config_template() {
    local c
    for c in \
        "${MANAGER_LIB_DIR:-}/nebula-manager.conf.template" \
        "${MANAGER_ROOT:-}/lib/nebula-manager.conf.template" \
        "${MANAGER_ROOT:-}/nebula-manager.conf" \
        "${NEBULA_MANAGER_TEMPLATE:-}"
    do
        [[ -n "$c" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# Quick heuristic: does this look like a nebula-manager.conf (not Nebula's config.yml)?
looks_like_manager_conf() {
    grep -qE '^[[:space:]]*\[(global|server\.)' "$1" 2>/dev/null
}

# Count the enabled [server.*] sections in a manager conf. Read-only; uses
# readable_nebula_config so a privileged config is read via the normal guarded
# path (silent when NEBULA_NO_PROMPT=1, e.g. during menu-state detection).
_conf_count_enabled() {
    local f="$1" src
    [[ -f "$f" ]] || { printf '0'; return 0; }
    src="$(readable_nebula_config "$f" 2>/dev/null)" || { printf '0'; return 0; }
    local n
    n="$(awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { next }
        { sub(/[[:space:]]*#.*$/, "") }
        /^[[:space:]]*\[server\.[^]]+\][[:space:]]*$/ { if (insec && enabled) c++; insec=1; enabled=0; next }
        /^[[:space:]]*\[/ { if (insec && enabled) c++; insec=0; enabled=0 }
        insec && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$/ { enabled=1 }
        END { if (insec && enabled) c++; print c+0 }
    ' "$src")"
    [[ "$src" != "$f" ]] && rm -f "$src"
    printf '%s' "$n"
}

# A human-readable, multi-line summary of what nebula-manager can currently see
# on this host: its own config file, whether Nebula is installed/running as a
# systemd unit, and the active certificate workspace. Used as the Setup/TUI
# prompt so the first screen reflects the *detected* state instead of always
# starting from a download. Never prompts (callers set NEBULA_NO_PROMPT=1).
setup_state_summary() {
    local conf; conf="$(resolve_server_conf)"
    local out=""
    if [[ -f "$conf" ]]; then
        if looks_like_manager_conf "$conf"; then
            local n; n="$(_conf_count_enabled "$conf")"
            out+="Config: $conf"
            out+=" ($n server(s) enabled)"
        else
            out+="Config: $conf (no [server.*] entries yet)"
        fi
    else
        out+="Config: none yet ($conf)"
    fi
    out+=$'\n'

    if check_nebula_installed 2>/dev/null; then
        out+="Nebula: installed (v${NEBULA_VERSION:-?})"
        local svc; svc="$(basename "${NEBULA_SERVICE:-nebula.service}")"
        if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$svc" >/dev/null 2>&1; then
            if systemctl is-active --quiet "$svc"; then out+=" - $svc running"; else out+=" - $svc stopped"; fi
        fi
    else
        out+="Nebula: not installed"
    fi
    out+=$'\n'

    local cdir; cdir="$(resolve_cert_dir)"
    if [[ -d "$cdir" ]]; then
        local cc; cc="$(ls "$cdir"/*.crt 2>/dev/null | wc -l | tr -d ' ')"
        out+="Certificates: $cdir ($cc .crt)"
    else
        out+="Certificates: $cdir (missing)"
    fi
    printf '%s' "$out"
}

# install_config_template <dest> [--force] : copy the bundled template (offline).
install_config_template() {
    local dest="$1" force="${2:-}"
    local tpl; tpl="$(find_config_template)" || { log_error "No bundled config template found (looked in ${MANAGER_LIB_DIR:-lib})"; return 1; }
    if [[ -e "$dest" && "$force" != "--force" ]]; then
        log_error "Config already exists: $dest (use --force to overwrite)"
        return 1
    fi
    ensure_dir "$(dirname "$dest")" || return 1
    if path_requires_root "$dest"; then
        elevate_why "write the Nebula Manager config to $dest" cp "$tpl" "$dest"
    else
        cp "$tpl" "$dest" || { log_error "Failed to write $dest"; return 1; }
    fi
    log_success "Created config from local template: $dest"
}

# refresh_config_template [dest] : download the newest template from the repo.
refresh_config_template() {
    local dest="${1:-$(resolve_server_conf)}"
    if [[ -z "${REPO_BASE:-}" ]]; then log_error "Unknown source repo for template refresh."; return 1; fi
    local url="${REPO_BASE}/nebula-manager.conf" tmp
    tmp="$(mktemp)"
    if ! curl -fsSL "$url" -o "$tmp" || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"; log_error "Could not download template from $url"; return 1
    fi
    ensure_dir "$(dirname "$dest")" || { rm -f "$tmp"; return 1; }
    if path_requires_root "$dest"; then
        elevate_why "update the config template at $dest" cp "$tmp" "$dest"
    else
        cp "$tmp" "$dest" || { rm -f "$tmp"; log_error "Failed to write $dest"; return 1; }
    fi
    rm -f "$tmp"
    log_success "Refreshed config from $url"
}

# config_use_file <path> : adopt an existing file as the active nebula-manager.conf
# after validating it really is a manager conf (not Nebula's config.yml).
# Sets CONF_OVERRIDE/SERVER_CONF on success. Returns 1 on invalid input.
config_use_file() {
    local path="$1"
    if [[ -z "$path" || ! -f "$path" ]]; then
        log_error "Not a file: ${path:-<empty>}"
        return 1
    fi
    if ! looks_like_manager_conf "$path"; then
        log_error "$path does not look like a nebula-manager.conf"
        log_info "Expected [global] and/or [server.NAME] sections (Nebula's own config.yml is different)."
        return 1
    fi
    CONF_OVERRIDE="$path"
    SERVER_CONF="$path"
    log_success "Using config: $CONF_OVERRIDE"
    return 0
}

# config remove [--force]
config_remove_cli() {
    local force=0
    while (($#)); do
        case "$1" in
            --force|-f) force=1 ;;
            --config)   shift; CONF_OVERRIDE="${1:-}" ;;
        esac
        shift
    done
    SERVER_CONF="$(resolve_server_conf)"
    if [[ ! -f "$SERVER_CONF" ]]; then log_warn "No config to remove: $SERVER_CONF"; return 0; fi
    if (( force == 0 )); then
        if [[ ! -t 0 ]]; then log_error "Refusing to delete without --force (non-interactive)."; return 1; fi
        local a; read -rp "$(show_status 'question') Delete $SERVER_CONF? [y/N]: " a
        [[ "$a" =~ ^[Yy] ]] || { log_info "Aborted."; return 1; }
    fi
    if path_requires_root "$SERVER_CONF"; then
        elevate_why "delete $SERVER_CONF" rm -f "$SERVER_CONF"
    else
        rm -f "$SERVER_CONF"
    fi
    log_success "Removed $SERVER_CONF"
}

# Headless: nebula-manager config [path|init|refresh]
config_cli() {
    local sub="${1:-path}"; shift || true
    case "$sub" in
        path|show) printf '%s\n' "$SERVER_CONF" ;;
        init|create)
            local force="" dest=""
            while (($#)); do
                case "$1" in
                    --force|-f) force="--force" ;;
                    --config) shift; CONF_OVERRIDE="$1" ;;
                    *) dest="$1" ;;
                esac
                shift
            done
            [[ -n "$dest" ]] && CONF_OVERRIDE="$dest"
            SERVER_CONF="$(resolve_server_conf)"
            install_config_template "$SERVER_CONF" "$force"
            ;;
        refresh|update) refresh_config_template "$SERVER_CONF" ;;
        edit) "${EDITOR:-${VISUAL:-vi}}" "$SERVER_CONF" ;;
        rm|remove|delete) config_remove_cli "$@" ;;
        *) log_error "Unknown 'config' subcommand: $sub (path|init|refresh|edit|remove)"; return 2 ;;
    esac
}

###################################################################
#################### [server.*] management ########################
###################################################################

# Write a prepared file into place (elevating only if the target needs it).
_conf_write() {
    local src="$1"
    if path_requires_root "$SERVER_CONF"; then
        elevate_why "update $SERVER_CONF" cp "$src" "$SERVER_CONF"
    else
        cp "$src" "$SERVER_CONF"
    fi
}

_conf_ensure_exists() {
    [[ -f "$SERVER_CONF" ]] && return 0
    ensure_dir "$(dirname "$SERVER_CONF")" || return 1
    local tmp; tmp="$(mktemp)"
    {
        printf '# nebula-manager.conf (created by "nebula-manager server")\n'
        printf '[global]\n'
        printf 'bin_path=%s\n' "${NEBULA_BIN_PATH:-/usr/local/bin}"
        printf 'cert_dir=%s\n' "$(resolve_cert_dir)"
    } > "$tmp"
    _conf_write "$tmp"; rm -f "$tmp"
}

server_section_exists() {
    [[ -f "$SERVER_CONF" ]] && grep -qF "[server.$1]" "$SERVER_CONF"
}

# server_add_entry <name> [dir] [service] [enabled] [role] [host]
# Adds or replaces the [server.<name>] section in $SERVER_CONF.
server_add_entry() {
    local name="$1" dir="${2:-}" service="${3:-}" enabled="${4:-true}" role="${5:-}" host="${6:-}"
    [[ -n "$name" ]] || { log_error "server name is required"; return 2; }
    _conf_ensure_exists || return 1

    local tmp; tmp="$(mktemp)"
    {
        # keep everything except an existing [server.<name>] section (re-add below)
        awk -v sec="server.$name" '
            /^\[/ { skip = ($0 == "[" sec "]") }
            skip { next }
            { print }
        ' "$SERVER_CONF" 2>/dev/null || true
        printf '\n[server.%s]\n' "$name"
        [[ -n "$dir"     ]] && printf 'dir=%s\n'     "$dir"
        [[ -n "$service" ]] && printf 'service=%s\n' "$service"
        [[ -n "$role"    ]] && printf 'role=%s\n'    "$role"
        [[ -n "$host"    ]] && printf 'host=%s\n'    "$host"
        printf 'enabled=%s\n' "$enabled"
    } > "$tmp"
    if _conf_write "$tmp"; then
        log_success "Added server '${name}' to $SERVER_CONF"
    else
        rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"
}

# server_remove_entry <name>
server_remove_entry() {
    local name="$1"
    server_section_exists "$name" || { log_error "No [server.$name] in $SERVER_CONF"; return 1; }
    local tmp; tmp="$(mktemp)"
    awk -v sec="server.$name" '
        /^\[/ { skip = ($0 == "[" sec "]") }
        skip { next }
        { print }
    ' "$SERVER_CONF" > "$tmp"
    _conf_write "$tmp" && log_success "Removed server '${name}'" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# server_set_enabled <name> <true|false>
server_set_enabled() {
    local name="$1" val="$2"
    server_section_exists "$name" || { log_error "No [server.$name] in $SERVER_CONF"; return 1; }
    local tmp; tmp="$(mktemp)"
    awk -v sec="server.$name" -v val="$val" '
        $0 == "[" sec "]" { insec=1; print; next }
        /^\[/ { if (insec && !set) print "enabled=" val; insec=0 }
        insec && /^[[:space:]]*enabled[[:space:]]*=/ { print "enabled=" val; set=1; next }
        { print }
        END { if (insec && !set) print "enabled=" val }
    ' "$SERVER_CONF" > "$tmp"
    _conf_write "$tmp" && log_success "Set [server.${name}] enabled=${val}" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# Print "name|dir|service|enabled|role|host" for each [server.*] (raw config).
server_entries() {
    local conf_src
    conf_src="$(readable_nebula_config "$SERVER_CONF")" || return 1
    awk '
        /^\[server\./ {
            if (n) print n"|"d"|"sv"|"en"|"ro"|"ho
            n=$0; sub(/^\[server\./,"",n); sub(/\][[:space:]]*$/,"",n)
            d=""; sv=""; en=""; ro=""; ho=""; next
        }
        /^\[/ { if (n) print n"|"d"|"sv"|"en"|"ro"|"ho; n="" }
        /^[[:space:]]*dir[[:space:]]*=/     { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); d=v }
        /^[[:space:]]*service[[:space:]]*=/ { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sv=v }
        /^[[:space:]]*enabled[[:space:]]*=/ { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); en=v }
        /^[[:space:]]*role[[:space:]]*=/    { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); ro=v }
        /^[[:space:]]*host[[:space:]]*=/    { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); ho=v }
        END { if (n) print n"|"d"|"sv"|"en"|"ro"|"ho }
    ' "$conf_src"
    [[ "$conf_src" != "$SERVER_CONF" ]] && rm -f "$conf_src"
    return 0
}

server_list() {
    [[ -f "$SERVER_CONF" ]] || { log_error "No config: $SERVER_CONF"; return 1; }
    local rows; rows="$(server_entries)" || { log_error "Cannot read $SERVER_CONF"; return 1; }
    [[ -n "$rows" ]] || { log_warn "No [server.*] entries in $SERVER_CONF"; return 0; }
    printf '%-20s %-8s %-24s %-24s %s\n' "Name" "Enabled" "Dir" "Service" "Role/Host"
    local n d sv en ro ho
    while IFS='|' read -r n d sv en ro ho; do
        [[ -z "$n" ]] && continue
        printf '%-20s %-8s %-24s %-24s %s\n' "$n" "${en:-?}" "$d" "$sv" "${ro}${ro:+ }${ho}"
    done <<< "$rows"
}

server_add_cli() {
    local name="" dir="" service="" enabled="true" role="" host=""
    while (($#)); do
        case "$1" in
            --dir|-d)     shift; dir="${1:-}" ;;
            --service|-s) shift; service="${1:-}" ;;
            --role)       shift; role="${1:-}" ;;
            --host)       shift; host="${1:-}" ;;
            --enabled)    shift; enabled="${1:-true}" ;;
            --disabled)   enabled="false" ;;
            --config)     shift; CONF_OVERRIDE="${1:-}" ;;
            *)            [[ -z "$name" ]] && name="$1" || log_warn "Ignoring extra argument: $1" ;;
        esac
        shift
    done
    if [[ -z "$name" ]]; then
        echo "Usage: nebula-manager server add NAME [--dir DIR] [--service UNIT] [--role R] [--host H:P] [--disabled]" >&2
        return 2
    fi
    SERVER_CONF="$(resolve_server_conf)"
    [[ -z "$dir" ]]     && { dir="/etc/nebula";            log_warn "Using default dir=$dir (override with --dir)"; }
    [[ -z "$service" ]] && { service="nebula.service";      log_warn "Using default service=$service (override with --service)"; }
    server_add_entry "$name" "$dir" "$service" "$enabled" "$role" "$host"
}

server_remove_cli() {
    local name="${1:-}" sub
    [[ -n "$name" ]] || { echo "Usage: nebula-manager server remove NAME" >&2; return 2; }
    shift || true
    while (($#)); do case "$1" in --config) shift; CONF_OVERRIDE="${1:-}";; esac; shift; done
    SERVER_CONF="$(resolve_server_conf)"
    server_remove_entry "$name"
}

server_toggle_cli() {
    local want="$1"; shift || true
    local name="${1:-}"
    [[ -n "$name" ]] || { echo "Usage: nebula-manager server $want NAME" >&2; return 2; }
    shift || true
    while (($#)); do case "$1" in --config) shift; CONF_OVERRIDE="${1:-}";; esac; shift; done
    SERVER_CONF="$(resolve_server_conf)"
    [[ "$want" == enable ]] && server_set_enabled "$name" true || server_set_enabled "$name" false
}

server_cli() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        add)            server_add_cli "$@" ;;
        list|ls)        SERVER_CONF="$(resolve_server_conf)"; server_list ;;
        remove|rm|del)  server_remove_cli "$@" ;;
        enable)         server_toggle_cli enable "$@" ;;
        disable)        server_toggle_cli disable "$@" ;;
        *) log_error "Unknown 'server' subcommand: $sub (add|list|remove|enable|disable)"; return 2 ;;
    esac
}

# Function to load global variables from conf file
load_global_config() {
    if [[ ! -f "$SERVER_CONF" ]]; then
        return
    fi
    # A system config may be owned by root/service user; read it read-only via a
    # passwordless elevated copy when possible, otherwise fall back to defaults.
    local conf_src="$SERVER_CONF" conf_tmp=""
    if [[ ! -r "$SERVER_CONF" ]]; then
        conf_tmp="$(readable_nebula_config "$SERVER_CONF" 2>/dev/null)" || conf_tmp=""
        if [[ -n "$conf_tmp" && "$conf_tmp" != "$SERVER_CONF" ]]; then
            conf_src="$conf_tmp"
        else
            log_warn "Cannot read $SERVER_CONF (permission denied); using defaults."
            return
        fi
    fi
    eval "$(
        awk -F= '
            { sub(/\r$/, "") }
            /^[ \t]*#/ { next }
            { sub(/[ \t]*#.*$/, "") }
            /^[ \t]*$/ { next }
            /^\[global\]/ { in_global = 1; next }
            /^\[.*\]/ { in_global = 0; next }
            in_global && NF == 2 {
                gsub(/^[ \t]+|[ \t]+$/, "", $1)
                gsub(/^[ \t]+|[ \t]+$/, "", $2)
                key = "GLOBAL_" toupper($1)
                gsub("-", "_", key)
                printf "export %s=\"%s\"\n", key, $2
            }
        ' "$conf_src"
    )"
    [[ -n "$conf_tmp" && "$conf_tmp" != "$SERVER_CONF" ]] && rm -f "$conf_tmp"
    : "${NEBULA_CERT_FOLDER:=${GLOBAL_CERT_FOLDER:-certs}}"
    : "${NEBULA_BIN_PATH:=${GLOBAL_BIN_PATH:-/usr/local/bin}}"
    : "${USE_COLOR:=${GLOBAL_USE_COLOR:-true}}"
    : "${USE_ICONS:=${GLOBAL_USE_ICONS:-true}}"
    : "${DISABLE_VERSION_CHECK:=${GLOBAL_DISABLE_VERSION_CHECK:-false}}"
    : "${IGNORE_DEPENDENCY_CHECK:=${GLOBAL_IGNORE_DEPENDENCY_CHECK:-false}}"
    : "${IGNORE_NEBULA_UPDATE:=${GLOBAL_IGNORE_NEBULA_UPDATE:-false}}"
    # Default Nebula listen port, used by diagnostics when config.yml has
    # `listen.port: 0` (OS-assigned) and auto-detection is unavailable.
    : "${NEBULA_DEFAULT_PORT:=${GLOBAL_DEFAULT_PORT:-4242}}"
    export NEBULA_DEFAULT_PORT
    # Explicit cert workspace in the conf (new key) wins over the legacy cert_folder
    : "${NEBULA_KEYS_DIR:=${GLOBAL_CERT_DIR:-}}"
    export NEBULA_KEYS_DIR
    if [[ "$USE_COLOR" == "false" ]]; then
        local var
        for var in "${NEBULA_COLOR_VARS[@]}"; do
            declare -g "$var="
        done
    fi
}

# Function to load server variables from conf file
load_server_config() {
    local server="$1" conf_src
    conf_src="$(readable_nebula_config "$SERVER_CONF")" || return 1
    eval "$(
        awk -F= -v s="server.$server" '
            { sub(/\r$/, "") }
            /^[ \t]*#/ { next }
            { sub(/[ \t]*#.*$/, "") }
            /^[ \t]*$/ { next }
            /^\[server\.[^]]+\]/ {
                in_server = 0
                section = substr($0, 2, length($0) - 2)
                if (section == s) in_server = 1
                next
            }
            in_server && NF == 2 {
                gsub(/^[ \t]+|[ \t]+$/, "", $1)
                gsub(/^[ \t]+|[ \t]+$/, "", $2)
                key = "NEBULA_" toupper($1)
                gsub("-", "_", key)
                printf "export %s=\"%s\"\n", key, $2
            }
        ' "$conf_src"
    )"
    [[ "$conf_src" != "$SERVER_CONF" ]] && rm -f "$conf_src"
}

# Offer to open a config file in the user's editor (interactive only).
_offer_edit_config() {
    [[ -t 0 && -t 1 ]] || return 0
    local e
    read -rp "$(show_status 'question') Open ${SERVER_CONF} in an editor now? [Y/n]: " e
    [[ "$e" =~ ^[Nn] ]] && return 0
    "${EDITOR:-${VISUAL:-vi}}" "$SERVER_CONF"
}

# Function for server selection
select_nebula_server() {
    if [[ ! -f "$SERVER_CONF" ]]; then
        log_info "No configuration yet at $SERVER_CONF (use Setup / 'import')."
        return 1
    fi

    # The config may be owned by the service user/root; get a readable copy
    # (prompting for sudo if needed) before parsing it.
    local conf_src conf_tmp=""
    if ! conf_src="$(readable_nebula_config "$SERVER_CONF")"; then
        log_error "Cannot read ${CYAN}$SERVER_CONF${RED} (permission denied)."
        log_info "Re-run with sudo, or choose a readable nebula-manager.conf."
        return 1
    fi
    [[ "$conf_src" != "$SERVER_CONF" ]] && conf_tmp="$conf_src"

    local -a servers
    mapfile -t servers < <(
    awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { next }
        { sub(/[[:space:]]*#.*$/, "") }
        /^[[:space:]]*$/ { next }
        /^\[server\.[^]]+\][[:space:]]*$/ {
            line = $0
            sub(/^\[server\./, "", line)
            sub(/\][[:space:]]*$/, "", line)
            server = line
            dir = ""
            next
        }
        /^[[:space:]]*dir[[:space:]]*=/ {
            dir_line = $0
            sub(/^[[:space:]]*dir[[:space:]]*=/, "", dir_line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", dir_line)
            dir = dir_line
            next
        }
        /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$/ {
            print server "\t" dir
        }
    ' "$conf_src"
    )
    [[ -n "$conf_tmp" ]] && rm -f "$conf_tmp"

    if (( ${#servers[@]} == 0 )); then
        log_error "No enabled [server.*] entries in ${CYAN}$SERVER_CONF"
        log_info "This must be a nebula-manager.conf (with [global] and [server.NAME]) - not Nebula's config.yml."
        return 1
    fi

    local s sname
    for s in "${servers[@]}"; do
        sname="${s%%$'\t'*}"
        [[ "$sname" == nebula-example* ]] && {
            log_error "Placeholder server [$sname] found in ${CYAN}$SERVER_CONF${RED} - please replace it with your own servers."
            return 1
        }
    done

    if (( ${#servers[@]} == 1 )); then
        local server_name server_dir
        IFS=$'\t' read -r server_name server_dir <<< "${servers[0]}"
        SELECTED_SERVER="$server_name"
    else
        echo -e "${BOLD}${CYAN}Available Nebula Servers:${RESET}"
        local name_width=$(( $(printf "%s\n" "${servers[@]}" | awk -F'\t' '{print length($1)}' | sort -nr | head -n1) + 6 ))
        local i
        for i in "${!servers[@]}"; do
            local name dir cfg iface status ip_net
            IFS=$'\t' read -r name dir <<< "${servers[i]}"
            cfg="$dir/config.yml"
            iface=""
            ip_net="[${GRAY}N/A${RESET}]"
            [[ -r "$cfg" ]] && iface=$(iface_from_config "$cfg")
            if [[ -n "$iface" ]] && iface_is_up "$iface"; then
                local ip_addr; ip_addr=$(ip addr show "$iface" | grep 'inet ' | awk '{print $2}')
                status="[${GREEN}Active${RESET}]"
                ip_net="[${YELLOW}$ip_addr${RESET}]      "
            else
                status="[${GRAY}Inactive${RESET}]"
            fi
            local color_code; color_code=$(hash_color_256 "$name")
            printf " ${BOLD}${YELLOW}%d.${RESET} \e[38;5;%sm%-*s\e[0m %-*b %b\n" \
                "$((i+1))" "$color_code" "$name_width" "$name" \
                20 "$status" "$ip_net"
        done
        while true; do
            read -p "$(show_status 'question') Choose a server [1-${#servers[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#servers[@]} )); then
                local server_name server_dir
                IFS=$'\t' read -r server_name server_dir <<< "${servers[$((choice-1))]}"
                SELECTED_SERVER="$server_name"
                break
            else
                log_error "Invalid selection."
            fi
        done
    fi

    SERVER_NAME="$SELECTED_SERVER"
    load_server_config "$SERVER_NAME"
    clear
}

###################################################################
################ Self-update / remote resolution ##################
###################################################################
# The update check follows the repo this copy came from, so a fork checks
# itself instead of upstream:
#   $NEBULA_MANAGER_REPO (owner/repo)  ->  git 'origin'  ->  built-in upstream.
# An update is only offered when the published version is strictly NEWER.

_normalize_repo_slug() {
    local url="$1"
    url="${url%.git}"
    url="${url#git@github.com:}"
    url="${url#ssh://git@github.com/}"
    url="${url#https://github.com/}"
    url="${url#http://github.com/}"
    url="${url#github.com/}"
    printf '%s' "$url"
}

manager_remote_repo() {
    if [[ -n "${NEBULA_MANAGER_REPO:-}" ]]; then printf '%s' "$NEBULA_MANAGER_REPO"; return 0; fi
    local url=""
    if [[ -n "${MANAGER_ROOT:-}" && -d "${MANAGER_ROOT}/.git" ]] && command -v git >/dev/null 2>&1; then
        url="$(git -C "$MANAGER_ROOT" remote get-url origin 2>/dev/null)"
    fi
    if [[ -n "$url" ]]; then
        local slug; slug="$(_normalize_repo_slug "$url")"
        case "$slug" in */*) printf '%s' "$slug"; return 0 ;; esac
    fi
    printf '%s' "${NEBULA_MANAGER_DEFAULT_REPO:-jordanhillis/nebula-manager}"
}

manager_remote_ref() { printf '%s' "${NEBULA_MANAGER_REF:-main}"; }

# Populate the *_URL globals (and the version cache) from the resolved repo/ref.
init_remote_urls() {
    local repo ref base safe
    repo="$(manager_remote_repo)"
    ref="$(manager_remote_ref)"
    base="https://raw.githubusercontent.com/${repo}/refs/heads/${ref}"
    safe="$(printf '%s' "$repo" | tr '/' '_')"
    REPO_SLUG="$repo"
    REPO_REF="$ref"
    REPO_BASE="$base"
    SERVER_CONF_URL="${base}/nebula-manager.conf"
    SCRIPT_URL="${base}/nebula-manager"
    VERSION_URL="${base}/latest_version.txt"
    RELEASE_PAGE="https://github.com/${repo}"
    # Key the cache by repo so a fork never reuses upstream's cached version.
    VERSION_CACHE_FILE="/tmp/nebula-manager-version-${safe}.cache"
    export REPO_SLUG REPO_REF REPO_BASE SERVER_CONF_URL SCRIPT_URL VERSION_URL RELEASE_PAGE VERSION_CACHE_FILE
}

# version_gt <a> <b> -> success when a > b (version-sort aware: 1.10 > 1.9)
version_gt() {
    [[ "$1" == "$2" ]] && return 1
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# update_available <local> <remote> -> success only when remote is strictly newer
update_available() { version_gt "$2" "$1"; }

# Install an update. Git checkouts are never auto-clobbered (you may have local
# work); file installs fetch the entrypoint + modules with checksum checking.
perform_manager_update() {
    local latest="$1"
    if [[ -n "${MANAGER_ROOT:-}" && -d "${MANAGER_ROOT}/.git" ]] && command -v git >/dev/null 2>&1; then
        log_warn "This is a git checkout; update it from your remote to preserve local changes:"
        echo -e "    ${CYAN}git -C \"$MANAGER_ROOT\" pull --ff-only${RESET}"
        return 1
    fi

    local tmp; tmp="$(mktemp -d)"
    local entry="$tmp/nebula-manager" sum="$tmp/nebula-manager.sha256"
    curl -fsSL "$SCRIPT_URL" -o "$entry" || { log_error "Download failed."; rm -rf "$tmp"; return 1; }
    curl -fsSL "${SCRIPT_URL}.sha256" -o "$sum" || { log_error "Failed to fetch checksum."; rm -rf "$tmp"; return 1; }
    local expected actual
    expected="$(awk '$2=="nebula-manager"{print $1}' "$sum")"
    actual="$(sha256sum "$entry" | awk '{print $1}')"
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        log_error "Checksum mismatch. Update aborted."
        log_info "Expected: ${expected:-<none>}"
        log_info "Actual:   $actual"
        rm -rf "$tmp"
        return 1
    fi

    mkdir -p "$tmp/lib"
    local m
    for m in ui.sh pki.sh bench.sh system.sh import.sh nebula-manager.conf.template; do
        curl -fsSL "${REPO_BASE}/lib/${m}" -o "$tmp/lib/${m}" \
            || { log_error "Failed to download lib/${m}"; rm -rf "$tmp"; return 1; }
    done

    local target="${SCRIPT_PATH:-$0}" libdir="${MANAGER_LIB_DIR:-}"
    if path_requires_root "$target"; then
        elevate cp "$entry" "$target" && elevate chmod +x "$target"
        [[ -n "$libdir" ]] && elevate cp "$tmp/lib/"* "$libdir/"
    else
        cp "$entry" "$target" && chmod +x "$target"
        [[ -n "$libdir" ]] && cp "$tmp/lib/"* "$libdir/"
    fi
    rm -rf "$tmp"
    log_success "Updated to version v$latest. Please rerun."
    return 0
}

check_script_update() {
  [[ "${DISABLE_VERSION_CHECK:-false}" == true ]] && return
  local now last_check_age latest_version
  now=$(date +%s)
  if [[ -f "$VERSION_CACHE_FILE" ]]; then
    local last_check
    last_check=$(stat -c %Y "$VERSION_CACHE_FILE")
    last_check_age=$(( now - last_check ))
    if (( last_check_age < VERSION_CACHE_TTL_SECONDS )); then
      latest_version=$(cat "$VERSION_CACHE_FILE")
    fi
  fi
  if [[ -z "$latest_version" ]]; then
    latest_version=$(curl -fsSL "$VERSION_URL" 2>/dev/null) || {
      log_info "Could not fetch version info from ${REPO_SLUG:-$VERSION_URL}."
      return
    }
    latest_version="$(printf '%s' "$latest_version" | tr -d '[:space:]')"
    if [[ ! "$latest_version" =~ ^[0-9] ]]; then
      log_info "Unexpected version data from $VERSION_URL."
      return
    fi
    echo "$latest_version" > "$VERSION_CACHE_FILE"
  fi

  if [[ "$latest_version" == "$MANAGER_VERSION" ]]; then
    return
  fi
  if update_available "$MANAGER_VERSION" "$latest_version"; then
    echo -e "$(show_status 'warning') $(get_icon 'package')${YELLOW}Update available for ${BOLD}${ORANGE}Nebula Manager${RESET}${YELLOW}: v$latest_version (you have ${RED}v$MANAGER_VERSION${YELLOW})${RESET}"
    echo -e "$(show_status 'info') $(get_icon 'link')${BLUE}Release notes: $RELEASE_PAGE/releases${RESET}"
    read -rp "$(show_status 'question') Do you want to update to the latest version? [y/N]: " answer
    case "$answer" in
      [Yy]*) perform_manager_update "$latest_version" && exit 0 ;;
      *) log_info "Continuing with current version v$MANAGER_VERSION" ;;
    esac
  else
    # Local build is newer than the published one (fork ahead / stale upstream).
    log_info "Local v$MANAGER_VERSION is newer than ${REPO_SLUG:-remote} v$latest_version; no update needed."
  fi
}

###################################################################
######################## Config / firewall editing #################
###################################################################

manage_firewall() {
    local config_file="$NEBULA_DIR/config.yml"
    [[ -f "$config_file" ]] || { log_error "Config file not found: $config_file"; return 1; }
    if ! yq_is_v4; then
        log_error "The firewall editor requires mikefarah yq v4."
        log_info "Fedora: 'sudo dnf install yq'  |  Arch/CachyOS: 'sudo pacman -S go-yq'"
        log_info "Ubuntu/Mint/Debian: install the upstream binary (docs/linux-distros.md)."
        return 1
    fi
    while true; do
        show_menu_header "$MENU_PATH" "Config" "Firewall"
        echo -e "        ${BOLD}${YELLOW}1.${RESET} $(get_icon 'left-arrow')Configure Inbound Rules ${GREEN}(Default Action: ${RED}$(yq -r ".firewall.inbound_action" "$config_file" 2>/dev/null)${GREEN})${RESET}"
        echo -e "        ${BOLD}${YELLOW}2.${RESET} $(get_icon 'right-arrow')Configure Outbound Rules ${GREEN}(Default Action: ${RED}$(yq -r ".firewall.outbound_action" "$config_file" 2>/dev/null)${GREEN})${RESET}"
        echo -e "        ${BOLD}${YELLOW}3.${RESET} $(get_icon 'security')Configure General Firewall Settings"
        echo -e "        ${BOLD}${YELLOW}4.${RESET} $(get_icon 'back')${BOLD}Go Back${RESET}"
        read -p "$(show_status 'question') Choose an option [1-4]: " choice
        case "$choice" in
            1) configure_inbound_rules ;;
            2) configure_outbound_rules ;;
            3) configure_firewall_settings ;;
            4) break ;;
            *) log_error "Invalid option. Please choose again." ;;
        esac
    done
}

configure_firewall_settings() {
    local config_file="$NEBULA_DIR/config.yml"
    echo -e "\n$(show_status 'info') ${YELLOW}Configuring ${CYAN}general firewall settings${RESET}. Press Enter to skip a setting."
    local key current input
    for key in outbound_action inbound_action; do
        current=$(yq -r ".firewall.$key" "$config_file")
        read -rp "$(printf "${YELLOW}firewall.$key${RESET} [${CYAN}%s${RESET}]: " "$current")" input
        [[ -n "$input" ]] && yq -i -y ".firewall.$key = \"$input\"" "$config_file"
    done
    echo -e "${YELLOW}Edit conntrack timeouts (press Enter to skip):${RESET}"
    for key in tcp_timeout udp_timeout default_timeout; do
        current=$(yq -r ".firewall.conntrack.$key" "$config_file")
        read -rp "$(printf "${YELLOW}firewall.conntrack.$key${RESET} [${CYAN}%s${RESET}]: " "$current")" input
        [[ -n "$input" ]] && yq -i -y ".firewall.conntrack.$key = \"$input\"" "$config_file"
    done
}

configure_inbound_rules() {
    local config_file="$NEBULA_DIR/config.yml"
    local table_width=115
    while true; do
        echo -e "\n${CYAN}Current Inbound Rules:                                                                       ${GREEN}[Default Action: ${RED}$(yq -r ".firewall.inbound_action" "$config_file")${GREEN}]${RESET}"
        printf "${CYAN}%${table_width}s${RESET}\n" | tr ' ' '-'
        printf "${BOLD}${YELLOW} %-4s | %-8s | %-6s | %-15s | %-20s | %-20s | %-20s ${RESET}\n" "Idx" "Port" "Proto" "Host" "Group(s)" "CIDR" "Local CIDR"
        printf "${CYAN}%${table_width}s${RESET}\n" | tr ' ' '-'
        local rule_count i port proto host groups cidr local_cidr
        rule_count=$(yq '.firewall.inbound | length' "$config_file")
        for ((i = 0; i < rule_count; i++)); do
            port=$(yq -r ".firewall.inbound[$i].port // \"any\"" "$config_file")
            proto=$(yq -r ".firewall.inbound[$i].proto // \"any\"" "$config_file")
            host=$(yq -r ".firewall.inbound[$i].host // \"any\"" "$config_file")
            groups=$(yq -r ".firewall.inbound[$i].groups // [] | join(\", \")" "$config_file")
            cidr=$(yq -r ".firewall.inbound[$i].cidr // \"\"" "$config_file")
            local_cidr=$(yq -r ".firewall.inbound[$i].local_cidr // \"\"" "$config_file")
            printf " %-4s | %-8s | %-6s | %-15s | %-20s | %-20s | %-20s \n" \
                "$i" "$port" "$proto" "$host" "$(maxlen "$groups" 20)" "$(maxlen "$cidr" 20)" "$(maxlen "$local_cidr" 20)"
        done
        printf "${CYAN}%${table_width}s${RESET}\n" | tr ' ' '-'
        read -rp "$(show_status 'question') Modify inbound rules? (add/delete/edit/skip): " action
        case "$action" in
            add) _edit_firewall_rule append "$config_file" inbound && log_success "Rule added successfully." ;;
            delete)
                read -rp "Enter rule index to delete: " index
                if [[ "$index" =~ ^[0-9]+$ ]]; then
                    yq -i -y "del(.firewall.inbound[$index])" "$config_file" && log_success "Rule $index deleted successfully."
                else log_error "Invalid index."; fi ;;
            edit)
                read -rp "Enter rule index to edit: " index
                if [[ "$index" =~ ^[0-9]+$ ]]; then
                    _edit_firewall_rule "$index" "$config_file" inbound && log_success "Rule $index edited successfully."
                else log_error "Invalid index."; fi ;;
            skip|*) break ;;
        esac
    done
}

configure_outbound_rules() {
    local config_file="$NEBULA_DIR/config.yml"
    local table_width=115
    while true; do
        echo -e "\n${CYAN}Current Outbound Rules:                                                                       ${GREEN}[Default Action: ${RED}$(yq -r ".firewall.outbound_action" "$config_file")${GREEN}]${RESET}"
        printf "${CYAN}%${table_width}s${RESET}\n" | tr ' ' '-'
        printf "${BOLD}${YELLOW} %-4s | %-8s | %-6s | %-15s | %-20s | %-20s | %-20s ${RESET}\n" "Idx" "Port" "Proto" "Host" "Group(s)" "CIDR" "Local CIDR"
        printf "${CYAN}%${table_width}s${RESET}\n" | tr ' ' '-'
        local rule_count i port proto host groups cidr local_cidr
        rule_count=$(yq '.firewall.outbound | length' "$config_file")
        for ((i = 0; i < rule_count; i++)); do
            port=$(yq -r ".firewall.outbound[$i].port // \"any\"" "$config_file")
            proto=$(yq -r ".firewall.outbound[$i].proto // \"any\"" "$config_file")
            host=$(yq -r ".firewall.outbound[$i].host // \"any\"" "$config_file")
            groups=$(yq -r ".firewall.outbound[$i].groups // [] | join(\", \")" "$config_file")
            cidr=$(yq -r ".firewall.outbound[$i].cidr // \"\"" "$config_file")
            local_cidr=$(yq -r ".firewall.outbound[$i].local_cidr // \"\"" "$config_file")
            printf " %-4s | %-8s | %-6s | %-15s | %-20s | %-20s | %-20s \n" \
                "$i" "$port" "$proto" "$host" "$(maxlen "$groups" 20)" "$(maxlen "$cidr" 20)" "$(maxlen "$local_cidr" 20)"
        done
        printf "${CYAN}%${table_width}s${RESET}\n" | tr ' ' '-'
        read -rp "$(show_status 'question') Modify outbound rules? (add/delete/edit/skip): " action
        case "$action" in
            add) _edit_firewall_rule append "$config_file" outbound && log_success "Rule added successfully." ;;
            delete)
                read -rp "Enter rule index to delete: " index
                if [[ "$index" =~ ^[0-9]+$ ]]; then
                    yq -i -y "del(.firewall.outbound[$index])" "$config_file" && log_success "Rule $index deleted successfully."
                else log_error "Invalid index."; fi ;;
            edit)
                read -rp "Enter rule index to edit: " index
                if [[ "$index" =~ ^[0-9]+$ ]]; then
                    _edit_firewall_rule "$index" "$config_file" outbound && log_success "Rule $index edited successfully."
                else log_error "Invalid index."; fi ;;
            skip|*) break ;;
        esac
    done
}

_edit_firewall_rule() {
    local index="$1" config_file="$2" direction="${3:-inbound}"
    local prefix=".firewall.$direction" is_new=0
    declare -A rule_fields=(
        [port]="Port (e.g. 80, 200-300, any, fragment)"
        [proto]="Protocol (any, tcp, udp, icmp)"
        [host]="Host (e.g. any or hostname)"
        [cidr]="Remote CIDR (e.g. 0.0.0.0/0 or ::/0)"
        [local_cidr]="Local CIDR (e.g. 192.168.1.0/24)"
        [groups]="Groups (comma-separated)"
    )
    if [[ "$index" == "append" ]]; then
        is_new=1
        index=$(yq "$prefix | length" "$config_file")
        yq -i -y "$prefix += [{}]" "$config_file"
    fi
    echo -e "$(show_status 'info') ${YELLOW}Configuring ${CYAN}$direction firewall${RESET}."
    echo -e "${YELLOW}Instructions:${RESET} Press Enter to skip a setting, or enter '-' to delete a field (except for port and proto)."
    local field current input
    for field in port proto host cidr local_cidr; do
        current=$(yq -r "${prefix}[${index}].${field} // \"\"" "$config_file")
        input=""
        while true; do
            printf "${YELLOW}%s${RESET} [${CYAN}%s${RESET}]: " "${rule_fields[$field]}" "$current"
            read input
            if [[ "$is_new" -eq 1 && -z "$input" && ( "$field" == "port" || "$field" == "proto" ) ]]; then
                log_error "${field^} cannot be empty for new rules."; continue
            fi
            [[ -z "$input" ]] && break
            if [[ "$input" == "-" ]]; then
                if [[ "$field" == "port" || "$field" == "proto" ]]; then
                    log_error "Cannot delete required field: $field"; continue
                else
                    yq -i -y "del(${prefix}[${index}].${field})" "$config_file"; break
                fi
            fi
            case "$field" in
                port)  [[ "$input" =~ ^(any|fragment|[0-9]+(-[0-9]+)?)$ ]] && break ;;
                proto) [[ "$input" =~ ^(any|tcp|udp|icmp)$ ]] && break ;;
                host)  [[ "$input" == "any" || "$input" =~ ^[a-zA-Z0-9._-]+$ ]] && break ;;
                cidr|local_cidr) [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$ || "$input" == "::/0" ]] && break ;;
            esac
            log_error "Invalid ${field}. Try again."
        done
        if [[ "$input" == "-" ]]; then
            yq -i -y "del(${prefix}[${index}].${field})" "$config_file"
        elif [[ -n "$input" ]]; then
            yq -i -y "${prefix}[${index}].${field} = \"$input\"" "$config_file"
        fi
    done
    local current_groups; current_groups=$(yq -r "${prefix}[${index}].groups // [] | join(\", \")" "$config_file")
    printf "${YELLOW}%s${RESET} [${CYAN}%s${RESET}]: " "${rule_fields[groups]}" "$current_groups"
    read input
    if [[ "$input" == "-" ]]; then
        yq -i -y "del(${prefix}[${index}].groups)" "$config_file"
    elif [[ -n "$input" ]]; then
        yq -i -y "${prefix}[${index}].groups = []" "$config_file"
        local -a groups; IFS=',' read -ra groups <<< "$input"
        local g
        for g in "${groups[@]}"; do
            g=$(echo "$g" | xargs)
            [[ -n "$g" ]] && yq -i -y "${prefix}[${index}].groups += [\"$g\"]" "$config_file"
        done
    fi
    check_nebula_config "$NEBULA_DIR/config.yml" "error"
    return 0
}

edit_nebula_config() {
    local config_file="${NEBULA_DIR:-/etc/nebula}/config.yml"
    [[ -f "$config_file" ]] || { log_error "Config file not found: $config_file"; return 1; }
    echo -e "$(show_status 'info') ${YELLOW}Configuring ${CYAN}$config_file${RESET}. Press Enter to skip a setting."
    local key current input
    for key in ca cert key disconnect_invalid; do
        current=$(yq -r ".pki.$key" "$config_file")
        read -rp "$(printf "${YELLOW}pki.$key${RESET} [${CYAN}%s${RESET}]: " "$current")" input
        [[ -n "$input" ]] && yq -i -y ".pki.$key = \"$input\"" "$config_file"
    done

    echo -e "${YELLOW}Editing static_host_map entries.${RESET}"
    local -a shm_keys; mapfile -t shm_keys < <(yq -r '.static_host_map | keys[]?' "$config_file")
    if ((${#shm_keys[@]})); then
        echo -e "${CYAN}Current entries:${RESET}"
        local val
        for key in "${shm_keys[@]}"; do
            val=$(yq -r ".static_host_map[\"$key\"][]" "$config_file")
            echo -e "  ${WHITE}$key => $val${RESET}"
        done
        read -rp "$(printf "${YELLOW}Delete static_host_map IPs (comma-separated), or press Enter to skip:${RESET} ")" del_input
        if [[ -n "$del_input" ]]; then
            local -a DEL; IFS=',' read -ra DEL <<< "$del_input"
            local ip trimmed
            for ip in "${DEL[@]}"; do
                trimmed=$(echo "$ip" | xargs)
                yq -i -y "del(.static_host_map.\"$trimmed\")" "$config_file"
            done
            log_success "Deleted specified entries."
        fi
    else
        echo -e "${CYAN}(No current entries)${RESET}"
    fi
    echo -e "${YELLOW}Add new static_host_map entries. Leave internal IP blank to stop.${RESET}"
    local i=1 ip pub port
    while true; do
        read -rp "$(printf "${YELLOW}static_host_map [$i] - internal Nebula IP:${RESET} ")" ip
        [[ -z "$ip" ]] && break
        read -rp "$(printf "${YELLOW}Public IP of $ip:${RESET} ")" pub
        read -rp "$(printf "${YELLOW}Port of $ip:${RESET} ")" port
        [[ -n "$pub" && -n "$port" ]] && yq -i -y ".static_host_map.\"$ip\" = [\"$pub:$port\"]" "$config_file"
        ((i++))
    done

    for key in am_lighthouse interval; do
        current=$(yq -r ".lighthouse.$key" "$config_file")
        read -rp "$(printf "${YELLOW}lighthouse.$key${RESET} [${CYAN}%s${RESET}]: " "$current")" input
        [[ -n "$input" ]] && yq -i -y ".lighthouse.$key = $input" "$config_file"
    done

    echo -e "${YELLOW}Editing lighthouse.hosts list.${RESET}"
    local -a current_hosts; mapfile -t current_hosts < <(yq -r '.lighthouse.hosts[]?' "$config_file")
    if ((${#current_hosts[@]})); then
        echo -e "${CYAN}Current lighthouse.hosts:${RESET}"
        for i in "${!current_hosts[@]}"; do
            echo -e "  [${i}] ${WHITE}${current_hosts[i]}${RESET}"
        done
        read -rp "$(printf "${YELLOW}Enter indices to delete (comma-separated), or press Enter to skip:${RESET} ")" del_input
        if [[ -n "$del_input" ]]; then
            local -a del_indices new_hosts; IFS=',' read -ra del_indices <<< "$del_input"
            new_hosts=()
            local skip d
            for i in "${!current_hosts[@]}"; do
                skip=false
                for d in "${del_indices[@]}"; do [[ "$i" -eq "$d" ]] && skip=true && break; done
                $skip || new_hosts+=("${current_hosts[i]}")
            done
            yq -i -y '.lighthouse.hosts = []' "$config_file"
            local host
            for host in "${new_hosts[@]}"; do yq -i -y ".lighthouse.hosts += [\"$host\"]" "$config_file"; done
        fi
    else
        echo -e "${CYAN}(No current entries)${RESET}"
    fi
    read -rp "$(printf "${YELLOW}Add lighthouse host IPs (comma-separated), or press Enter to skip:${RESET} ")" input
    if [[ -n "$input" ]]; then
        local -a HOSTS trimmed_h; IFS=',' read -ra HOSTS <<< "$input"
        local host trimmed
        for host in "${HOSTS[@]}"; do
            trimmed=$(echo "$host" | xargs)
            [[ -n "$trimmed" ]] && yq -i -y ".lighthouse.hosts += [\"$trimmed\"]" "$config_file"
        done
    fi

    for key in host port; do
        current=$(yq -r ".listen.$key" "$config_file")
        read -rp "$(printf "${YELLOW}listen.$key${RESET} [${CYAN}%s${RESET}]: " "$current")" input
        [[ -n "$input" ]] && yq -i -y ".listen.$key = \"$input\"" "$config_file"
    done

    current=$(yq -r ".punchy.punch" "$config_file")
    read -rp "$(printf "${YELLOW}punchy.punch${RESET} [${CYAN}%s${RESET}]: " "$current")" input
    [[ -n "$input" ]] && yq -i -y ".punchy.punch = $input" "$config_file"

    current=$(yq -r ".relay.am_relay" "$config_file")
    read -rp "$(printf "${YELLOW}relay.am_relay${RESET} [${CYAN}%s${RESET}]: " "$current")" input
    [[ -n "$input" ]] && yq -i -y ".relay.am_relay = $input" "$config_file"

    current=$(yq -r ".relay.use_relays" "$config_file")
    read -rp "$(printf "${YELLOW}relay.use_relays${RESET} [${CYAN}%s${RESET}]: " "$current")" input
    [[ -n "$input" ]] && yq -i -y ".relay.use_relays = $input" "$config_file"

    echo -e "${YELLOW}Editing relay.relays list.${RESET}"
    local -a current_relays; mapfile -t current_relays < <(yq -r '.relay.relays[]?' "$config_file")
    if ((${#current_relays[@]})); then
        echo -e "${CYAN}Current relay.relays:${RESET}"
        for i in "${!current_relays[@]}"; do
            echo -e "  [${i}] ${WHITE}${current_relays[i]}${RESET}"
        done
        read -rp "$(printf "${YELLOW}Enter indices to delete (comma-separated), or press Enter to skip:${RESET} ")" del_input
        if [[ -n "$del_input" ]]; then
            local -a del_indices new_relays; IFS=',' read -ra del_indices <<< "$del_input"
            new_relays=()
            local skip d
            for i in "${!current_relays[@]}"; do
                skip=false
                for d in "${del_indices[@]}"; do [[ "$i" -eq "$d" ]] && skip=true && break; done
                $skip || new_relays+=("${current_relays[i]}")
            done
            yq -i -y '.relay.relays = []' "$config_file"
            local relay
            for relay in "${new_relays[@]}"; do yq -i -y ".relay.relays += [\"$relay\"]" "$config_file"; done
        fi
    fi
    read -rp "$(printf "${YELLOW}Add relay IPs (comma-separated), or press Enter to skip:${RESET} ")" input
    if [[ -n "$input" ]]; then
        local -a RELAYS; IFS=',' read -ra RELAYS <<< "$input"
        local relay trimmed
        for relay in "${RELAYS[@]}"; do
            trimmed=$(echo "$relay" | xargs)
            [[ -n "$trimmed" ]] && yq -i -y ".relay.relays += [\"$trimmed\"]" "$config_file"
        done
    fi

    current=$(yq -r ".tun.dev" "$config_file")
    read -rp "$(printf "${YELLOW}tun.dev${RESET} [${CYAN}%s${RESET}]: " "$current")" input
    [[ -n "$input" ]] && yq -i -y ".tun.dev = \"$input\"" "$config_file"

    log_success "Finished updating ${CYAN}$config_file${RESET}."
    check_nebula_config "$NEBULA_DIR/config.yml" "error"
}

manage_configuration() {
    dynamic_menu_title=("$MENU_PATH" "Configuration Management")
    dynamic_menu_options=("$(get_icon 'validate')Validate Config" "$(get_icon 'configuration')Edit Config" "$(get_icon 'firewall')Edit Firewall")
    dynamic_menu_functions=("check_nebula_config \"$NEBULA_DIR/config.yml\" \"error\"" "edit_nebula_config" "manage_firewall")
    dynamic_menu dynamic_menu_title dynamic_menu_options dynamic_menu_functions 1
}
