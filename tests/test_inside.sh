#!/bin/bash
# =============================================================================
# test_inside.sh — Assertion suite (runs INSIDE Docker container)
# =============================================================================
set -uo pipefail

# ── Terminal colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; SKIP=0
FAILURES=()

# ── Helpers ───────────────────────────────────────────────────────────────────
pass() { echo -e "  ${GREEN}PASS${NC}  $1"; (( PASS++ )); }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; (( FAIL++ )); FAILURES+=("$1"); }
skip() { echo -e "  ${YELLOW}SKIP${NC}  $1"; (( SKIP++ )); }
section() { echo -e "\n${BOLD}${CYAN}▶ $1${NC}"; }

assert_file_exists() {
    local desc="$1" path="$2"
    [[ -f "$path" ]] && pass "$desc" || fail "$desc (missing: $path)"
}

assert_file_contains() {
    local desc="$1" path="$2" pattern="$3"
    if [[ ! -f "$path" ]]; then
        fail "$desc (file not found: $path)"
    elif grep -qF "$pattern" "$path" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc (pattern not found: '$pattern' in $path)"
    fi
}

assert_file_not_contains() {
    local desc="$1" path="$2" pattern="$3"
    if [[ ! -f "$path" ]]; then
        fail "$desc (file not found: $path)"
    elif ! grep -qF "$pattern" "$path" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc (should NOT contain: '$pattern' in $path)"
    fi
}

assert_dir_exists() {
    local desc="$1" path="$2"
    [[ -d "$path" ]] && pass "$desc" || fail "$desc (missing dir: $path)"
}

assert_mock_called() {
    local desc="$1" log="$2" pattern="$3"
    if [[ ! -f "$log" ]]; then
        fail "$desc (mock log not found: $log)"
    elif grep -qF "$pattern" "$log" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc (mock log has no: '$pattern')"
    fi
}

assert_exit_ok() {
    local desc="$1"; shift
    if "$@"; then
        pass "$desc"
    else
        fail "$desc (exited $?)"
    fi
}

# ── Source Ubuntu version ─────────────────────────────────────────────────────
# shellcheck source=/dev/null
source /etc/os-release
UBUNTU_VERSION="$VERSION_ID"

echo -e "\n${BOLD}Ubuntu RDP Setup — Test Suite${NC}"
echo    "Container OS: Ubuntu $UBUNTU_VERSION"

# =============================================================================
# PRE-FLIGHT: syntax check
# =============================================================================
section "Syntax check"
assert_exit_ok "setup_rdp.sh has valid bash syntax" bash -n /opt/setup_rdp.sh

# =============================================================================
# RUN SETUP (--no-tunnel mode, mocks in PATH)
# =============================================================================
section "Running setup_rdp.sh --no-tunnel"

export PATH="/usr/local/bin/mock_bins:$PATH"
# Clear old mock logs
rm -f /tmp/mock_*.log

if bash /opt/setup_rdp.sh --no-tunnel 2>&1 | tee /tmp/setup_output.log; then
    pass "setup_rdp.sh exited 0"
else
    fail "setup_rdp.sh exited non-zero (see /tmp/setup_output.log)"
fi

# =============================================================================
# WAYLAND CONFIGURATION
# =============================================================================
section "Wayland disabled in GDM"
assert_file_contains \
    "GDM config has WaylandEnable=false" \
    "/etc/gdm3/custom.conf" \
    "WaylandEnable=false"

assert_file_not_contains \
    "GDM config has no commented WaylandEnable" \
    "/etc/gdm3/custom.conf" \
    "#WaylandEnable=false"

# =============================================================================
# XRDP CONFIGURATION
# =============================================================================
section "xrdp configuration"
assert_file_exists "xrdp.ini exists"          "/etc/xrdp/xrdp.ini"
assert_file_contains "xrdp.ini port=3389"     "/etc/xrdp/xrdp.ini" "port=3389"
assert_file_contains "xrdp.ini TLS enabled"   "/etc/xrdp/xrdp.ini" "security_layer=tls"
assert_file_exists   "xrdp.ini.bak created"   "/etc/xrdp/xrdp.ini.bak"

# =============================================================================
# GNOME SESSION SCRIPT
# =============================================================================
section "GNOME session (startwm.sh)"
assert_file_exists   "startwm.sh exists"       "/etc/xrdp/startwm.sh"
assert_file_exists   "startwm.sh.bak created"  "/etc/xrdp/startwm.sh.bak"
assert_file_contains "startwm.sh: XDG_SESSION_TYPE=x11" \
    "/etc/xrdp/startwm.sh" "XDG_SESSION_TYPE=x11"
assert_file_contains "startwm.sh: GNOME env set" \
    "/etc/xrdp/startwm.sh" "GNOME_SHELL_SESSION_MODE=ubuntu"
assert_file_contains "startwm.sh: unset DBUS" \
    "/etc/xrdp/startwm.sh" "unset DBUS_SESSION_BUS_ADDRESS"
assert_file_contains "startwm.sh: unset XDG_RUNTIME_DIR" \
    "/etc/xrdp/startwm.sh" "unset XDG_RUNTIME_DIR"
assert_file_contains "startwm.sh: gnome-session call" \
    "/etc/xrdp/startwm.sh" "gnome-session"

# Version-specific session flag
if [[ "$UBUNTU_VERSION" == "22.04" ]]; then
    assert_file_contains "startwm.sh: --session=ubuntu (22.04)" \
        "/etc/xrdp/startwm.sh" "--session=ubuntu"
fi

# =============================================================================
# POLKIT RULES
# =============================================================================
section "PolicyKit rules"
assert_file_exists "polkit rules.d file exists" \
    "/etc/polkit-1/rules.d/02-xrdp-colord.rules"
assert_file_contains "polkit rules.d: color-manager action" \
    "/etc/polkit-1/rules.d/02-xrdp-colord.rules" \
    "org.freedesktop.color-manager.create-device"
assert_file_contains "polkit rules.d: returns YES" \
    "/etc/polkit-1/rules.d/02-xrdp-colord.rules" \
    "polkit.Result.YES"

assert_file_exists "polkit .pkla file exists" \
    "/etc/polkit-1/localauthority/50-local.d/45-xrdp-colord.pkla"
assert_file_contains "polkit .pkla: ResultActive=yes" \
    "/etc/polkit-1/localauthority/50-local.d/45-xrdp-colord.pkla" \
    "ResultActive=yes"

# =============================================================================
# FIREWALL (mock verification)
# =============================================================================
section "UFW firewall (mock)"
assert_mock_called "ufw: SSH allowed" \
    "/tmp/mock_ufw.log" "allow ssh"
assert_mock_called "ufw: RDP port from localhost" \
    "/tmp/mock_ufw.log" "3389"

# =============================================================================
# SERVICE MANAGEMENT (mock verification)
# =============================================================================
section "systemctl calls (mock)"
assert_mock_called "systemctl: xrdp enabled" \
    "/tmp/mock_systemctl.log" "enable xrdp"
assert_mock_called "systemctl: xrdp restarted" \
    "/tmp/mock_systemctl.log" "restart xrdp"
assert_mock_called "systemctl: daemon-reload" \
    "/tmp/mock_systemctl.log" "daemon-reload"

# =============================================================================
# NO-TUNNEL mode: cloudflared NOT called
# =============================================================================
section "Cloudflare tunnel skipped in --no-tunnel mode"
if [[ -f /tmp/mock_cloudflared.log ]]; then
    fail "cloudflared should not be called in --no-tunnel mode"
else
    pass "cloudflared was NOT called (correct)"
fi

# =============================================================================
# RUN SETUP with tunnel mocks
# =============================================================================
section "Running setup_rdp.sh --hostname test.example.com (tunnel mode)"
rm -f /tmp/mock_*.log

# Pre-create cloudflared cert file that login would create
mkdir -p ~/.cloudflared
echo '{}' > ~/.cloudflared/mock-cert.pem
echo '[{"id":"aaaabbbb-cccc-dddd-eeee-000011112222","name":"ubuntu-rdp"}]' \
    > /tmp/tunnel_list.json

if bash /opt/setup_rdp.sh --hostname test.example.com 2>&1 | tee /tmp/setup_tunnel_output.log; then
    pass "setup_rdp.sh (tunnel mode) exited 0"
else
    fail "setup_rdp.sh (tunnel mode) exited non-zero (see /tmp/setup_tunnel_output.log)"
fi

# Cloudflared config file
assert_file_exists   "cloudflared config.yml created" \
    "/etc/cloudflared/config.yml"
assert_file_contains "config.yml: correct hostname" \
    "/etc/cloudflared/config.yml" "test.example.com"
assert_file_contains "config.yml: tcp ingress" \
    "/etc/cloudflared/config.yml" "tcp://localhost:3389"
assert_file_contains "config.yml: tunnel name" \
    "/etc/cloudflared/config.yml" "tunnel: ubuntu-rdp"

# Mock calls
assert_mock_called "cloudflared: tunnel login called" \
    "/tmp/mock_cloudflared.log" "tunnel login"
assert_mock_called "cloudflared: tunnel create called" \
    "/tmp/mock_cloudflared.log" "tunnel create"
assert_mock_called "cloudflared: dns route set" \
    "/tmp/mock_cloudflared.log" "tunnel route dns"
assert_mock_called "systemctl: cloudflared enabled" \
    "/tmp/mock_systemctl.log" "enable cloudflared"

# UFW: RDP restricted to localhost in tunnel mode
assert_mock_called "ufw: RDP restricted to 127.0.0.1 in tunnel mode" \
    "/tmp/mock_ufw.log" "from 127.0.0.1"

# =============================================================================
# SUMMARY
# =============================================================================
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}PASS${NC}: $PASS   ${RED}FAIL${NC}: $FAIL   ${YELLOW}SKIP${NC}: $SKIP"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo -e "\n${RED}Failed tests:${NC}"
    for f in "${FAILURES[@]}"; do
        echo -e "  • $f"
    done
fi

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
