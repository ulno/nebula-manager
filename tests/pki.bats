#!/usr/bin/env bats
#
# tests/pki.bats - BATS mirror of the core unprivileged-PKI guarantees.
# Run by ./run_tests.sh when `bats` is installed.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export HOME="$SANDBOX/home"
    export XDG_DATA_HOME="$SANDBOX/xdg-data"
    export XDG_CONFIG_HOME="$SANDBOX/xdg-config"
    export USE_COLOR=false USE_ICONS=false NEBULA_UI=plain
    mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$SANDBOX/bin"

    # Mocked sudo: record invocations, never do privileged work.
    export SUDO_LOG="$SANDBOX/sudo.log"
    : > "$SUDO_LOG"
    cat > "$SANDBOX/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${SUDO_LOG:?}"
exit 0
MOCK
    chmod +x "$SANDBOX/bin/sudo"
    export PATH="$SANDBOX/bin:$PATH"

    NM="$REPO_ROOT/nebula-manager"
    KEYS="$SANDBOX/keys"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "version prints the tool name" {
    run "$NM" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nebula Manager v"* ]]
}

@test "help prints usage" {
    run "$NM" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "paths resolves the default per-user cert dir" {
    run "$NM" paths
    [ "$status" -eq 0 ]
    [[ "$output" == *"cert-dir:  $XDG_DATA_HOME/nebula-manager/keys"* ]]
}

@test "CA creation and signing work without root and without sudo" {
    command -v nebula-cert >/dev/null 2>&1 || skip "nebula-cert not installed"

    run "$NM" ca --name bats-ca --cert-dir "$KEYS"
    [ "$status" -eq 0 ]
    [ -f "$KEYS/ca.crt" ]
    [ -f "$KEYS/ca.key" ]

    run "$NM" sign --name bats-node --ip 10.5.5.5/24 --cert-dir "$KEYS"
    [ "$status" -eq 0 ]
    [ -f "$KEYS/bats-node.crt" ]
    [ -f "$KEYS/bats-node.key" ]

    # least-privilege: the mocked sudo log must be empty
    [ ! -s "$SUDO_LOG" ]
}
