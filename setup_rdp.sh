#!/bin/bash
# =============================================================================
# Ubuntu RDP Setup Script with Cloudflare Tunnel
# =============================================================================
# Supports  : Ubuntu 22.04 (Jammy) / Ubuntu 24.04 (Noble)
# Desktop   : GNOME (existing installation)
# Auth      : PAM - existing Ubuntu user accounts
# Access    : Cloudflare Tunnel (no port forwarding required)
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}──── $* ────${NC}"; }

# ── Globals ───────────────────────────────────────────────────────────────────
UBUNTU_VERSION=""
TUNNEL_NAME="ubuntu-rdp"
RDP_PORT=3389
CF_HOSTNAME=""         # e.g. rdp.example.com  (set via --hostname flag)
TUNNEL_TOKEN=""        # set via --token flag (non-interactive)
SKIP_TUNNEL=false      # --no-tunnel: UFW-only mode
POWER_MODE=""          # --power disable-sleep | wol | none  (default: ask)

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --hostname <host>   Cloudflare hostname for RDP       (e.g. rdp.example.com)
  --tunnel-name <n>   Cloudflare tunnel name             (default: ubuntu-rdp)
  --token <token>     Cloudflare tunnel token            (non-interactive mode)
  --port <port>       Local RDP port                     (default: 3389)
  --no-tunnel         Skip Cloudflare; open UFW port only
  --power <mode>      Power management mode:
                        disable-sleep  Mask all sleep/suspend targets (safe for
                                       always-on desktops plugged into AC)
                        wol            Enable Wake-on-LAN so the machine can be
                                       woken remotely; does NOT disable sleep
                        none           Skip power management setup
                      (default: interactive prompt)
  -h, --help          Show this help

Examples:
  # Interactive setup with Cloudflare Tunnel
  sudo $0 --hostname rdp.example.com

  # Non-interactive (CI/automated) using existing tunnel token
  sudo $0 --hostname rdp.example.com --token <cf_tunnel_token>

  # UFW-only mode (manual port forwarding required)
  sudo $0 --no-tunnel

EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hostname)    CF_HOSTNAME="$2";    shift 2 ;;
            --tunnel-name) TUNNEL_NAME="$2";    shift 2 ;;
            --token)       TUNNEL_TOKEN="$2";   shift 2 ;;
            --port)        RDP_PORT="$2";       shift 2 ;;
            --no-tunnel)   SKIP_TUNNEL=true;    shift ;;
            --power)       POWER_MODE="$2";     shift 2 ;;
            -h|--help)     usage ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
}

# =============================================================================
# 1. PREREQUISITE CHECKS
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Run as root:  sudo $0"
        exit 1
    fi
}

check_ubuntu() {
    [[ -f /etc/os-release ]] || { log_error "Cannot detect OS"; exit 1; }
    # shellcheck source=/dev/null
    source /etc/os-release

    [[ "$ID" == "ubuntu" ]] || { log_error "Ubuntu only (detected: $ID)"; exit 1; }

    UBUNTU_VERSION="$VERSION_ID"
    case "$UBUNTU_VERSION" in
        22.04|24.04) log_ok "Ubuntu $UBUNTU_VERSION detected" ;;
        *) log_error "Unsupported version: $UBUNTU_VERSION (need 22.04 or 24.04)"; exit 1 ;;
    esac
}

check_gnome() {
    if dpkg -l gnome-shell 2>/dev/null | grep -q "^ii"; then
        log_ok "GNOME Shell is installed"
    else
        log_warn "GNOME Shell not found – installing ubuntu-desktop-minimal..."
        apt-get install -y ubuntu-desktop-minimal gnome-shell
    fi
}

# =============================================================================
# 2. PACKAGE INSTALLATION
# =============================================================================
install_xrdp() {
    log_step "Installing xrdp"

    apt-get update -q

    local pkgs=(xrdp dbus-x11 xauth)

    # xorgxrdp improves performance; optional – skip if unavailable
    if apt-cache show xorgxrdp &>/dev/null; then
        pkgs+=(xorgxrdp)
    fi

    # PulseAudio xrdp module for audio (optional)
    if apt-cache show pulseaudio-module-xrdp &>/dev/null; then
        pkgs+=(pulseaudio-module-xrdp)
    fi

    apt-get install -y "${pkgs[@]}"
    log_ok "xrdp installed"
}

# =============================================================================
# 3. WAYLAND → X11
# =============================================================================
disable_wayland() {
    log_step "Forcing X11 (disabling Wayland)"

    local gdm_conf="/etc/gdm3/custom.conf"
    [[ -f "$gdm_conf" ]] || { log_warn "GDM config not found – skipping"; return; }

    cp "$gdm_conf" "${gdm_conf}.bak"

    # Ensure [daemon] section exists
    if ! grep -q "^\[daemon\]" "$gdm_conf"; then
        echo -e "\n[daemon]" >> "$gdm_conf"
    fi

    # Set WaylandEnable=false
    if grep -q "^WaylandEnable=" "$gdm_conf"; then
        sed -i 's/^WaylandEnable=.*/WaylandEnable=false/' "$gdm_conf"
    elif grep -q "^#WaylandEnable=" "$gdm_conf"; then
        sed -i 's/^#WaylandEnable=.*/WaylandEnable=false/' "$gdm_conf"
    else
        sed -i '/^\[daemon\]/a WaylandEnable=false' "$gdm_conf"
    fi

    log_ok "Wayland disabled in GDM"
}

# =============================================================================
# 4. GNOME SESSION FOR XRDP
# =============================================================================
configure_gnome_session() {
    log_step "Configuring GNOME session for xrdp"

    cp /etc/xrdp/startwm.sh /etc/xrdp/startwm.sh.bak

    # Re-read VERSION_ID directly from os-release inside this function.
    # Avoids relying on the $UBUNTU_VERSION global which may be shadowed
    # by variables exported during apt-get postinst scripts.
    local ver
    ver=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}")

    local session_cmd="exec gnome-session"
    [[ "$ver" == "22.04" ]] && session_cmd="exec gnome-session --session=ubuntu"
    log_info "Session command: $session_cmd  (detected ver=$ver)"

    # Write the static header with a quoted heredoc (no variable expansion).
    cat > /etc/xrdp/startwm.sh <<'STATIC'
#!/bin/sh
# xrdp GNOME session startup – generated by setup_rdp.sh

# Load locale
if [ -r /etc/default/locale ]; then
    . /etc/default/locale
    export LANG LANGUAGE LC_ALL LC_MESSAGES
fi

# Clear variables that cause session conflicts
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
unset SESSION_MANAGER

# Force X11 backend
export XDG_SESSION_TYPE=x11
export GDK_BACKEND=x11

# GNOME environment
export XDG_SESSION_DESKTOP=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export GNOME_SHELL_SESSION_MODE=ubuntu

# Start GNOME
if command -v gnome-session >/dev/null 2>&1; then
STATIC

    # Append the version-specific session launcher (dynamic, written via printf).
    printf '    %s\n' "$session_cmd" >> /etc/xrdp/startwm.sh

    # Append the static footer.
    cat >> /etc/xrdp/startwm.sh <<'STATIC'
else
    exec /etc/X11/Xsession
fi
STATIC

    chmod +x /etc/xrdp/startwm.sh
    log_ok "GNOME session script created"
}

# =============================================================================
# 5. POLKIT – FIX AUTHENTICATION POPUPS
# =============================================================================
configure_polkit() {
    log_step "Configuring PolicyKit"

    mkdir -p /etc/polkit-1/rules.d
    mkdir -p /etc/polkit-1/localauthority/50-local.d

    # Allow color profile management (eliminates auth popup on RDP login)
    cat > /etc/polkit-1/rules.d/02-xrdp-colord.rules <<'RULES'
polkit.addRule(function(action, subject) {
    var colorActions = [
        "org.freedesktop.color-manager.create-device",
        "org.freedesktop.color-manager.create-profile",
        "org.freedesktop.color-manager.delete-device",
        "org.freedesktop.color-manager.delete-profile",
        "org.freedesktop.color-manager.modify-device",
        "org.freedesktop.color-manager.modify-profile"
    ];
    if (colorActions.indexOf(action.id) !== -1 && subject.isInGroup("users")) {
        return polkit.Result.YES;
    }
});
RULES

    # Legacy .pkla format (polkit < 0.106)
    cat > /etc/polkit-1/localauthority/50-local.d/45-xrdp-colord.pkla <<'PKLA'
[Allow colord for RDP users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
PKLA

    log_ok "PolicyKit rules created"
}

# =============================================================================
# 6. XRDP CONFIGURATION
# =============================================================================
configure_xrdp() {
    log_step "Configuring xrdp"

    local ini="/etc/xrdp/xrdp.ini"
    cp "$ini" "${ini}.bak"

    # Port
    sed -i "s/^port=.*/port=${RDP_PORT}/" "$ini"

    # TLS encryption
    sed -i 's/^security_layer=.*/security_layer=tls/' "$ini"

    # Add xrdp to ssl-cert group
    if getent group ssl-cert > /dev/null 2>&1; then
        usermod -aG ssl-cert xrdp
        log_ok "xrdp added to ssl-cert group"
    fi

    log_ok "xrdp configured on port ${RDP_PORT}"
}

# =============================================================================
# 7. FIREWALL
# =============================================================================
configure_firewall() {
    log_step "Configuring firewall"

    if command -v ufw &>/dev/null; then
        # Always allow SSH to prevent lockout
        ufw allow ssh comment 'SSH' 2>/dev/null || true

        if [[ "$SKIP_TUNNEL" == true ]]; then
            # Direct mode: open RDP port to the world
            ufw allow "${RDP_PORT}/tcp" comment 'RDP'
            log_ok "UFW: opened port ${RDP_PORT}/tcp"
        else
            # Tunnel mode: RDP only from localhost (cloudflared → xrdp)
            ufw allow from 127.0.0.1 to any port "${RDP_PORT}" proto tcp comment 'RDP via Cloudflare Tunnel'
            log_ok "UFW: RDP restricted to localhost (Cloudflare Tunnel only)"
        fi

        if ! ufw status | grep -q "Status: active"; then
            ufw --force enable
        fi
        ufw status
    else
        log_warn "UFW not found – skipping firewall configuration"
    fi
}

# =============================================================================
# 8. CLOUDFLARE TUNNEL
# =============================================================================
install_cloudflared() {
    log_step "Installing cloudflared"

    if command -v cloudflared &>/dev/null; then
        log_ok "cloudflared already installed: $(cloudflared --version)"
        return
    fi

    local arch
    arch=$(dpkg --print-architecture)   # amd64 / arm64

    local pkg_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"

    log_info "Downloading cloudflared (${arch})..."
    local tmp_deb
    tmp_deb=$(mktemp /tmp/cloudflared_XXXXXX.deb)

    if command -v curl &>/dev/null; then
        curl -fsSL -o "$tmp_deb" "$pkg_url"
    elif command -v wget &>/dev/null; then
        wget -q -O "$tmp_deb" "$pkg_url"
    else
        apt-get install -y curl
        curl -fsSL -o "$tmp_deb" "$pkg_url"
    fi

    dpkg -i "$tmp_deb"
    rm -f "$tmp_deb"
    log_ok "cloudflared installed: $(cloudflared --version)"
}

setup_cloudflare_tunnel_token() {
    # Non-interactive mode: use pre-generated tunnel token
    log_step "Configuring Cloudflare Tunnel (token mode)"

    cloudflared service install "$TUNNEL_TOKEN"
    systemctl enable cloudflared
    systemctl start cloudflared

    log_ok "Cloudflare Tunnel service installed via token"
}

setup_cloudflare_tunnel_interactive() {
    log_step "Configuring Cloudflare Tunnel (interactive)"

    if [[ -z "$CF_HOSTNAME" ]]; then
        echo -e "${YELLOW}Enter the hostname for RDP access (e.g. rdp.example.com):${NC}"
        read -r CF_HOSTNAME
        [[ -n "$CF_HOSTNAME" ]] || { log_error "Hostname cannot be empty"; exit 1; }
    fi

    # ── 8a. Login ──────────────────────────────────────────────────────────────
    log_info "Logging into Cloudflare (browser will open)..."
    cloudflared tunnel login

    # ── 8b. Create tunnel ──────────────────────────────────────────────────────
    if cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
        log_warn "Tunnel '$TUNNEL_NAME' already exists – reusing"
    else
        cloudflared tunnel create "$TUNNEL_NAME"
        log_ok "Tunnel '$TUNNEL_NAME' created"
    fi

    local tunnel_id
    tunnel_id=$(cloudflared tunnel list --output json 2>/dev/null \
        | python3 -c "import sys,json; t=[x for x in json.load(sys.stdin) if x['name']=='${TUNNEL_NAME}']; print(t[0]['id'])" \
        2>/dev/null || true)

    if [[ -z "$tunnel_id" ]]; then
        log_warn "Could not auto-detect tunnel ID. Check 'cloudflared tunnel list'."
    fi

    # ── 8c. DNS route ──────────────────────────────────────────────────────────
    cloudflared tunnel route dns "$TUNNEL_NAME" "$CF_HOSTNAME"
    log_ok "DNS CNAME set: $CF_HOSTNAME → tunnel"

    # ── 8d. Config file ────────────────────────────────────────────────────────
    mkdir -p /etc/cloudflared

    local cred_file
    cred_file=$(ls ~/.cloudflared/*.json 2>/dev/null | head -n1 || true)

    # Move credentials to system location if created as root
    if [[ -n "$cred_file" && ! -f "/etc/cloudflared/$(basename "$cred_file")" ]]; then
        cp "$cred_file" /etc/cloudflared/
        cred_file="/etc/cloudflared/$(basename "$cred_file")"
    fi

    cat > /etc/cloudflared/config.yml <<CFCFG
tunnel: ${TUNNEL_NAME}
credentials-file: ${cred_file:-~/.cloudflared/${tunnel_id}.json}

ingress:
  # RDP over TCP
  - hostname: ${CF_HOSTNAME}
    service: tcp://localhost:${RDP_PORT}
    originRequest:
      connectTimeout: 30s
  - service: http_status:404
CFCFG

    log_ok "Cloudflared config written to /etc/cloudflared/config.yml"

    # ── 8e. Systemd service ────────────────────────────────────────────────────
    cloudflared service install || true
    systemctl enable cloudflared
    systemctl restart cloudflared

    if systemctl is-active --quiet cloudflared; then
        log_ok "Cloudflare Tunnel service is running"
    else
        log_warn "cloudflared service did not start – check: journalctl -u cloudflared"
    fi
}

# =============================================================================
# 9. POWER MANAGEMENT
# =============================================================================

# ── 9a. Disable all sleep/suspend targets ─────────────────────────────────────
power_disable_sleep() {
    log_step "Power: disabling sleep / suspend"

    # Mask systemd sleep targets — survives reboots
    systemctl mask sleep.target suspend.target hibernate.target \
        hybrid-sleep.target 2>/dev/null || true

    # Prevent GNOME from auto-suspending (run as the login user, not root)
    # Works on both X11 and Wayland GNOME sessions.
    local real_user="${SUDO_USER:-}"
    if [[ -n "$real_user" ]]; then
        sudo -u "$real_user" \
            gsettings set org.gnome.settings-daemon.plugins.power \
            sleep-inactive-ac-type 'nothing' 2>/dev/null || true
        sudo -u "$real_user" \
            gsettings set org.gnome.settings-daemon.plugins.power \
            sleep-inactive-battery-type 'nothing' 2>/dev/null || true
        log_ok "GNOME auto-suspend disabled for user '$real_user'"
    else
        log_warn "Could not detect login user — set GNOME auto-suspend manually:"
        log_warn "  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'"
    fi

    log_ok "All sleep/suspend targets masked"
}

# ── 9b. Wake-on-LAN ───────────────────────────────────────────────────────────
power_enable_wol() {
    log_step "Power: enabling Wake-on-LAN"

    apt-get install -y ethtool

    # Detect the default-route interface (the NIC used for internet access)
    local iface
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)

    if [[ -z "$iface" ]]; then
        log_warn "Could not detect network interface — enable WoL manually:"
        log_warn "  sudo ethtool -s <iface> wol g"
        return
    fi

    local mac
    mac=$(ip link show "$iface" 2>/dev/null | awk '/link\/ether/ {print $2}')

    # Enable WoL magic-packet mode for current session
    ethtool -s "$iface" wol g 2>/dev/null || \
        log_warn "ethtool failed — your NIC or driver may not support WoL"

    # Persist across reboots with a systemd service
    cat > /etc/systemd/system/wol-enable.service <<WOLS
[Unit]
Description=Enable Wake-on-LAN on ${iface}
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -s ${iface} wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
WOLS

    systemctl daemon-reload
    systemctl enable --now wol-enable.service

    log_ok "WoL enabled on ${iface}  (MAC: ${mac:-unknown})"
    echo -e ""
    echo -e "  ${BOLD}MAC address:${NC}  ${mac:-run: ip link show ${iface}}"
    echo -e ""
    echo -e "${YELLOW}Next steps for WoL:${NC}"
    echo -e "  1. Enable WoL in BIOS/UEFI  (usually under 'Power' or 'Advanced')"
    echo -e "  2. To wake the machine from another device on the same network:"
    echo -e "     ${GREEN}wakeonlan ${mac:-<MAC>}${NC}     # or  etherwake ${mac:-<MAC>}"
    echo -e "  3. For remote (external) wake, an always-on relay device is needed:"
    echo -e "     e.g. Raspberry Pi / VPS that can reach this machine's subnet"
    echo -e "     The relay runs: wakeonlan -i <broadcast-IP> ${mac:-<MAC>}"
    echo -e ""
    echo -e "${YELLOW}Important:${NC} While sleeping the Cloudflare Tunnel is offline."
    echo -e "  Wake the machine first, wait ~60 s, then connect via RDP."
}

# ── 9c. Apply power management (default: disable-sleep) ──────────────────────
power_prompt_and_apply() {
    # Default is disable-sleep — keeps RDP always reachable without extra setup.
    # Override with --power wol or --power none.
    local mode="${POWER_MODE:-disable-sleep}"
    case "$mode" in
        disable-sleep) power_disable_sleep ;;
        wol)           power_enable_wol ;;
        none)          log_info "Power management skipped (--power none)" ;;
        *)
            log_error "Unknown --power mode: $mode"
            log_error "Valid modes: disable-sleep | wol | none"
            exit 1 ;;
    esac
}

# =============================================================================
# 10. START XRDP
# =============================================================================
start_xrdp() {
    log_step "Starting xrdp service"

    systemctl daemon-reload
    systemctl enable xrdp
    systemctl restart xrdp

    if systemctl is-active --quiet xrdp; then
        log_ok "xrdp is running on port ${RDP_PORT}"
    else
        log_error "xrdp failed to start"
        systemctl status xrdp --no-pager || true
        exit 1
    fi
}

# =============================================================================
# 10. SHOW CONNECTION INFO
# =============================================================================
show_info() {
    log_step "Setup Complete"

    local local_ip
    local_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "unknown")

    echo -e ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║      Ubuntu RDP Setup Complete           ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo -e ""

    if [[ "$SKIP_TUNNEL" == true ]]; then
        local public_ip
        public_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")

        echo -e "  ${BOLD}Mode:${NC}          Direct RDP (UFW)"
        echo -e "  ${BOLD}Local IP:${NC}      ${local_ip}:${RDP_PORT}"
        echo -e "  ${BOLD}Public IP:${NC}     ${public_ip}:${RDP_PORT}"
        echo -e ""
        echo -e "${YELLOW}Required:${NC} Forward port ${RDP_PORT}/TCP on your router → ${local_ip}"
    else
        echo -e "  ${BOLD}Mode:${NC}          Cloudflare Tunnel"
        echo -e "  ${BOLD}Hostname:${NC}      ${CF_HOSTNAME:-"(see /etc/cloudflared/config.yml)"}"
        echo -e "  ${BOLD}Local port:${NC}    ${local_ip}:${RDP_PORT} (localhost only)"
        echo -e ""
        echo -e "${BOLD}${CYAN}How to connect from an external machine:${NC}"
        echo -e ""
        echo -e "  ${BOLD}Step 1.${NC} Install cloudflared on the CLIENT machine:"
        echo -e "          https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
        echo -e ""
        echo -e "  ${BOLD}Step 2.${NC} On the client, run:"
        echo -e "          ${GREEN}cloudflared access rdp --hostname ${CF_HOSTNAME:-rdp.example.com} --url rdp://localhost:${RDP_PORT}${NC}"
        echo -e ""
        echo -e "  ${BOLD}Step 3.${NC} Open your RDP client and connect to:"
        echo -e "          ${GREEN}localhost:${RDP_PORT}${NC}"
        echo -e "          (Login with your Ubuntu username / password)"
        echo -e ""
        echo -e "  ${BOLD}Windows shortcut:${NC}"
        echo -e "    mstsc → Computer: localhost:${RDP_PORT}"
        echo -e "    (while cloudflared access rdp is running in the background)"
    fi

    echo -e ""
    echo -e "${BOLD}RDP Clients:${NC}"
    echo -e "  Windows : Remote Desktop Connection (built-in)"
    echo -e "  macOS   : Microsoft Remote Desktop (App Store)"
    echo -e "  Linux   : Remmina  /  xfreerdp"
    echo -e ""
    echo -e "${YELLOW}Security notes:${NC}"
    echo -e "  • Cloudflare Tunnel encrypts traffic – no port forwarding needed"
    echo -e "  • Consider enabling Cloudflare Access policies (Zero Trust) for MFA"
    echo -e "  • Use a strong password for your Ubuntu account"
    echo -e ""
    echo -e "${BOLD}Useful commands:${NC}"
    echo -e "  systemctl status xrdp"
    echo -e "  systemctl status cloudflared"
    echo -e "  journalctl -u cloudflared -f"
    echo -e "  cloudflared tunnel info ${TUNNEL_NAME}"
    echo -e ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   Ubuntu RDP Setup — GNOME + Cloudflare Tunnel  ║"
    echo "║   Supports: Ubuntu 22.04 / 24.04                ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    parse_args "$@"

    check_root
    check_ubuntu
    check_gnome

    install_xrdp
    disable_wayland
    configure_gnome_session
    configure_polkit
    configure_xrdp
    configure_firewall
    power_prompt_and_apply
    start_xrdp

    if [[ "$SKIP_TUNNEL" == false ]]; then
        install_cloudflared

        if [[ -n "$TUNNEL_TOKEN" ]]; then
            setup_cloudflare_tunnel_token
        else
            setup_cloudflare_tunnel_interactive
        fi
    fi

    show_info
}

main "$@"
