# FoundryVTT Self-Hosted Setup

Secure, free-to-operate self-hosted FoundryVTT using Proxmox, Debian, and Cloudflare Tunnel. No open router ports, no exposed home IP, Cloudflare Access authentication in front of the app.

---

## Stack Overview

```
Players → Cloudflare Access (email verify) → Cloudflare Tunnel → FoundryVTT (port 30000)
```

| Component | Purpose |
|---|---|
| Proxmox | Hypervisor running the Debian VM |
| Debian 12 (Bookworm) | OS for the Foundry server |
| FoundryVTT | Virtual tabletop application |
| Node.js 20 | Runtime for Foundry |
| cloudflared | Outbound tunnel to Cloudflare's network |
| Cloudflare Tunnel | Exposes Foundry externally without open ports |
| Cloudflare Access | Email-based authentication gate in front of Foundry |
| UFW | Host-based firewall |
| Fail2Ban | SSH brute force protection |
| auditd | Security event logging |

---

## Costs

| Item | Cost |
|---|---|
| FoundryVTT license | ~$50 one-time |
| Domain name | ~$10–15/year |
| Cloudflare Tunnel | Free |
| Cloudflare Access (up to 50 users) | Free |
| Proxmox | Free (runs on your own hardware) |
| Debian | Free |

---

## Prerequisites

- Proxmox host with available resources
- Cloudflare account with a domain managed by Cloudflare DNS
- FoundryVTT license from [foundryvtt.com](https://foundryvtt.com)
- SSH access to the Debian VM from your management machine

---

## Proxmox VM Specs

Recommended for a private group of 4–5 players:

| Setting | Value |
|---|---|
| OS | Debian 12 (Bookworm) |
| Disk | 50 GB |
| RAM | 4096 MB (balloon to 8192 MB) |
| Sockets | 1 |
| Cores | 2 |
| NUMA | Disabled |
| Cache | Write through |
| QEMU Guest Agent | Enabled |

> **Note:** Write through cache is recommended if you do not have a UPS. Switch to Write back if you add one later.

---

## Scripts

Two scripts are included in this repo. Run them in order on a fresh Debian install.

### 1. `harden-debian.sh`

Hardens the base OS. Run this first, immediately after the Debian install.

**What it does:**
- Updates all system packages
- Creates a non-root admin user with sudo access
- Configures UFW — denies all inbound traffic, allows SSH from your LAN subnet only
- Installs and configures Fail2Ban — bans IPs after 3 failed SSH attempts for 24 hours
- Enables unattended security upgrades with automatic reboots at 03:00
- Applies sysctl kernel hardening (IP spoofing protection, SYN flood protection, ICMP redirect blocking, kernel pointer restrictions)
- Disables unused services (bluetooth, avahi, cups, rpcbind, nfs-common)
- Locks the `foundryvtt` service account — no shell, no password, no sudo
- Installs auditd and sets rules to log changes to auth files, sudoers, SSH config, and systemd services

**Edit the config block at the top before running:**

```bash
ADMIN_USER="youruser"         # your admin username
LAN_SUBNET="10.6.4.0/24"     # subnet SSH is reachable from
FOUNDRY_USER="foundryvtt"     # service account name
DISABLE_IPV6="true"           # set false if you need IPv6
AUTO_REBOOT_TIME="03:00"      # time unattended upgrades may reboot
```

**Run:**
```bash
chmod +x harden-debian.sh
sudo ./harden-debian.sh
```

---

### 2. `install-foundry.sh`

Installs FoundryVTT and cloudflared. Run this after the hardening script.

**What it does:**
- Installs curl, wget, unzip
- Installs qemu-guest-agent (required for Proxmox RAM ballooning)
- Installs Node.js 20 via NodeSource
- Creates the `foundryvtt` service account and `/opt/foundry/app` + `/opt/foundry/data` directories
- Prompts for your Foundry timed download URL and downloads/extracts Foundry
- Automatically locates `main.js` and writes the correct systemd service file
- Enables and starts the `foundryvtt` systemd service
- Installs cloudflared from Cloudflare's official repo
- Prompts for your Cloudflare tunnel token and registers cloudflared as a systemd service

**Run:**
```bash
chmod +x install-foundry.sh
./install-foundry.sh
```

> **Note:** Run without sudo — the script calls sudo internally where needed.

During the script you will be prompted for:
1. Your **Foundry timed download URL** — generate this from [foundryvtt.com](https://foundryvtt.com) → Purchased Licenses → your license → Linux/NodeJS → Timed URL
2. Your **Cloudflare tunnel token** — found in the Cloudflare dashboard under Networks → Tunnels → your tunnel → Configure → Debian

---

## Cloudflare Tunnel Setup

1. Go to [one.dash.cloudflare.com](https://one.dash.cloudflare.com)
2. **Networks → Tunnels → Create a tunnel**
3. Choose **Cloudflared** → name it (e.g. `foundryvtt`) → Save
4. Select **Debian** as the OS and copy the tunnel token for use in `install-foundry.sh`
5. After the script runs, go to **Routes → Add route → Published application**

| Field | Value |
|---|---|
| Internal hostname | `localhost` |
| Protocol | `HTTP` |
| Port | `30000` |

6. Set your public hostname (e.g. `vtt.yourdomain.com`) and save

---

## Cloudflare Access Setup

Puts an email verification gate in front of Foundry so only authorized players can reach it.

1. Go to [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → set up **Zero Trust** (free, up to 50 users)
2. **Access → Applications → Add an application → Self-hosted**

| Field | Value |
|---|---|
| Application name | `FoundryVTT` |
| Internal hostname | `localhost` |
| Protocol | `HTTP` |
| Port | `30000` |

3. Add a policy with **Action: Allow** and add each player's email under **Emails**
4. Save the application

Players will receive a one-time code to their email the first time they visit your URL. Each unique email uses 1 of your 50 free seats.

---

## Foundry Configuration

After the install script runs, edit Foundry's `options.json` to configure it for the reverse proxy:

```bash
sudo -u foundryvtt nano /opt/foundry/data/Config/options.json
```

```json
"hostname": "vtt.yourdomain.com",
"proxySSL": true,
"proxyPort": 443,
"upnp": false
```

Restart Foundry:
```bash
sudo systemctl restart foundryvtt
```

---

## Firewall Rules

UFW is configured by the hardening script. To open additional ports after setup:

```bash
# Example: allow Foundry access from your VLAN
sudo ufw allow from 10.10.20.0/24 to any port 30000 comment "FoundryVTT VLAN"

# Check current rules
sudo ufw status verbose
```

---

## Service Management

```bash
# Foundry
sudo systemctl status foundryvtt
sudo systemctl restart foundryvtt
sudo journalctl -u foundryvtt -n 50

# Cloudflared
sudo systemctl status cloudflared
sudo systemctl restart cloudflared
sudo journalctl -u cloudflared -n 50

# Check open ports
sudo ss -tlnp
```

---

## Security Notes

- **Home IP is never exposed** — all traffic routes through Cloudflare's network
- **No open inbound ports** — cloudflared uses outbound-only connections
- **Cloudflare Access** gates all external traffic behind email verification
- **foundryvtt service account** has no shell, no password, and no sudo rights
- **SSH is restricted** to your LAN subnet only via UFW
- **Unattended security upgrades** keep the OS patched automatically
- This setup is appropriate for a private group of trusted players. It is not intended for large public-facing deployments.

---

## Adding Players

1. Go to Cloudflare Zero Trust → **Access → Applications → FoundryVTT → Edit → Policies**
2. Add each player's email address under **Emails**
3. Share your domain URL with them — they will receive an email verification code on first visit

---

## Directory Structure

```
/opt/foundry/
├── app/          # Foundry application files (owned by foundryvtt)
│   └── resources/
│       └── app/
│           └── main.js
└── data/         # Worlds, assets, modules, settings (owned by foundryvtt)
    └── Config/
        └── options.json
```

---

## Proxmox Guest Agent

The install script handles this automatically, but if you need to do it manually:

```bash
sudo apt install -y qemu-guest-agent
sudo systemctl enable qemu-guest-agent
sudo systemctl start qemu-guest-agent
```

Also ensure the **QEMU Guest Agent** checkbox is enabled in the VM's Options tab in the Proxmox UI. Both sides must be configured for RAM ballooning to work.
