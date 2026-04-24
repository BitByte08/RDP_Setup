#!/bin/bash
# =============================================================================
# setup_client_macos.sh — macOS RDP Client Setup
# =============================================================================
# Installs and configures everything needed to connect to the Ubuntu RDP server
# via Cloudflare Tunnel from a macOS machine.
#
# What this script does:
#   1. Installs Homebrew (if missing)
#   2. Installs cloudflared via Homebrew
#   3. Installs Microsoft Remote Desktop via Homebrew Cask (optional)
#   4. Creates a connect helper script at ~/bin/rdp-connect
#   5. Creates a launchd plist to run the Cloudflare access proxy as a service
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BOLD}${CYAN}──── $* ────${NC}"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
CF_HOSTNAME=""          # --hostname rdp.example.com
LOCAL_RDP_PORT=13389    # local port that cloudflared forwards to
INSTALL_MSRDP=true      # --no-msrdp to skip Microsoft Remote Desktop
INSTALL_SERVICE=false   # --service to install launchd auto-start

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 --hostname <rdp.example.com> [OPTIONS]

Options:
  --hostname <host>   Cloudflare hostname of the RDP server  (required)
  --port <port>       Local forwarding port                   (default: 13389)
  --no-msrdp          Skip Microsoft Remote Desktop install
  --service           Install cloudflared as a launchd service (auto-start)
  -h, --help          Show this help

Examples:
  $0 --hostname rdp.example.com
  $0 --hostname rdp.example.com --port 13389 --service
EOF
    exit 0
}

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)  CF_HOSTNAME="$2";      shift 2 ;;
        --port)      LOCAL_RDP_PORT="$2";   shift 2 ;;
        --no-msrdp)  INSTALL_MSRDP=false;   shift ;;
        --service)   INSTALL_SERVICE=true;  shift ;;
        -h|--help)   usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$CF_HOSTNAME" ]]; then
    echo -e "${YELLOW}Enter the RDP hostname (e.g. rdp.example.com):${NC} "
    read -r CF_HOSTNAME
    [[ -n "$CF_HOSTNAME" ]] || { log_error "Hostname is required"; exit 1; }
fi

# ── OS check ──────────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
    log_error "This script is for macOS only."
    exit 1
fi

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║   Ubuntu RDP — macOS Client Setup               ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# =============================================================================
# 1. HOMEBREW
# =============================================================================
log_step "Homebrew"

if command -v brew &>/dev/null; then
    log_ok "Homebrew already installed: $(brew --version | head -1)"
else
    log_info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add brew to PATH for Apple Silicon
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        # Persist for future shells
        local_profile="$HOME/.zprofile"
        if ! grep -q "homebrew" "$local_profile" 2>/dev/null; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$local_profile"
        fi
    fi
    log_ok "Homebrew installed"
fi

# =============================================================================
# 2. CLOUDFLARED
# =============================================================================
log_step "cloudflared"

if command -v cloudflared &>/dev/null; then
    log_ok "cloudflared already installed: $(cloudflared --version)"
else
    log_info "Installing cloudflared..."
    brew install cloudflare/cloudflare/cloudflared
    log_ok "cloudflared installed: $(cloudflared --version)"
fi

# =============================================================================
# 3. MICROSOFT REMOTE DESKTOP (optional)
# =============================================================================
log_step "RDP Client"

if [[ "$INSTALL_MSRDP" == true ]]; then
    if [[ -d "/Applications/Microsoft Remote Desktop.app" ]]; then
        log_ok "Microsoft Remote Desktop already installed"
    else
        log_info "Installing Microsoft Remote Desktop via Homebrew Cask..."
        if brew install --cask microsoft-remote-desktop 2>/dev/null; then
            log_ok "Microsoft Remote Desktop installed"
        else
            log_warn "Could not install via Homebrew. Download manually:"
            log_warn "  https://apps.apple.com/app/microsoft-remote-desktop/id1295203466"
        fi
    fi
else
    log_info "Skipping Microsoft Remote Desktop (--no-msrdp)"
    log_info "You can use any RDP client: Screens, CoRD, or built-in Screen Sharing"
fi

# =============================================================================
# 4. CONNECT HELPER SCRIPT ~/bin/rdp-connect
# =============================================================================
log_step "Creating connect helper ~/bin/rdp-connect"

mkdir -p "$HOME/bin"

cat > "$HOME/bin/rdp-connect" <<HELPER
#!/bin/bash
# rdp-connect — One-command RDP connection via Cloudflare Tunnel
# Generated by setup_client_macos.sh
#
# Usage:
#   rdp-connect          # Start tunnel + open RDP client
#   rdp-connect stop     # Stop the background tunnel proxy

CF_HOSTNAME="${CF_HOSTNAME}"
LOCAL_PORT="${LOCAL_RDP_PORT}"
PROXY_PID_FILE="\$HOME/.cache/cloudflared-rdp.pid"

start() {
    echo "Starting Cloudflare RDP proxy → \$CF_HOSTNAME..."

    # Kill any existing proxy on the same port
    if [[ -f "\$PROXY_PID_FILE" ]]; then
        old_pid=\$(cat "\$PROXY_PID_FILE")
        kill "\$old_pid" 2>/dev/null || true
        rm -f "\$PROXY_PID_FILE"
    fi

    mkdir -p "\$(dirname "\$PROXY_PID_FILE")"

    # Start tunnel proxy in background
    cloudflared access rdp \
        --hostname "\$CF_HOSTNAME" \
        --url "rdp://localhost:\$LOCAL_PORT" &
    echo \$! > "\$PROXY_PID_FILE"

    # Wait for proxy to be ready
    echo -n "Waiting for proxy"
    for i in \$(seq 1 20); do
        if nc -z localhost "\$LOCAL_PORT" 2>/dev/null; then
            echo " ready"
            break
        fi
        echo -n "."
        sleep 0.5
    done

    echo ""
    echo "Tunnel active: localhost:\$LOCAL_PORT → \$CF_HOSTNAME"
    echo ""
    echo "Connect with:"
    echo "  Microsoft Remote Desktop → localhost:\$LOCAL_PORT"
    echo "  or: open rdp://localhost:\$LOCAL_PORT"
    echo ""
    echo "Run 'rdp-connect stop' when done."

    # Try to open Microsoft Remote Desktop automatically
    if [[ -d "/Applications/Microsoft Remote Desktop.app" ]]; then
        open "rdp://localhost:\${LOCAL_PORT}"
    fi
}

stop() {
    if [[ -f "\$PROXY_PID_FILE" ]]; then
        pid=\$(cat "\$PROXY_PID_FILE")
        if kill "\$pid" 2>/dev/null; then
            echo "Stopped cloudflared proxy (PID \$pid)"
        else
            echo "Proxy was not running"
        fi
        rm -f "\$PROXY_PID_FILE"
    else
        # Kill any cloudflared access rdp process
        pkill -f "cloudflared access rdp" 2>/dev/null && echo "Stopped cloudflared proxy" || echo "No proxy running"
    fi
}

case "\${1:-start}" in
    start) start ;;
    stop)  stop  ;;
    *)     echo "Usage: rdp-connect [start|stop]"; exit 1 ;;
esac
HELPER

chmod +x "$HOME/bin/rdp-connect"
log_ok "Created ~/bin/rdp-connect"

# Add ~/bin to PATH if not already there
SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == *"bash"* ]] && SHELL_RC="$HOME/.bash_profile"

if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$SHELL_RC" 2>/dev/null; then
    echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
    log_ok "Added ~/bin to PATH in $SHELL_RC"
fi

# Export for current session
export PATH="$HOME/bin:$PATH"

# =============================================================================
# 5. LAUNCHD SERVICE (optional — auto-start tunnel proxy on login)
# =============================================================================
if [[ "$INSTALL_SERVICE" == true ]]; then
    log_step "Installing launchd service (auto-start on login)"

    PLIST_DIR="$HOME/Library/LaunchAgents"
    PLIST="$PLIST_DIR/com.cloudflare.rdp-tunnel.plist"
    mkdir -p "$PLIST_DIR"

    CF_BIN=$(command -v cloudflared)

    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.rdp-tunnel</string>

    <key>ProgramArguments</key>
    <array>
        <string>${CF_BIN}</string>
        <string>access</string>
        <string>rdp</string>
        <string>--hostname</string>
        <string>${CF_HOSTNAME}</string>
        <string>--url</string>
        <string>rdp://localhost:${LOCAL_RDP_PORT}</string>
    </array>

    <key>RunAtLoad</key>
    <false/>

    <key>KeepAlive</key>
    <false/>

    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/cloudflared-rdp.log</string>

    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/cloudflared-rdp-error.log</string>
</dict>
</plist>
PLIST

    launchctl unload "$PLIST" 2>/dev/null || true
    log_ok "Launchd plist saved: $PLIST"
    log_info "To start tunnel manually: launchctl load $PLIST"
fi

# =============================================================================
# DONE
# =============================================================================
log_step "Setup Complete"

echo -e ""
echo -e "${BOLD}${GREEN}macOS RDP client is ready!${NC}"
echo -e ""
echo -e "  ${BOLD}Target server:${NC}  $CF_HOSTNAME"
echo -e "  ${BOLD}Local port:${NC}     localhost:$LOCAL_RDP_PORT"
echo -e ""
echo -e "${BOLD}Quick connect:${NC}"
echo -e "  ${GREEN}rdp-connect${NC}          # start tunnel + open RDP client"
echo -e "  ${GREEN}rdp-connect stop${NC}     # stop tunnel"
echo -e ""
echo -e "${BOLD}Manual steps:${NC}"
echo -e "  1. ${GREEN}cloudflared access rdp --hostname $CF_HOSTNAME --url rdp://localhost:$LOCAL_RDP_PORT${NC}"
echo -e "  2. Open Microsoft Remote Desktop → New PC → ${BOLD}localhost:$LOCAL_RDP_PORT${NC}"
echo -e "  3. Login with your Ubuntu username and password"
echo -e ""
if [[ "$INSTALL_SERVICE" == false ]]; then
    echo -e "${YELLOW}Tip:${NC} Run with --service to install a launchd auto-start entry"
fi
echo -e ""
