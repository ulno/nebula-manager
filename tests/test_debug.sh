#!/usr/bin/env bash
# Test: DEBUG modes (warn/log/info/learn/all).
# Verifies that debug output never pollutes stdout and that DEBUG=learn prints
# the exact Nebula CLI commands before they run.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="DEBUG modes"
harness_init

ERR="$SANDBOX/debug.err"
: > "$ERR"

# --- default (log) ----------------------------------------------------------
out="$(debug_run echo hi 2>"$ERR")"
assert_eq "default: command still runs" "$out" "hi"
assert_empty_file "default: no learn output" "$ERR"

out="$(DEBUG=log log_info "normal message" 2>"$ERR")"
assert_contains "log: info still shown" "$out" "normal message"
assert_empty_file "log: nothing on stderr" "$ERR"

# --- learn ------------------------------------------------------------------
out="$(DEBUG=learn debug_run echo hi 2>"$ERR")"
assert_eq "learn: stdout stays clean" "$out" "hi"
assert_contains "learn: prints command" "$(cat "$ERR")" "[learn] echo hi"

# A command with spaces must be quoted unambiguously.
out="$(DEBUG=learn debug_run printf '%s\n' "two words" 2>"$ERR")"
assert_eq "learn: quoted command runs" "$out" "two words"
assert_contains "learn: quotes arguments" "$(cat "$ERR")" "two\\ words"

DEBUG=learn debug_run false 2>/dev/null
assert_eq "learn: preserves the command exit status" "$?" "1"

# --- warn -------------------------------------------------------------------
out="$(DEBUG=warn log_info "chatter" 2>"$ERR")"
assert_eq "warn: hides log_info" "$out" ""
out="$(DEBUG=warn log_success "chatter" 2>"$ERR")"
assert_eq "warn: hides log_success" "$out" ""
out="$(DEBUG=warn log_warn "careful" 2>"$ERR")"
assert_eq "warn: warning stays on stderr" "$out" ""
assert_contains "warn: warning is shown" "$(cat "$ERR")" "careful"

# --- comma-separated levels -------------------------------------------------
out="$(DEBUG=warn,learn log_info "quiet chatter" 2>"$ERR")"
assert_eq "warn,learn: info still hidden" "$out" ""
DEBUG=warn,learn debug_print_cmd echo mixed-cmd 2>"$ERR"
assert_contains "warn,learn: commands still shown" "$(cat "$ERR")" "[learn] echo mixed-cmd"

# Elevated actions are shown too (sudo wrapper).
DEBUG=learn elevate true 2>"$ERR"
assert_contains "learn: elevated command shown" "$(cat "$ERR")" "[learn] sudo true"

# --- info / all -------------------------------------------------------------
out="$(DEBUG=info debug_info "resolved detail" 2>"$ERR")"
assert_eq "info: detail goes to stderr only" "$out" ""
assert_contains "info: detail is shown" "$(cat "$ERR")" "[debug] resolved detail"

out="$(DEBUG=log debug_info "hidden detail" 2>"$ERR")"
assert_empty_file "log: no info details" "$ERR"

out="$(DEBUG=all debug_info "all detail" 2>"$ERR")"
assert_contains "all: includes info" "$(cat "$ERR")" "[debug] all detail"
DEBUG=all debug_print_cmd echo all-cmd 2>"$ERR"
assert_contains "all: includes learn" "$(cat "$ERR")" "[learn] echo all-cmd"

# --- unknown level: warn once, keep working ---------------------------------
out="$(DEBUG=bogus debug_run echo still-works 2>"$ERR")"
assert_eq "unknown level: command runs" "$out" "still-works"
assert_contains "unknown level: warns" "$(cat "$ERR")" "unknown DEBUG level"

# --- Nebula CLI calls are routed through learn ------------------------------
FAKEBIN="$SANDBOX/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/nebula-cert" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "print" && "${2:-}" == "-json" ]]; then
    printf '%s\n' '{"details":{"name":"fake","isCa":false,"ips":[],"groups":[],"subnets":[],"notBefore":"2026-01-01T00:00:00Z","notAfter":"2036-01-01T00:00:00Z"},"fingerprint":"abc"}'
fi
# Emulate the real tool's output files so signing can be verified.
out=""; key=""
while (($#)); do
    case "$1" in
        -out-crt) shift; out="${1:-}" ;;
        -out-key) shift; key="${1:-}" ;;
    esac
    shift
done
[[ -n "$out" ]] && printf 'FAKE CERT\n' > "$out"
[[ -n "$key" ]] && printf 'FAKE KEY\n' > "$key"
exit 0
FAKE
cat > "$FAKEBIN/nebula" <<'FAKE'
#!/usr/bin/env bash
echo "Version: v9.9.9"
exit 0
FAKE
chmod +x "$FAKEBIN/nebula-cert" "$FAKEBIN/nebula"
export NEBULA_BIN_PATH="$FAKEBIN"

# JSON capture: the learn line must be on stderr, the JSON on stdout.
json="$(DEBUG=learn nebula_cert_json "$FAKEBIN" "$SANDBOX/fake.crt" 2>"$ERR")"
assert_contains "learn: JSON command shown" "$(cat "$ERR")" "nebula-cert print -json"
assert_contains "learn: JSON output stays parseable" "$json" '"name": "fake"'
assert_not_contains "learn: debug line not in JSON stdout" "$json" "[learn]"

# CA creation and signing print the command.
out="$(CERT_DIR="$SANDBOX/pki" CA_NAME="dbg-ca" DEBUG=learn pki_ca_create 2>"$ERR")"
assert_contains "learn: CA command shown" "$(cat "$ERR")" "nebula-cert ca -name dbg-ca"
assert_contains "learn: CA success still logged" "$out" "CA generated"

mkdir -p "$SANDBOX/pki"
: > "$SANDBOX/pki/ca.crt"
: > "$SANDBOX/pki/ca.key"
out="$(CERT_DIR="$SANDBOX/pki" SIGN_NAME="node1" SIGN_IP="10.9.9.2/24" \
    DEBUG=learn pki_sign 2>"$ERR")"
assert_contains "learn: sign command shown" "$(cat "$ERR")" "nebula-cert sign -name node1 -ip 10.9.9.2/24"
assert_contains "learn: sign success still logged" "$out" "Certificate signed"

# Version probe: command shown, value captured cleanly.
DEBUG=learn check_nebula_installed 2>"$ERR"
assert_eq "learn: version captured cleanly" "$NEBULA_VERSION" "v9.9.9"
assert_contains "learn: version command shown" "$(cat "$ERR")" "nebula --version"

# --- --debug flag and env var ----------------------------------------------
NM="$REPO_ROOT/nebula-manager"
out="$(DEBUG= "$NM" --debug=learn paths 2>"$ERR")"
assert_contains "--debug=learn: paths still on stdout" "$out" "cert-dir:"
assert_contains "--debug=learn: details on stderr" "$(cat "$ERR")" "[debug] cert-dir:"
assert_not_contains "--debug=learn: no debug on stdout" "$out" "[debug]"

out="$(DEBUG=learn "$NM" paths 2>"$ERR")"
assert_contains "DEBUG=learn env: details on stderr" "$(cat "$ERR")" "[debug]"

out="$(DEBUG= "$NM" --learn paths 2>"$ERR")"
assert_contains "--learn selects the learn level" "$out" "debug:     learn"
assert_contains "--learn includes info details" "$(cat "$ERR")" "[debug]"

out="$(DEBUG= "$NM" -l paths 2>"$ERR")"
assert_contains "-l selects the learn level" "$out" "debug:     learn"

harness_summary
