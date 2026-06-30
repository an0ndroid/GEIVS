#!/bin/bash
# =============================================================
# GEIVS Pro — Server Preparation & Hardening Script
# Run this BEFORE geivs-install.sh on a fresh Ubuntu 22.04/24.04
# Requires: sudo or root
# Usage: sudo bash geivs-prep.sh
# =============================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

STEP=0
TOTAL_STEPS=14
REBOOT_REQUIRED=false
HAS_NVIDIA_HW=false

step() { STEP=$((STEP+1)); echo ""; echo -e "${CYAN}── Step ${STEP}/${TOTAL_STEPS}: $1 ${NC}"; }
ok()   { echo -e "${GREEN}  ✓ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }
err()  { echo -e "${RED}  ✗ $1${NC}"; }
info() { echo -e "${BLUE}  → $1${NC}"; }

# ── Root check ────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Run as root: sudo bash $0${NC}"
  exit 1
fi

# Detect the real user (the one who ran sudo)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
  read -rp "  Username that will run GEIVS: " REAL_USER
fi
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# ── Banner ────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     GEIVS Pro — Server Hardening & Prep Script      ║${NC}"
echo -e "${CYAN}║   Ubuntu 22.04 / 24.04 · NVIDIA GPU · Docker        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Target user: ${BOLD}${REAL_USER}${NC}  (home: ${REAL_HOME})"
echo ""

# ── Step 1: Detect OS ─────────────────────────────────────────
step "Detecting OS"

if ! grep -qiE 'ubuntu' /etc/os-release 2>/dev/null; then
  err "This script is designed for Ubuntu 22.04 or 24.04."
  exit 1
fi

OS_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
ok "Ubuntu ${OS_VERSION}"

if [[ "$OS_VERSION" != "22.04" && "$OS_VERSION" != "24.04" ]]; then
  warn "Tested on 22.04 and 24.04 — proceeding anyway on ${OS_VERSION}"
fi

# Detect NVIDIA GPU hardware (used to gate driver + toolkit steps)
if lspci 2>/dev/null | grep -qi nvidia; then
  HAS_NVIDIA_HW=true
  ok "NVIDIA GPU hardware detected"
else
  warn "No NVIDIA GPU hardware detected — driver and toolkit steps will be skipped"
  warn "If this is a VM, run geivs-install.sh directly after this script (CPU mode auto-detected)"
fi

# ── Step 2: System Updates ────────────────────────────────────
step "Running system updates"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
apt-get autoremove -y -qq
ok "System packages updated"

# ── Step 3: Install Prerequisites ────────────────────────────
step "Installing prerequisites"

PACKAGES=(
  # Core tools
  curl wget git openssl gnupg ca-certificates
  # Python (needed by installer and n8n workflow activation)
  python3 python3-pip
  # Text / parsing utilities
  jq unzip zip
  # Monitoring / diagnostics
  htop iotop nethogs lsof net-tools dstat
  # System
  chrony            # accurate time — critical for automation workflows
  logrotate
  build-essential
  apt-transport-https
  software-properties-common
  # Security
  fail2ban
  unattended-upgrades
  # Useful extras
  tmux vim nano
)

apt-get install -y -qq "${PACKAGES[@]}"
ok "Prerequisites installed (${#PACKAGES[@]} packages)"

# ── Step 4: Configure Timezone & Time Sync ───────────────────
step "Configuring timezone and NTP"

DEFAULT_TZ="America/Chicago"
read -rp "  Timezone [${DEFAULT_TZ}]: " TZ_INPUT
TZ_INPUT=${TZ_INPUT:-$DEFAULT_TZ}
timedatectl set-timezone "$TZ_INPUT"
ok "Timezone set to $TZ_INPUT"

# Enable and start chrony for accurate time
systemctl enable chrony >/dev/null 2>&1
systemctl restart chrony
ok "Chrony NTP enabled"

# ── Step 5: NVIDIA Driver ─────────────────────────────────────
step "Installing NVIDIA drivers"

if [ "$HAS_NVIDIA_HW" = false ]; then
  warn "No NVIDIA GPU — skipping driver install (CPU mode)"
elif command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
  DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
  ok "NVIDIA driver already installed (version $DRIVER_VER)"
else
  info "Installing ubuntu-drivers and recommended NVIDIA driver..."
  apt-get install -y -qq ubuntu-drivers-common

  RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | grep recommended | awk '{print $3}' | head -1 || true)
  if [ -n "$RECOMMENDED" ]; then
    info "Recommended driver: $RECOMMENDED"
    apt-get install -y "$RECOMMENDED"
    ok "NVIDIA driver installed: $RECOMMENDED"
  else
    warn "No recommended driver found via ubuntu-drivers — install manually with: ubuntu-drivers autoinstall"
  fi
  REBOOT_REQUIRED=true
fi

# Enable NVIDIA persistence daemon (reduces model load latency)
if systemctl list-units --all | grep -q nvidia-persistenced 2>/dev/null; then
  systemctl enable nvidia-persistenced >/dev/null 2>&1 || true
  ok "NVIDIA persistence daemon enabled"
fi

# ── Step 6: Docker Engine ─────────────────────────────────────
step "Installing Docker Engine"

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
  DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || docker --version | awk '{print $3}' | tr -d ',')
  ok "Docker already installed (v${DOCKER_VER})"
else
  info "Installing Docker Engine via official install script..."
  curl -fsSL https://get.docker.com | sh
  ok "Docker installed"
fi

# Add real user to docker group
if ! groups "$REAL_USER" | grep -qw docker; then
  usermod -aG docker "$REAL_USER"
  ok "Added ${REAL_USER} to docker group"
else
  ok "${REAL_USER} already in docker group"
fi

# Enable and start Docker
systemctl enable docker >/dev/null 2>&1
systemctl start docker
ok "Docker daemon running"

# ── Step 7: NVIDIA Container Toolkit ─────────────────────────
step "Installing NVIDIA Container Toolkit"

if [ "$HAS_NVIDIA_HW" = false ]; then
  warn "No NVIDIA GPU — skipping Container Toolkit (CPU mode)"
  # Write basic Docker daemon config (log limits only, no nvidia runtime)
  cat > /etc/docker/daemon.json << 'DAEMONEOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "storage-driver": "overlay2"
}
DAEMONEOF
  systemctl restart docker
  ok "Docker configured with log limits (CPU mode)"
else
  if dpkg -l | grep -q nvidia-container-toolkit 2>/dev/null; then
    ok "nvidia-container-toolkit already installed"
  else
    info "Adding NVIDIA Container Toolkit repository..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

    apt-get update -qq
    apt-get install -y -qq nvidia-container-toolkit
    ok "nvidia-container-toolkit installed"
  fi

  # Configure Docker to use NVIDIA runtime by default
  nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1

  # Write Docker daemon config: NVIDIA as default runtime + log limits
  cat > /etc/docker/daemon.json << 'DAEMONEOF'
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "storage-driver": "overlay2"
}
DAEMONEOF

  systemctl restart docker
  ok "Docker configured with NVIDIA runtime as default"

  # Verify GPU passthrough (skip if reboot still required for new driver)
  if [ "$REBOOT_REQUIRED" = false ]; then
    if docker run --rm --runtime=nvidia --gpus all \
        nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi &>/dev/null; then
      ok "GPU passthrough to Docker verified"
    else
      warn "GPU passthrough test failed — reboot may be required"
    fi
  else
    warn "GPU passthrough will be verified after reboot"
  fi
fi

# ── Step 8: Swap File ─────────────────────────────────────────
step "Configuring swap"

CURRENT_SWAP=$(swapon --show --noheadings 2>/dev/null | wc -l)
if [ "$CURRENT_SWAP" -gt 0 ]; then
  SWAP_SIZE=$(swapon --show --noheadings 2>/dev/null | awk '{print $3}' | head -1)
  ok "Swap already configured ($SWAP_SIZE)"
else
  # Default: 32 GB swap for large AI models
  read -rp "  Swap file size in GB [32]: " SWAP_GB
  SWAP_GB=${SWAP_GB:-32}
  SWAPFILE=/swapfile

  if [ ! -f "$SWAPFILE" ]; then
    info "Creating ${SWAP_GB}GB swap file at $SWAPFILE..."
    fallocate -l "${SWAP_GB}G" "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
  fi

  swapon "$SWAPFILE"

  # Persist across reboots
  if ! grep -q "$SWAPFILE" /etc/fstab; then
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
  fi
  ok "${SWAP_GB}GB swap file created and enabled"
fi

# ── Step 9: Kernel / sysctl Tuning ───────────────────────────
step "Applying kernel tuning"

cat > /etc/sysctl.d/99-geivs.conf << 'SYSCTLEOF'
# ── Network security ──────────────────────────────────────────
# IP spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1
# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1
# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
# Log martian packets
net.ipv4.conf.all.log_martians = 1
# Disable IPv6 (optional — remove if you need it)
# net.ipv6.conf.all.disable_ipv6 = 1

# ── Performance for AI / Docker workloads ─────────────────────
# Reduce swap aggressiveness (prefer RAM, use swap for overflow)
vm.swappiness = 10
# Better dirty page handling for bulk writes (model downloads etc.)
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
# More inotify watches (n8n, Open WebUI use many)
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
# Higher file descriptor limits
fs.file-max = 2097152
# TCP performance
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
SYSCTLEOF

sysctl -p /etc/sysctl.d/99-geivs.conf >/dev/null 2>&1
ok "Kernel parameters applied"

# ── Step 10: System Limits ────────────────────────────────────
step "Setting system limits"

cat > /etc/security/limits.d/99-geivs.conf << 'LIMITSEOF'
# Open file / process limits for GEIVS (Docker, Ollama, n8n)
*    soft nofile  1048576
*    hard nofile  1048576
*    soft nproc   65536
*    hard nproc   65536
root soft nofile  1048576
root hard nofile  1048576
LIMITSEOF

# Also set limits in systemd
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-geivs.conf << 'SDEOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65536
SDEOF

ok "System limits configured (1M file handles, 64K processes)"

# ── Step 11: SSH Hardening ────────────────────────────────────
step "Hardening SSH"

SSHD_CONF=/etc/ssh/sshd_config

# Back up original
cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%Y%m%d)" 2>/dev/null || true

# Apply hardening settings
declare -A SSH_SETTINGS=(
  ["PermitRootLogin"]="no"
  ["PasswordAuthentication"]="yes"   # keep on — user may not have key auth set up yet
  ["X11Forwarding"]="no"
  ["MaxAuthTries"]="4"
  ["LoginGraceTime"]="20"
  ["ClientAliveInterval"]="300"
  ["ClientAliveCountMax"]="2"
  ["AllowAgentForwarding"]="no"
  ["AllowTcpForwarding"]="yes"       # needed for Tailscale SSH tunnelling
  ["PrintLastLog"]="yes"
  ["PermitEmptyPasswords"]="no"
)

for key in "${!SSH_SETTINGS[@]}"; do
  val="${SSH_SETTINGS[$key]}"
  if grep -qE "^#?${key}" "$SSHD_CONF"; then
    sed -i "s|^#*${key}.*|${key} ${val}|" "$SSHD_CONF"
  else
    echo "${key} ${val}" >> "$SSHD_CONF"
  fi
done

sshd -t && systemctl restart sshd
ok "SSH hardened (root login disabled, max auth tries = 4)"

# ── Step 12: Firewall (UFW) ───────────────────────────────────
step "Configuring firewall (UFW)"

apt-get install -y -qq ufw

# Reset to clean state (non-interactive)
ufw --force reset >/dev/null 2>&1

# Default policy
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# ─ Required ports ─
# SSH
ufw allow 22/tcp comment 'SSH' >/dev/null

# GEIVS web interface (nginx reverse proxy — all services go through here)
ufw allow 80/tcp  comment 'GEIVS HTTP' >/dev/null
ufw allow 443/tcp comment 'GEIVS HTTPS (future TLS)' >/dev/null

# Tailscale VPN (UDP — needed even if kernel module handles it)
ufw allow 41641/udp comment 'Tailscale VPN' >/dev/null

# Docker uses its own iptables rules for inter-container networking.
# UFW does not block Docker container-to-container or host-to-container traffic
# on bridge networks, so no extra rules are needed for internal services
# (Ollama 11434, n8n 5678, Open WebUI 3000, SearXNG 8080, etc.).
# They are only accessible externally via nginx on port 80.

# Enable UFW
ufw --force enable >/dev/null
ok "UFW enabled — allowed: 22/tcp (SSH), 80/tcp (HTTP), 443/tcp (HTTPS), 41641/udp (Tailscale)"
ufw status numbered 2>/dev/null | grep -E "ALLOW|DENY" | sed 's/^/    /'

# Fix Docker + UFW conflict: Docker bypasses UFW by default via iptables.
# Patch /etc/default/ufw to not flush iptables on reload
# and tell Docker to use iptables in a UFW-compatible way.
# The easiest production-safe fix is the DOCKER-USER chain approach.
cat > /etc/ufw/after.rules.geivs << 'UFWEOF'
# Rules appended by geivs-prep.sh
# Allow Docker containers to reach the host (needed for n8n ↔ signal-cli etc.)
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i docker0 -j ACCEPT
-A DOCKER-USER -o docker0 -j ACCEPT
COMMIT
UFWEOF
# Only append if not already there
if ! grep -q 'DOCKER-USER' /etc/ufw/after.rules 2>/dev/null; then
  cat /etc/ufw/after.rules.geivs >> /etc/ufw/after.rules
fi
rm -f /etc/ufw/after.rules.geivs

ok "UFW/Docker iptables compatibility configured"

# ── Step 13: fail2ban ─────────────────────────────────────────
step "Configuring fail2ban"

cat > /etc/fail2ban/jail.local << 'F2BEOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = auto
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 4
bantime  = 7200

[nginx-http-auth]
enabled  = false

[nginx-botsearch]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/access.log
maxretry = 8
bantime  = 3600
F2BEOF

systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
ok "fail2ban configured (SSH: 4 attempts → 2h ban)"

# ── Step 14: Automatic Security Updates ──────────────────────
step "Enabling automatic security updates"

cat > /etc/apt/apt.conf.d/50unattended-upgrades-geivs << 'UUEOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
UUEOF

cat > /etc/apt/apt.conf.d/20auto-upgrades-geivs << 'AUGEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUGEOF

systemctl enable unattended-upgrades >/dev/null 2>&1
systemctl start unattended-upgrades
ok "Automatic security updates enabled (no auto-reboot)"

# ── Final Summary ─────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          GEIVS Server Preparation Complete               ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} System updated & prerequisites installed              ${CYAN}║${NC}"
if [ "$HAS_NVIDIA_HW" = true ]; then
echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} NVIDIA driver installed                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} Docker Engine + NVIDIA Container Toolkit             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} Docker default runtime → nvidia                      ${CYAN}║${NC}"
else
echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} Docker Engine installed (CPU mode)                   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${YELLOW}○${NC} No NVIDIA GPU detected — CPU mode                    ${CYAN}║${NC}"
fi
echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} Swap file configured                                 ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} Kernel hardening + performance tuning                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} SSH hardened (root login disabled)                   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} UFW firewall active (22, 80, 443, 41641)             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} fail2ban protecting SSH                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} Automatic security updates enabled                   ${CYAN}║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}Next Step${NC}                                               ${CYAN}║${NC}"
if [ "$REBOOT_REQUIRED" = true ]; then
echo -e "${CYAN}║${NC}  ${YELLOW}⚠${NC}  REBOOT REQUIRED before running geivs-install.sh    ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     Run: ${BOLD}sudo reboot${NC}                                      ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     Then: ${BOLD}bash geivs-install.sh${NC}                           ${CYAN}║${NC}"
else
echo -e "${CYAN}║${NC}  Run: ${BOLD}bash geivs-install.sh${NC}                             ${CYAN}║${NC}"
fi
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
[ "$REBOOT_REQUIRED" = true ] && echo -e "${YELLOW}  System will need a reboot to activate NVIDIA drivers.${NC}"
echo -e "  Log out and back in (or reboot) so the docker group takes effect for ${BOLD}${REAL_USER}${NC}."
echo ""
