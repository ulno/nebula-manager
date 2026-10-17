#!/usr/bin/env bash
# Test: distro detection and per-distro package name mapping (Arch/CachyOS, etc).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="distro & package mapping"
harness_init

# Real detection on the test host should never be 'unknown' (Arch/CachyOS here).
assert_ne "detect_distro identifies the host" "$(detect_distro)" "unknown"

# --- install command mapping ---
assert_eq "debian install cmd"   "$(install_cmd_for debian)"  "apt install"
assert_eq "redhat install cmd"   "$(install_cmd_for redhat)"  "dnf install"
assert_eq "arch install cmd"     "$(install_cmd_for arch)"    "pacman -S --needed"
assert_eq "unknown install cmd"  "$(install_cmd_for unknown)" ""

# --- package mapping via stubbed distro ---
detect_distro() { echo debian; }
assert_eq "debian ping package" "$(pkg_for ping)" "iputils-ping"
detect_distro() { echo redhat; }
assert_eq "redhat ping package" "$(pkg_for ping)" "iputils"
detect_distro() { echo arch; }
assert_eq "arch ping package"     "$(pkg_for ping)"     "iputils"
assert_eq "arch whiptail package" "$(pkg_for whiptail)" "libnewt"
assert_eq "arch yq package"       "$(pkg_for yq)"       "go-yq"
assert_eq "arch awk uses default" "$(pkg_for awk)"      "gawk"

# --- yq v4 detection (firewall editor requirement) ---
cat > "$SANDBOX/bin/yq" <<'MOCK'
#!/usr/bin/env bash
echo "yq (https://github.com/mikefarah/yq/) version v4.44.1"
MOCK
chmod +x "$SANDBOX/bin/yq"
if yq_is_v4; then _ok "mikefarah yq v4 recognised"; else _bad "mikefarah yq v4 recognised"; fi
printf '#!/usr/bin/env bash\necho "yq 3.1.0"\n' > "$SANDBOX/bin/yq"; chmod +x "$SANDBOX/bin/yq"
if yq_is_v4; then _bad "python yq v3 rejected"; else _ok "python yq v3 rejected"; fi
rm -f "$SANDBOX/bin/yq"

# --- a missing dependency on arch -> exit 1 + pacman hint ---
PKG_BASE[frobnicate]="frobnicate-tool"
out="$(check_dependencies 2>&1)"; rc=$?
assert_eq "missing dependency returns 1" "$rc" "1"
assert_contains "arch install hint shown" "$out" "pacman -S --needed"
assert_contains "missing package named"   "$out" "frobnicate-tool"
unset 'PKG_BASE[frobnicate]'

# --- restore real detection: with all deps present -> exit 0 (no hard fail) ---
unset -f detect_distro
if check_dependencies >/dev/null 2>&1; then _ok "host deps present -> 0"; else _bad "host deps present -> 0"; fi

harness_summary
