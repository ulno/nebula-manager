#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/store.sh - certificate-store history, backups and optional git tracking
# ===========================================================================
# Every write to a certificate workspace is recorded in
#   <cert-dir>/nebula-manager.log
# and, before an overwrite/removal, the old files are preserved using one of:
#
#   * git mode: the store is inside a git work tree -> pending certificate
#     changes are committed first (private keys are always ignored/staged-out);
#   * folder mode: otherwise a datestamped folder
#       <cert-dir>/backups/<YYYYmmdd-HHMMSS>-<reason>/
#     with the old files (mode 600) and ACTION.txt.
#
# Private keys are never committed: the gitignore/staging list excludes *.key.
# Nothing here needs root for a user-owned store.

CERT_STORE_LOG_NAME="nebula-manager.log"
_CERT_STORE_GIT_HINT="${_CERT_STORE_GIT_HINT:-0}"
_CERT_STORE_LOG_WARNED="${_CERT_STORE_LOG_WARNED:-0}"
CERT_STORE_LAST_SNAPSHOT="${CERT_STORE_LAST_SNAPSHOT:-}"

cert_store_log_file() {
    printf '%s/%s' "${1:-$(resolve_cert_dir)}" "$CERT_STORE_LOG_NAME"
}

cert_store_is_git() {
    local dir="${1:-$(resolve_cert_dir)}"
    command -v git >/dev/null 2>&1 || return 1
    [[ -d "$dir" ]] || return 1
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# cert_store_log <dir> <message...> ; append one audit line (never fails hard).
cert_store_log() {
    local dir="$1"; shift
    [[ -d "$dir" ]] || return 0
    local logf line user host
    logf="$(cert_store_log_file "$dir")"
    user="$(id -un 2>/dev/null || echo unknown)"
    host="$(hostname 2>/dev/null || echo unknown)"
    printf -v line '%s user=%s host=%s %s' "$(date -Is 2>/dev/null || date)" "$user" "$host" "$*"
    [[ -n "${NEBULA_MANAGER_CMDLINE:-}" ]] && line+=" cmd=\"$NEBULA_MANAGER_CMDLINE\""
    line="${line//$'\n'/ }"
    if ! printf '%s\n' "$line" >> "$logf" 2>/dev/null; then
        if declare -F elevate >/dev/null; then
            printf '%s\n' "$line" | elevate tee -a "$logf" >/dev/null 2>&1 || true
        fi
        if (( ! _CERT_STORE_LOG_WARNED )); then
            log_warn "Could not write the certificate-store log at $logf."
            _CERT_STORE_LOG_WARNED=1
        fi
        return 0
    fi
    chmod 600 "$logf" 2>/dev/null || true
    return 0
}

# Ensure a nested .gitignore protects secrets and derived files.
cert_store_ensure_gitignore() {
    local dir="$1" gi="$dir/.gitignore" p
    [[ -d "$dir" ]] || return 1
    local -a pats=( "*.key" "backups/" "*.crt.bak" "*.zip" "*.tar.gz" "*.png" )
    for p in "${pats[@]}"; do
        if [[ ! -f "$gi" ]] || ! grep -qxF "$p" "$gi" 2>/dev/null; then
            printf '%s\n' "$p" >> "$gi" || return 1
        fi
    done
    return 0
}

# cert_store_git_commit_pending <dir> <reason>
# Commit whatever changed in the store *before* the next mutation. Returns 0
# when the old state is safely in git (including "already clean"), 1 when git
# is unavailable/unusable so the caller should fall back to a folder backup.
cert_store_git_commit_pending() {
    local dir="$1" reason="$2"
    command -v git >/dev/null 2>&1 || return 1
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    cert_store_ensure_gitignore "$dir" || true

    # A local identity keeps automatic snapshots working without touching the
    # user's global git configuration.
    git -C "$dir" config user.name  >/dev/null 2>&1 || git -C "$dir" config user.name  "nebula-manager" >/dev/null 2>&1
    git -C "$dir" config user.email >/dev/null 2>&1 || git -C "$dir" config user.email "nebula-manager@localhost" >/dev/null 2>&1

    # Stage the store subtree, never private keys or backup folders.
    if ! git -C "$dir" add -A -- . ':(exclude)*.key' ':(exclude)backups/**' >/dev/null 2>&1; then
        ( cd "$dir" && git add -- '*.crt' '.gitignore' "$CERT_STORE_LOG_NAME" >/dev/null 2>&1 ) || return 1
    fi
    if git -C "$dir" diff --cached --quiet >/dev/null 2>&1; then
        return 0
    fi
    git -C "$dir" commit -q -m "nebula-manager: pre-change snapshot ($reason)" >/dev/null 2>&1 || return 1
    return 0
}

# cert_store_make_backup_dir <dir> <reason> [files...]
# Copy the listed files (default: all certs/keys/public keys) into a datestamped
# folder with ACTION.txt. Prints the folder path. Returns 0 even when there is
# nothing to copy (a log line is still written by the caller).
cert_store_make_backup_dir() {
    local dir="$1" reason="$2"; shift 2
    local -a files=()
    local f
    if (( $# )); then
        for f in "$@"; do [[ -f "$f" ]] && files+=("$f"); done
    else
        for f in "$dir"/*.crt "$dir"/*.key "$dir"/*.pub; do
            [[ -f "$f" ]] && files+=("$f")
        done
    fi
    (( ${#files[@]} )) || return 0

    local stamp slug bdir seq base
    stamp="$(date +%Y%m%d-%H%M%S)"
    slug="$(printf '%s' "$reason" | tr -cs 'A-Za-z0-9_.-' '-' | sed 's/^-//;s/-$//')"
    mkdir -p "$dir/backups" 2>/dev/null || { log_warn "Could not create $dir/backups"; return 1; }
    # Sequence per timestamp (not per reason) so names stay sortable when several
    # backups are created within the same second. mkdir is the atomic claim.
    seq="$(find "$dir/backups" -mindepth 1 -maxdepth 1 -type d -name "${stamp}-*" 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$seq" =~ ^[0-9]+$ ]] || seq=0
    while :; do
        bdir="$dir/backups/${stamp}-$(printf '%03d' "$seq")${slug:+-$slug}"
        if mkdir "$bdir" 2>/dev/null; then break; fi
        seq=$((seq + 1))
    done
    chmod 700 "$bdir" 2>/dev/null || true

    local copied=0
    for f in "${files[@]}"; do
        base="$(basename "$f")"
        if cp -p "$f" "$bdir/$base" 2>/dev/null; then
            chmod 600 "$bdir/$base" 2>/dev/null || true
            copied=$((copied + 1))
        else
            log_warn "Could not back up $f"
        fi
    done
    {
        printf 'time: %s\n'   "$(date -Is 2>/dev/null || date)"
        printf 'user: %s\n'   "$(id -un 2>/dev/null || echo unknown)"
        printf 'host: %s\n'   "$(hostname 2>/dev/null || echo unknown)"
        printf 'reason: %s\n' "$reason"
        printf 'source: %s\n' "$dir"
        [[ -n "${NEBULA_MANAGER_CMDLINE:-}" ]] && printf 'command: %s\n' "$NEBULA_MANAGER_CMDLINE"
        printf 'files (%d):\n' "$copied"
        for f in "${files[@]}"; do printf '  %s\n' "$(basename "$f")"; done
    } > "$bdir/ACTION.txt" 2>/dev/null || true
    chmod 600 "$bdir/ACTION.txt" 2>/dev/null || true
    printf '%s' "$bdir"
}

# cert_store_snapshot_before <dir> <reason> [files...]
# Preserve the old state before a mutation. Sets CERT_STORE_LAST_SNAPSHOT to
# "git" or the backup folder path (empty when there was nothing to preserve).
cert_store_snapshot_before() {
    local dir="${1:-$(resolve_cert_dir)}" reason="${2:-change}"; shift 2
    [[ -d "$dir" ]] || return 0
    if [[ ! -w "$dir" ]]; then
        log_warn "Certificate store $dir is not writable; cannot record a backup."
        return 1
    fi

    local -a files=()
    local f
    if (( $# )); then
        for f in "$@"; do [[ -f "$f" ]] && files+=("$f"); done
    else
        for f in "$dir"/*.crt "$dir"/*.key "$dir"/*.pub; do
            [[ -f "$f" ]] && files+=("$f")
        done
    fi

    CERT_STORE_LAST_SNAPSHOT=""
    if (( ${#files[@]} == 0 )); then
        cert_store_log "$dir" "snapshot reason=\"$reason\" mode=none files=0"
        return 0
    fi

    local mode="" path="" is_git=0
    cert_store_is_git "$dir" && is_git=1
    if (( is_git )) && cert_store_git_commit_pending "$dir" "$reason"; then
        mode="git"; path="git"
    else
        if (( is_git )); then
            log_warn "Git snapshot failed for $dir; writing a folder backup instead."
        fi
        mode="folder"
        path="$(cert_store_make_backup_dir "$dir" "$reason" "${files[@]}")" || path=""
        if (( ! is_git && ! _CERT_STORE_GIT_HINT )); then
            log_warn "Tip: track certificate history in git: nebula-manager cert store git-init --cert-dir \"$dir\""
            _CERT_STORE_GIT_HINT=1
        fi
    fi
    CERT_STORE_LAST_SNAPSHOT="$path"
    cert_store_log "$dir" "snapshot reason=\"$reason\" mode=$mode path=\"${path:-none}\" files=${#files[@]}"
    return 0
}

cert_store_status() {
    local dir="${1:-$(resolve_cert_dir)}"
    if [[ ! -d "$dir" ]]; then
        printf 'Certificate store: %s (missing)\n' "$dir"
        return 1
    fi
    printf 'Certificate store: %s\n' "$dir"
    if cert_store_is_git "$dir"; then
        local top pending
        top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")"
        pending="$(git -C "$dir" status --porcelain 2>/dev/null | grep -c . || true)"
        printf 'VCS:               git (%s, %s pending change(s))\n' "$top" "${pending:-0}"
    else
        printf 'VCS:               none\n'
    fi
    local logf lines
    logf="$(cert_store_log_file "$dir")"
    if [[ -f "$logf" ]]; then
        lines="$(wc -l < "$logf" 2>/dev/null | tr -d ' ')"
        printf 'Action log:        %s (%s line(s))\n' "$logf" "${lines:-0}"
    else
        printf 'Action log:        %s (not created yet)\n' "$logf"
    fi
    local n=0 latest=""
    if [[ -d "$dir/backups" ]]; then
        n="$(find "$dir/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
        latest="$(find "$dir/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)"
    fi
    printf 'Backup folders:    %s%s\n' "${n:-0}" "${latest:+ (latest: $latest)}"
}

# cert_store_git_init <dir> ; create/complete a local repo (keys stay ignored).
cert_store_git_init() {
    local dir="${1:-$(resolve_cert_dir)}"
    command -v git >/dev/null 2>&1 || { log_error "git is not installed."; return 1; }
    mkdir -p "$dir" 2>/dev/null || { log_error "Cannot create $dir"; return 1; }
    if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if ! git -C "$dir" init -q 2>/dev/null; then
            log_error "git init failed for $dir"
            return 1
        fi
        log_success "Initialized a git repository in $dir"
    fi
    cert_store_ensure_gitignore "$dir" || { log_error "Could not write $dir/.gitignore"; return 1; }
    git -C "$dir" config user.name  >/dev/null 2>&1 || git -C "$dir" config user.name  "nebula-manager" >/dev/null 2>&1
    git -C "$dir" config user.email >/dev/null 2>&1 || git -C "$dir" config user.email "nebula-manager@localhost" >/dev/null 2>&1

    cert_store_log "$dir" "git-init dir=\"$dir\""
    if ! git -C "$dir" add -A -- . ':(exclude)*.key' ':(exclude)backups/**' >/dev/null 2>&1; then
        ( cd "$dir" && git add -- '*.crt' '.gitignore' "$CERT_STORE_LOG_NAME" >/dev/null 2>&1 ) || true
    fi
    if ! git -C "$dir" diff --cached --quiet >/dev/null 2>&1; then
        if git -C "$dir" commit -q -m "nebula-manager: initial certificate store snapshot" >/dev/null 2>&1; then
            log_success "Committed the current certificates (private keys are ignored)."
        else
            log_warn "Could not create the initial commit; check 'git -C \"$dir\" status'."
        fi
    else
        log_info "Nothing new to commit - the store is already tracked."
    fi
    return 0
}

cert_store_menu() {
    local dir; dir="$(resolve_cert_dir)"
    ensure_cert_dir >/dev/null || return 1
    local choice logf text
    while true; do
        cert_store_status "$dir"
        choice="$(ui_menu "Certificate store" "History, backups and optional git tracking for $dir:" \
            snapshot "Snapshot now (git commit, or a datestamped backup folder)" \
            gitinit  "Initialize git (private keys are ignored)" \
            log      "Show the action log" \
            back     "Go back")" || return 0
        case "$choice" in
            snapshot)
                cert_store_snapshot_before "$dir" "manual" || true
                if [[ "${CERT_STORE_LAST_SNAPSHOT:-}" == "git" ]]; then
                    log_success "Committed pending certificate changes (or nothing to commit)."
                elif [[ -n "${CERT_STORE_LAST_SNAPSHOT:-}" ]]; then
                    log_success "Backup written: $CERT_STORE_LAST_SNAPSHOT"
                else
                    log_info "Nothing to snapshot."
                fi
                ;;
            gitinit) cert_store_git_init "$dir" ;;
            log)
                logf="$(cert_store_log_file "$dir")"
                if [[ -f "$logf" ]]; then
                    text="$(tail -n 200 "$logf" 2>/dev/null)"
                    ui_textbox "Certificate store log" "$text"
                else
                    log_info "No log yet at $logf."
                fi
                ;;
            back) break ;;
        esac
    done
}

# Headless CLI: nebula-manager cert store status|log|backup|git-init
cert_store_cli() {
    local sub="${1:-status}"; shift || true
    local dir="" reason="manual" n=50
    while (( $# )); do
        case "$1" in
            --cert-dir)   shift; dir="${1:-}" ;;
            --cert-dir=*) dir="${1#*=}" ;;
            --reason)     shift; reason="${1:-manual}" ;;
            --reason=*)   reason="${1#*=}" ;;
            -n|--lines)   shift; n="${1:-50}" ;;
            -h|--help)
                echo "Usage: nebula-manager cert store status|log|backup|git-init [--cert-dir DIR]" >&2
                echo "  status    store path, git state, log size and backup count" >&2
                echo "  log [-n N]  show the action log (default 50 lines)" >&2
                echo "  backup [--reason TEXT]  snapshot now (git commit or backup folder)" >&2
                echo "  git-init  create a local repo; private keys and backups are ignored" >&2
                return 0 ;;
            *) log_error "Unknown option for 'cert store $sub': $1"; return 2 ;;
        esac
        shift
    done
    dir="${dir:-$(resolve_cert_dir)}"
    case "$sub" in
        status) cert_store_status "$dir" ;;
        log)
            local logf; logf="$(cert_store_log_file "$dir")"
            [[ -f "$logf" ]] || { log_warn "No log yet at $logf."; return 1; }
            tail -n "$n" "$logf" ;;
        backup)
            cert_store_snapshot_before "$dir" "$reason" || return 1
            if [[ "${CERT_STORE_LAST_SNAPSHOT:-}" == "git" ]]; then
                log_success "Git snapshot complete (pending certificate changes committed)."
            elif [[ -n "${CERT_STORE_LAST_SNAPSHOT:-}" ]]; then
                printf '%s\n' "$CERT_STORE_LAST_SNAPSHOT"
            else
                log_info "Nothing to snapshot."
            fi ;;
        git-init) cert_store_git_init "$dir" ;;
        *) log_error "Unknown 'cert store' subcommand: $sub"; return 2 ;;
    esac
}
