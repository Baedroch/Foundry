#!/bin/bash
# =============================================================================
# Debian Hardening Script
# Covers: system update, non-root admin user, UFW firewall, Fail2Ban,
#         unattended upgrades, sysctl kernel hardening, unused service
#         cleanup, foundry user lockdown, and auditd logging.
# SSH hardening is intentionally excluded - handle that separately.
# Run as root or with sudo.
# =============================================================================

set -euo pipefail

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${YELLOW}========== $1 ==========${NC}"; }

# --- Must run as root ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root or with sudo."
fi

# =============================================================================
# CONFIGURATION - Edit these before running
# =============================================================================

# Your admin username (will be created if it doesn't exist)
ADMIN_USER="richard"

# Subnet that SSH will be reachable from (your main LAN)
LAN_SUBNET="REDACTED"

# The service account that runs Foundry - no sudo, no shell access
FOUNDRY_USER="foundryvtt"

# Set to "true" to disable IPv6 (recommended if you are not using it)
DISABLE_IPV6="true"

# Time unattended upgrades may reboot the machine if needed (24hr format)
AUTO_REBOOT_TIME="03:00"

# =============================================================================
# STEP 1 - System Update
# =============================================================================
section "STEP 1: System Update"

log "Updating package lists and upgrading installed packages..."
apt update -y
apt upgrade -y
apt autoremove -y
apt autoclean -y
log "System updated."

# =============================================================================
# STEP 2 - Create Non-Root Admin User
# =============================================================================
section "STEP 2: Admin User Setup"

if id "$ADMIN_USER" &>/dev/null; then
    warn "User '$ADMIN_USER' already exists, skipping creation."
else
    log "Creating admin user '$ADMIN_USER'..."
    adduser --gecos "" "$ADMIN_USER"
    log "User '$ADMIN_USER' created."
fi

if groups "$ADMIN_USER" | grep -q "\bsudo\b"; then
    warn "User '$ADMIN_USER' is already in the sudo group."
else
    log "Adding '$ADMIN_USER' to sudo group..."
    usermod -aG sudo "$ADMIN_USER"
    log "Done."
fi

# =============================================================================
# STEP 3 - UFW Firewall
# =============================================================================
section "STEP 3: UFW Firewall"

log "Installing UFW..."
apt install -y ufw

log "Setting default policies - deny inbound, allow outbound..."
ufw default deny incoming
ufw default allow outgoing

log "Allowing SSH from LAN subnet only ($LAN_SUBNET)..."
ufw allow from "$LAN_SUBNET" to any port 22 comment "SSH - LAN only"

log "Enabling UFW..."
ufw --force enable

log "UFW status:"
ufw status verbose
log "Firewall configured."

# =============================================================================
# STEP 4 - Fail2Ban
# =============================================================================
section "STEP 4: Fail2Ban"

log "Installing Fail2Ban..."
apt install -y fail2ban

log "Writing /etc/fail2ban/jail.local..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 24h
EOF

log "Enabling and starting Fail2Ban..."
systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2Ban configured."

# =============================================================================
# STEP 5 - Unattended Security Upgrades
# =============================================================================
section "STEP 5: Unattended Security Upgrades"

log "Installing unattended-upgrades and apt-listchanges..."
apt install -y unattended-upgrades apt-listchanges

log "Writing /etc/apt/apt.conf.d/50unattended-upgrades..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "$AUTO_REBOOT_TIME";
EOF

log "Writing /etc/apt/apt.conf.d/20auto-upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

log "Unattended upgrades configured (reboots at $AUTO_REBOOT_TIME if needed)."

# =============================================================================
# STEP 6 - Kernel / sysctl Hardening
# =============================================================================
section "STEP 6: Kernel Hardening (sysctl)"

log "Writing /etc/sysctl.d/99-hardening.conf..."
cat > /etc/sysctl.d/99-hardening.conf <<EOF
# --- IP Spoofing Protection ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# --- Ignore ICMP Redirects (prevent MITM) ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# --- Ignore Ping Broadcasts ---
net.ipv4.icmp_echo_ignore_broadcasts = 1

# --- SYN Flood Protection ---
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# --- Prevent Core Dump Leaks ---
fs.suid_dumpable = 0

# --- Restrict dmesg to root ---
kernel.dmesg_restrict = 1

# --- Restrict Kernel Pointer Leaks ---
kernel.kptr_restrict = 2
EOF

if [[ "$DISABLE_IPV6" == "true" ]]; then
    log "Disabling IPv6..."
    cat >> /etc/sysctl.d/99-hardening.conf <<EOF

# --- Disable IPv6 ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
fi

log "Applying sysctl settings..."
sysctl -p /etc/sysctl.d/99-hardening.conf
log "Kernel hardening applied."

# =============================================================================
# STEP 7 - Disable Unused Services
# =============================================================================
section "STEP 7: Disable Unused Services"

UNUSED_SERVICES=("bluetooth" "avahi-daemon" "cups" "cups-browsed" "rpcbind" "nfs-common")

for svc in "${UNUSED_SERVICES[@]}"; do
    if systemctl list-units --all | grep -q "$svc"; then
        log "Disabling $svc..."
        systemctl disable --now "$svc" 2>/dev/null || warn "$svc could not be stopped (may not be running)."
    else
        warn "$svc not found, skipping."
    fi
done

log "Unused services disabled."

# =============================================================================
# STEP 8 - Foundry User Lockdown
# =============================================================================
section "STEP 8: Foundry User Lockdown"

if id "$FOUNDRY_USER" &>/dev/null; then
    log "Removing shell access from '$FOUNDRY_USER'..."
    usermod -s /usr/sbin/nologin "$FOUNDRY_USER"

    log "Ensuring '$FOUNDRY_USER' has no sudo access..."
    if groups "$FOUNDRY_USER" | grep -q "\bsudo\b"; then
        gpasswd -d "$FOUNDRY_USER" sudo
        warn "Removed '$FOUNDRY_USER' from sudo group - it should not have been there."
    else
        log "'$FOUNDRY_USER' is not in sudo group. Good."
    fi

    log "Locking password for '$FOUNDRY_USER'..."
    passwd -l "$FOUNDRY_USER"

    log "Foundry user locked down."
else
    warn "User '$FOUNDRY_USER' not found - skipping. Re-run this script after the Foundry user is created."
fi

# =============================================================================
# STEP 9 - Auditd Logging
# =============================================================================
section "STEP 9: Auditd Logging"

log "Installing auditd and audispd-plugins..."
apt install -y auditd audispd-plugins

log "Writing audit rules to /etc/audit/rules.d/hardening.rules..."
cat > /etc/audit/rules.d/hardening.rules <<EOF
# --- Identity and Auth Files ---
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers

# --- SSH Config Changes ---
-w /etc/ssh/sshd_config -p wa -k sshd_config

# --- Sudo Usage ---
-w /usr/bin/sudo -p x -k sudo_usage

# --- Systemd Service Changes ---
-w /etc/systemd/system -p wa -k systemd_services
EOF

log "Enabling and starting auditd..."
systemctl enable auditd
systemctl restart auditd
log "Auditd configured."

# =============================================================================
# FINAL - Status Summary
# =============================================================================
section "FINAL: Service Status Summary"

SERVICES=("ufw" "fail2ban" "auditd")

for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then
        log "$svc is running."
    else
        warn "$svc is NOT running - check with: sudo systemctl status $svc"
    fi
done

echo ""
log "Checking open ports..."
ss -tlnp

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Hardening complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  ${YELLOW}Reminders:${NC}"
echo -e "  1. Only port 22 should appear in open ports above"
echo -e "  2. Harden SSH separately using key-based auth"
echo -e "  3. Open any additional ports via UFW as needed after this runs"
echo -e "  4. If '$FOUNDRY_USER' did not exist yet, re-run after creating it"
echo -e "  5. Install qemu-guest-agent for Proxmox ballooning:"
echo -e "     sudo apt install -y qemu-guest-agent"
echo ""
