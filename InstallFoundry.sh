#!/bin/bash
# =============================================================================
# FoundryVTT + Cloudflared Install Script for Debian
# - Installs Node.js 20
# - Creates foundry directory structure
# - Downloads and extracts FoundryVTT
# - Creates and enables foundryvtt systemd service
# - Installs cloudflared and registers tunnel via token
# - Installs qemu-guest-agent for Proxmox ballooning
#
# Run as your admin user with sudo (not as root directly).
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${YELLOW}========== $1 ==========${NC}"; }

# --- Must run as sudo-capable user, not root directly ---
if [[ $EUID -eq 0 ]]; then
    error "Do not run this script as root. Run as your admin user with sudo privileges."
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

# The dedicated service account for Foundry (no shell, no sudo)
FOUNDRY_USER="foundryvtt"

# Install paths
FOUNDRY_APP_DIR="/opt/foundry/app"
FOUNDRY_DATA_DIR="/opt/foundry/data"

# Node.js version
NODE_VERSION="20"

# =============================================================================
# STEP 1 - Install Prerequisites
# =============================================================================
section "STEP 1: Install Prerequisites"

log "Installing curl, wget, unzip..."
sudo apt update -y
sudo apt install -y curl wget unzip

log "Installing qemu-guest-agent for Proxmox ballooning..."
sudo apt install -y qemu-guest-agent
sudo systemctl enable qemu-guest-agent
sudo systemctl start qemu-guest-agent
log "qemu-guest-agent running."

# =============================================================================
# STEP 2 - Install Node.js
# =============================================================================
section "STEP 2: Install Node.js $NODE_VERSION"

log "Adding NodeSource repository..."
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo bash -

log "Installing Node.js..."
sudo apt install -y nodejs

NODE_INSTALLED=$(node -v)
log "Node.js installed: $NODE_INSTALLED"

# =============================================================================
# STEP 3 - Create Foundry User and Directories
# =============================================================================
section "STEP 3: Foundry User and Directory Setup"

if id "$FOUNDRY_USER" &>/dev/null; then
    warn "User '$FOUNDRY_USER' already exists, skipping creation."
else
    log "Creating '$FOUNDRY_USER' service account..."
    sudo adduser --disabled-password --gecos "" "$FOUNDRY_USER"
    log "User '$FOUNDRY_USER' created."
fi

log "Setting shell to nologin for '$FOUNDRY_USER'..."
sudo usermod -s /usr/sbin/nologin "$FOUNDRY_USER"

log "Creating Foundry directories..."
sudo mkdir -p "$FOUNDRY_APP_DIR"
sudo mkdir -p "$FOUNDRY_DATA_DIR"
sudo chown -R "$FOUNDRY_USER":"$FOUNDRY_USER" /opt/foundry
log "Directories created and ownership set."

# =============================================================================
# STEP 4 - Download and Extract FoundryVTT
# =============================================================================
section "STEP 4: Download FoundryVTT"

echo ""
echo -e "${YELLOW}You need a timed download URL from foundryvtt.com:${NC}"
echo "  1. Go to https://foundryvtt.com and log in"
echo "  2. Click your username → Purchased Licenses"
echo "  3. Click the download icon on your license"
echo "  4. Select Linux/NodeJS"
echo "  5. Click 'Timed URL' to generate the link"
echo "  6. Copy the full URL and paste it below"
echo ""
read -rp "Paste your Foundry timed download URL: " FOUNDRY_URL

if [[ -z "$FOUNDRY_URL" ]]; then
    error "No URL provided. Exiting."
fi

log "Downloading FoundryVTT..."
sudo -u "$FOUNDRY_USER" wget -O /tmp/foundryvtt.zip "$FOUNDRY_URL"

log "Extracting FoundryVTT to $FOUNDRY_APP_DIR..."
sudo -u "$FOUNDRY_USER" unzip /tmp/foundryvtt.zip -d "$FOUNDRY_APP_DIR"
sudo rm /tmp/foundryvtt.zip

# Locate main.js
log "Locating main.js..."
MAIN_JS=$(sudo find "$FOUNDRY_APP_DIR" -name "main.js" | grep -v node_modules | head -1)

if [[ -z "$MAIN_JS" ]]; then
    error "Could not locate main.js in $FOUNDRY_APP_DIR. Check the extraction manually."
fi

log "Found main.js at: $MAIN_JS"

# =============================================================================
# STEP 5 - Create systemd Service
# =============================================================================
section "STEP 5: Foundry systemd Service"

log "Writing /etc/systemd/system/foundryvtt.service..."
sudo tee /etc/systemd/system/foundryvtt.service > /dev/null <<EOF
[Unit]
Description=FoundryVTT
After=network.target

[Service]
Type=simple
User=$FOUNDRY_USER
WorkingDirectory=$(dirname "$MAIN_JS")
ExecStart=/usr/bin/node $MAIN_JS --dataPath=$FOUNDRY_DATA_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log "Reloading systemd and enabling foundryvtt service..."
sudo systemctl daemon-reload
sudo systemctl enable foundryvtt
sudo systemctl start foundryvtt

# Give it a moment to start
sleep 3

if sudo systemctl is-active --quiet foundryvtt; then
    log "FoundryVTT is running."
else
    error "FoundryVTT failed to start. Check: sudo journalctl -u foundryvtt -n 50"
fi

# Verify port is listening
if sudo ss -tlnp | grep -q ":30000"; then
    log "Foundry is listening on port 30000."
else
    warn "Port 30000 not detected yet - it may still be starting. Check with: sudo ss -tlnp | grep 30000"
fi

# =============================================================================
# STEP 6 - Install Cloudflared
# =============================================================================
section "STEP 6: Install Cloudflared"

log "Adding Cloudflare GPG key..."
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null

log "Adding Cloudflare repository..."
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list

sudo apt update
sudo apt install -y cloudflared
log "Cloudflared installed."

# =============================================================================
# STEP 7 - Register Cloudflare Tunnel
# =============================================================================
section "STEP 7: Register Cloudflare Tunnel"

echo ""
echo -e "${YELLOW}You need your tunnel token from the Cloudflare dashboard:${NC}"
echo "  1. Go to https://one.dash.cloudflare.com"
echo "  2. Networks → Tunnels → your tunnel → Configure"
echo "  3. Select Debian as the OS"
echo "  4. Copy the token from the install command (the long string after 'service install')"
echo ""
read -rp "Paste your Cloudflare tunnel token: " CF_TOKEN

if [[ -z "$CF_TOKEN" ]]; then
    error "No token provided. Exiting."
fi

log "Registering cloudflared as a system service..."
sudo cloudflared service install "$CF_TOKEN"

sleep 3

if sudo systemctl is-active --quiet cloudflared; then
    log "Cloudflared is running."
else
    error "Cloudflared failed to start. Check: sudo systemctl status cloudflared"
fi

# =============================================================================
# FINAL - Summary
# =============================================================================
section "FINAL: Installation Summary"

echo ""
sudo systemctl status foundryvtt --no-pager | grep -E "Active|Main PID"
sudo systemctl status cloudflared --no-pager | grep -E "Active|Main PID"
echo ""
sudo ss -tlnp | grep 30000 || warn "Port 30000 not showing - check Foundry status"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "  1. In Cloudflare dashboard, set the route URL to: http://localhost:30000"
echo -e "  2. Navigate to your domain and complete Foundry setup"
echo -e "  3. Set your Foundry admin password"
echo -e "  4. Create your world and invite your players"
echo ""
