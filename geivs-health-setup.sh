#!/bin/bash
# =============================================================
# GEIVS Host Health Service Setup
# Installs the system_health service (:4090) as a host systemd unit — the one
# GEIVS component that must run on the host (it reads CPU/temps/SMART/docker.sock,
# which a container can't cleanly do). The dashboard's "Server Health" tile
# proxies to it via nginx (/api/health -> host.docker.internal:4090).
#
# Needs root (apt + systemd + ufw). The GEIVS installer calls it with sudo;
# to run standalone:  sudo bash geivs-health-setup.sh
# Safe to re-run.
# =============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }
err()  { echo -e "${RED}  ✗ $1${NC}"; }
info() { echo -e "${BLUE}  → $1${NC}"; }

if [ "$EUID" -ne 0 ]; then
  err "This needs root. Re-run: sudo bash $0"
  exit 1
fi

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/an0ndroid/GEIVS/main}"
GATEWAY_RAW="${GATEWAY_RAW:-$REPO_RAW/geivs-gateway}"
HEALTH_DIR="${HEALTH_DIR:-/opt/geivs-health}"
PORT="${HEALTH_PORT:-4090}"
# Run the service as the invoking (non-root) user when known, so it isn't root;
# it still reaches smartctl/docker via `sudo -n` (see sudoers rule below).
RUN_USER="${SUDO_USER:-root}"

echo ""
echo -e "${CYAN}── GEIVS Host Health Service ${NC}"

# ── 1. Dependencies ──────────────────────────────────────────
info "Installing dependencies (python3-psutil, smartmontools, lm-sensors)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq python3 python3-psutil smartmontools lm-sensors curl || \
  warn "some packages failed to install — health may be partial (temps/SMART)"

# ── 2. Fetch the service code ────────────────────────────────
info "Fetching service code to $HEALTH_DIR"
mkdir -p "$HEALTH_DIR"
fetch() {  # url dest
  if curl -fsSL "$1" -o "$2" 2>/dev/null; then ok "$(basename "$2")"; else err "download failed: $1"; return 1; fi
}
fetch "$GATEWAY_RAW/services/system_health.py" "$HEALTH_DIR/system_health.py"
fetch "$GATEWAY_RAW/services/common.py"        "$HEALTH_DIR/common.py"

# ── 3. sudoers: let the service user read SMART + docker without a password ──
# smartctl needs root for raw disk access; docker ps needs the docker socket.
if [ "$RUN_USER" != "root" ]; then
  SMARTCTL="$(command -v smartctl || echo /usr/sbin/smartctl)"
  DOCKER_BIN="$(command -v docker || echo /usr/bin/docker)"
  cat > /etc/sudoers.d/geivs-health <<SUDOEOF
$RUN_USER ALL=(root) NOPASSWD: $SMARTCTL, $DOCKER_BIN ps *
SUDOEOF
  chmod 440 /etc/sudoers.d/geivs-health
  visudo -cf /etc/sudoers.d/geivs-health >/dev/null 2>&1 && ok "sudoers rule for $RUN_USER (smartctl, docker ps)" \
    || { rm -f /etc/sudoers.d/geivs-health; warn "sudoers rule invalid — removed; SMART/containers may be blank"; }
fi

# ── 4. systemd unit ──────────────────────────────────────────
info "Installing systemd unit geivs-health.service (runs as $RUN_USER, binds 0.0.0.0:$PORT)"
cat > /etc/systemd/system/geivs-health.service <<UNITEOF
[Unit]
Description=GEIVS system health service (:$PORT)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$HEALTH_DIR
# 0.0.0.0 so the nginx container reaches it via host.docker.internal.
Environment=GEIVS_BINDS=0.0.0.0
Environment=HEALTH_PORT=$PORT
ExecStart=/usr/bin/python3 $HEALTH_DIR/system_health.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable --now geivs-health.service >/dev/null 2>&1
ok "geivs-health.service enabled + started"

# ── 5. Firewall: allow the docker bridge networks to reach :$PORT ────────────
# Containers hit the host at its docker-gateway IP (172.16.0.0/12). UFW's
# default-deny INPUT would otherwise block nginx -> host:$PORT.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
  ufw allow from 172.16.0.0/12 to any port "$PORT" proto tcp >/dev/null 2>&1 \
    && ok "UFW: allowed 172.16.0.0/12 -> :$PORT (docker bridges)" \
    || warn "UFW rule for :$PORT failed — add manually if the health tile 500s"
fi

# ── 6. Verify ────────────────────────────────────────────────
sleep 1
if curl -sf "http://127.0.0.1:$PORT/health.json" >/dev/null 2>&1; then
  ok "Health endpoint responding on 127.0.0.1:$PORT"
else
  warn "Health endpoint not responding yet — check: journalctl -u geivs-health -n 30"
fi
echo ""
