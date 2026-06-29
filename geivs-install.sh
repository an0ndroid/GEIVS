#!/bin/bash
# =============================================================
# GEIVS Pro — Self-Hosted AI Butler Platform Installer
# Supports: Ubuntu 22.04 / 24.04, NVIDIA GPU, AMD GPU, CPU-only
# Usage: bash geivs-install.sh [--dry-run] [--help]
# =============================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DRY_RUN=false
STEP=0
TOTAL_STEPS=17

# ── Flags ─────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --help)
      echo "Usage: bash geivs-install.sh [--dry-run] [--help]"
      echo "  --dry-run   Show what would be done without making changes"
      echo "  --help      Show this help"
      exit 0 ;;
  esac
done

step() {
  STEP=$((STEP+1))
  echo ""
  echo -e "${CYAN}── Step ${STEP}/${TOTAL_STEPS}: $1 ${NC}"
}

ok()   { echo -e "${GREEN}  ✓ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }
err()  { echo -e "${RED}  ✗ $1${NC}"; }
run()  {
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}  [dry-run] $*${NC}"
  else
    "$@"
  fi
}

# ── Banner ────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       GEIVS Pro — AI Butler Platform Installer       ║${NC}"
echo -e "${CYAN}║         Self-hosted · Private · Production-ready     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
[ "$DRY_RUN" = true ] && echo -e "${YELLOW}  DRY RUN MODE — no changes will be made${NC}\n"

# ── Step 1: Prerequisites ─────────────────────────────────────
step "Checking prerequisites"

install_docker() {
  echo -e "${BLUE}  Installing Docker...${NC}"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  ok "Docker installed (you may need to log out and back in)"
}

if ! command -v docker &>/dev/null; then
  warn "Docker not found — installing"
  run install_docker
else
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"
fi

if ! docker compose version &>/dev/null; then
  err "Docker Compose plugin not available. Update Docker or install manually."
  echo "    https://docs.docker.com/compose/install/"
  exit 1
fi
ok "Docker Compose $(docker compose version --short)"

for pkg in curl openssl python3 git; do
  if ! command -v "$pkg" &>/dev/null; then
    warn "$pkg not found — installing"
    run sudo apt-get install -y "$pkg" -qq
  else
    ok "$pkg"
  fi
done

# ── Step 2: GPU Detection ─────────────────────────────────────
step "Detecting GPU"

GPU_MODE="cpu"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
  GPU_MODE="nvidia"
  GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)
  ok "NVIDIA GPU detected: $GPU_INFO"
elif [ -e /dev/kfd ] || command -v rocminfo &>/dev/null; then
  GPU_MODE="amd"
  ok "AMD GPU detected (ROCm)"
else
  warn "No GPU detected — running in CPU-only mode"
  warn "Performance will be limited. A dedicated GPU is recommended."
fi
echo -e "  ${BOLD}Mode: ${GPU_MODE^^}${NC}"

# ── Step 3: User Input ────────────────────────────────────────
step "Gathering configuration"

DEFAULT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
DEFAULT_TZ="America/Chicago"

if [ "$GPU_MODE" = "cpu" ]; then
  DEFAULT_MODEL="qwen2.5:7b"
else
  DEFAULT_MODEL="gemma3:12b"
fi

echo ""
read -rp "  Server IP or hostname [$DEFAULT_IP]: " GEIVS_HOST
GEIVS_HOST=${GEIVS_HOST:-$DEFAULT_IP}

read -rp "  Admin email [admin@geivs.local]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@geivs.local}

while true; do
  read -rsp "  Admin password: " ADMIN_PASSWORD; echo ""
  read -rsp "  Confirm password: " ADMIN_PASSWORD2; echo ""
  [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD2" ] && break
  err "Passwords do not match, try again."
done

read -rp "  Business name [My Business]: " BUSINESS_NAME
BUSINESS_NAME=${BUSINESS_NAME:-My Business}

read -rp "  Butler persona name [GEIVS]: " PERSONA_NAME
PERSONA_NAME=${PERSONA_NAME:-GEIVS}

read -rp "  Timezone [$DEFAULT_TZ]: " TZ
TZ=${TZ:-$DEFAULT_TZ}

echo "  Primary AI model options:"
echo "    1) qwen2.5:7b   (fast, 4.7GB)"
echo "    2) gemma3:12b   (balanced, 8.1GB)"
echo "    3) llama3.3:70b (powerful, 42GB — needs lots of RAM)"
read -rp "  Choose [default: $DEFAULT_MODEL]: " MODEL_CHOICE
case $MODEL_CHOICE in
  1) PRIMARY_MODEL="qwen2.5:7b" ;;
  2) PRIMARY_MODEL="gemma3:12b" ;;
  3) PRIMARY_MODEL="llama3.3:70b" ;;
  *) PRIMARY_MODEL="$DEFAULT_MODEL" ;;
esac

read -rp "  Tailscale auth key (leave blank to skip): " TAILSCALE_KEY
read -rp "  Timezone [$DEFAULT_TZ]: " TZ_CONFIRM
[ -n "$TZ_CONFIRM" ] && TZ="$TZ_CONFIRM"

ok "Configuration collected"

# ── Step 4: Generate Secrets ──────────────────────────────────
step "Generating secrets"

WEBUI_SECRET_KEY=$(openssl rand -hex 32)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
CRAWL4AI_TOKEN=$(openssl rand -hex 16)
DB_PASSWORD=$(openssl rand -hex 16)
ok "All secrets generated"

# ── Step 5: Directory Structure ───────────────────────────────
step "Creating directory structure"

GEIVS_DIR="$HOME/geivs"
run mkdir -p "$GEIVS_DIR"/{nginx,n8n-workflows,logs}
ok "Directories created at $GEIVS_DIR"

# ── Step 6: Write .env ────────────────────────────────────────
step "Writing environment file"

if [ "$DRY_RUN" = false ]; then
cat > "$GEIVS_DIR/.env" << ENV
# GEIVS Pro — Environment Configuration
# Generated by installer on $(date)

GEIVS_HOST=${GEIVS_HOST}
BUSINESS_NAME=${BUSINESS_NAME}
PERSONA_NAME=${PERSONA_NAME}
TZ=${TZ}
GPU_MODE=${GPU_MODE}
PRIMARY_MODEL=${PRIMARY_MODEL}

# Auth
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}

# Secrets
WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
JWT_SECRET=${JWT_SECRET}
CRAWL4AI_TOKEN=${CRAWL4AI_TOKEN}
DB_PASSWORD=${DB_PASSWORD}

# n8n
N8N_HOST=${GEIVS_HOST}
N8N_PORT=5678
N8N_PROTOCOL=http
WEBHOOK_URL=http://${GEIVS_HOST}/automation/

# Open WebUI
OPENWEBUI_API_KEY=$(openssl rand -hex 24)

# Postiz DB
POSTGRES_PASSWORD=${DB_PASSWORD}
ENV
chmod 600 "$GEIVS_DIR/.env"
fi
ok ".env written (permissions 600)"

# ── Step 7: Download Compose File ────────────────────────────
step "Downloading docker-compose configuration"

REPO_RAW="https://raw.githubusercontent.com/an0ndroid/GEIVS/main"

download_or_warn() {
  local url="$1" dest="$2"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}  [dry-run] curl -fsSL $url -> $dest${NC}"
    return 0
  fi
  if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
    ok "Downloaded $(basename "$dest")"
  else
    warn "Could not download $(basename "$dest") from $url"
    return 1
  fi
}

if ! download_or_warn "$REPO_RAW/docker-compose.pro.yml" "$GEIVS_DIR/docker-compose.pro.yml"; then
  err "Could not download docker-compose.pro.yml"
  echo "    Place it manually at: $GEIVS_DIR/docker-compose.pro.yml"
  echo "    Then re-run: bash $0"
  exit 1
fi

# Strip GPU blocks if CPU-only mode
if [ "$GPU_MODE" = "cpu" ] && [ "$DRY_RUN" = false ]; then
  python3 - "$GEIVS_DIR/docker-compose.pro.yml" << 'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
content = re.sub(
    r'\s*deploy:\s*\n\s*resources:\s*\n\s*reservations:\s*\n\s*devices:\s*\n(?:\s*-[^\n]*\n)+',
    '\n', content)
content = content.replace('latest-cuda', 'latest-cpu')
content = content.replace('WHISPER__MODEL=medium', 'WHISPER__MODEL=tiny')
content = content.replace('WHISPER__DEVICE=cuda', 'WHISPER__DEVICE=cpu')
open(sys.argv[1], 'w').write(content)
PYEOF
  ok "GPU blocks stripped, Whisper set to CPU/tiny (CPU-only mode)"
fi

# ── Step 8: Download nginx Config ────────────────────────────
step "Downloading nginx configuration"

if ! download_or_warn "$REPO_RAW/nginx/geivs.conf" "$GEIVS_DIR/nginx/geivs.conf"; then
  warn "Writing minimal fallback nginx config"
  if [ "$DRY_RUN" = false ]; then
  cat > "$GEIVS_DIR/nginx/geivs.conf" << 'NGINXEOF'
server {
    listen 80;
    server_name _;
    resolver 127.0.0.11 valid=30s;
    client_max_body_size 100M;
    location / {
        set $upstream http://openwebui:8080;
        proxy_pass $upstream;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
    }
    location /automation/ {
        set $upstream http://n8n:5678;
        rewrite ^/automation/(.*)$ /$1 break;
        proxy_pass $upstream;
        proxy_set_header Host $host;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location /monitor/ {
        set $upstream http://uptime-kuma:3001;
        rewrite ^/monitor/(.*)$ /$1 break;
        proxy_pass $upstream;
        proxy_set_header Host $host;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location /crawl4ai/ {
        allow 10.0.0.0/8; allow 172.16.0.0/12; allow 192.168.0.0/16; deny all;
        set $upstream http://crawl4ai:11235;
        rewrite ^/crawl4ai/(.*)$ /$1 break;
        proxy_pass $upstream;
        proxy_set_header Host $host;
        proxy_read_timeout 300s;
    }
    location /ollama/ {
        allow 10.0.0.0/8; allow 172.16.0.0/12; allow 192.168.0.0/16; deny all;
        set $upstream http://ollama:11434;
        rewrite ^/ollama/(.*)$ /$1 break;
        proxy_pass $upstream;
        proxy_set_header Host $host;
        proxy_read_timeout 300s;
    }
}
NGINXEOF
  fi
fi

# ── Step 9: Download Workflows ────────────────────────────────
step "Downloading n8n workflows"

for wf in \
  geivs-signal-bot geivs-email-bot geivs-daily-briefing geivs-email-draft \
  geivs-calendar-integration geivs-dashboard \
  geivs-email-transcription geivs-signal-transcription \
  geivs-calendar-setup geivs-email-setup geivs-signal-setup \
  geivs-storage-setup geivs-telegram-setup; do
  download_or_warn "$REPO_RAW/n8n-workflows/${wf}.json" "$GEIVS_DIR/n8n-workflows/${wf}.json" || true
done

# ── Step 10: Download Onboarding Files ───────────────────────
step "Downloading onboarding and support files"

download_or_warn "$REPO_RAW/onboarding-init.sh" "$GEIVS_DIR/onboarding-init.sh" || true
download_or_warn "$REPO_RAW/geivs-system-prompt.md" "$GEIVS_DIR/geivs-system-prompt.md" || true
# geivs-state.json is bind-mounted into geivs-init container — must exist before compose up
download_or_warn "$REPO_RAW/geivs-state.json" "$GEIVS_DIR/geivs-state.json" || true
# Model pull scripts — bind-mounted and available for manual use
download_or_warn "$REPO_RAW/pull-models.sh" "$GEIVS_DIR/pull-models.sh" || true
download_or_warn "$REPO_RAW/pull-models-cpu.sh" "$GEIVS_DIR/pull-models-cpu.sh" || true
# Update script
download_or_warn "$REPO_RAW/update-geivs.sh" "$GEIVS_DIR/update-geivs.sh" || true
if [ "$DRY_RUN" = false ]; then
  chmod +x "$GEIVS_DIR/onboarding-init.sh" 2>/dev/null || true
  chmod +x "$GEIVS_DIR/pull-models.sh" 2>/dev/null || true
  chmod +x "$GEIVS_DIR/pull-models-cpu.sh" 2>/dev/null || true
  chmod +x "$GEIVS_DIR/update-geivs.sh" 2>/dev/null || true
fi

# ── Step 11: Start the Stack ──────────────────────────────────
step "Starting GEIVS stack"

if [ "$DRY_RUN" = false ]; then
  cd "$GEIVS_DIR"
  docker compose -f docker-compose.pro.yml --env-file .env up -d 2>&1 | \
    grep -E "(Started|Created|Pulled|Error|error)" || true
  ok "Stack started"

  # Enable JSON format in SearXNG (required for Open WebUI web search)
  # Retry loop: SearXNG generates settings.yml on first boot which can take 30-60s
  echo -e "  ${BLUE}Waiting for SearXNG to initialise...${NC}"
  SEARXNG_PATCHED=false
  for attempt in $(seq 1 15); do
    PATCH_RESULT=$(docker exec geivs_searxng python3 -c "
import re, sys
f = '/etc/searxng/settings.yml'
try:
    c = open(f).read()
    if '- json' not in c:
        c = re.sub(r'(  formats:\n    - html)', r'\1\n    - json', c)
        open(f, 'w').write(c)
        print('patched')
    else:
        print('already_patched')
except Exception as e:
    print('not_ready')
    sys.exit(1)
" 2>/dev/null || true)
    if [ "$PATCH_RESULT" = "patched" ]; then
      docker restart geivs_searxng >/dev/null 2>&1 || true
      ok "SearXNG JSON format enabled (Open WebUI web search will work)"
      SEARXNG_PATCHED=true
      break
    elif [ "$PATCH_RESULT" = "already_patched" ]; then
      ok "SearXNG JSON format already enabled"
      SEARXNG_PATCHED=true
      break
    fi
    sleep 4
  done
  [ "$SEARXNG_PATCHED" = false ] && \
    warn "SearXNG JSON patch failed — add '- json' under search.formats in /etc/searxng/settings.yml"
else
  echo -e "${BLUE}  [dry-run] docker compose up -d${NC}"
  echo -e "${BLUE}  [dry-run] patch SearXNG JSON format${NC}"
fi

# ── Step 12: Wait for Open WebUI ──────────────────────────────
step "Waiting for Open WebUI to be ready"

if [ "$DRY_RUN" = false ]; then
  echo -n "  Waiting"
  for i in $(seq 1 60); do
    if curl -sf http://localhost:3000/health &>/dev/null; then
      echo ""
      ok "Open WebUI is ready"
      break
    fi
    echo -n "."
    sleep 3
    if [ "$i" = "60" ]; then
      echo ""
      warn "Open WebUI did not become ready in 3 minutes — continuing anyway"
    fi
  done
fi

# ── Step 13: Run Onboarding ───────────────────────────────────
step "Running first-boot onboarding"

if [ "$DRY_RUN" = false ] && [ -f "$GEIVS_DIR/onboarding-init.sh" ]; then
  OPENWEBUI_URL=http://localhost:3000 \
  OLLAMA_URL=http://localhost:11434 \
  STATE_FILE="$GEIVS_DIR/geivs-state.json" \
  SYSTEM_PROMPT_FILE="$GEIVS_DIR/geivs-system-prompt.md" \
  ADMIN_EMAIL="$ADMIN_EMAIL" \
  ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  ADMIN_NAME="$BUSINESS_NAME Admin" \
  bash "$GEIVS_DIR/onboarding-init.sh" || warn "Onboarding had errors — check logs"
else
  [ "$DRY_RUN" = true ] && echo -e "${BLUE}  [dry-run] run onboarding-init.sh${NC}"
  [ ! -f "$GEIVS_DIR/onboarding-init.sh" ] && warn "onboarding-init.sh not found, skipping"
fi

# ── Step 14: Pull Primary Model ───────────────────────────────
step "Starting AI model download"

if [ "$DRY_RUN" = false ]; then
  docker exec geivs_ollama ollama pull "$PRIMARY_MODEL" > "$GEIVS_DIR/logs/model-pull.log" 2>&1 &
  ok "Pulling $PRIMARY_MODEL in background (tail $GEIVS_DIR/logs/model-pull.log to watch)"
else
  echo -e "${BLUE}  [dry-run] ollama pull $PRIMARY_MODEL${NC}"
fi

# ── Step 15: Import n8n Workflows ────────────────────────────
step "Importing n8n workflows"

if [ "$DRY_RUN" = false ]; then
  # Wait a moment for n8n to settle
  sleep 5
  N8N_WF_DIR="$GEIVS_DIR/n8n-workflows"
  if docker exec geivs_n8n test -d /home/node/.n8n &>/dev/null; then
    # Copy workflows into container and import
    for wf in "$N8N_WF_DIR"/*.json; do
      [ -f "$wf" ] || continue
      fname=$(basename "$wf")
      docker cp "$wf" "geivs_n8n:/tmp/$fname" 2>/dev/null || true
    done
    docker exec geivs_n8n n8n import:workflow --separate --input=/tmp/ 2>/dev/null && \
      ok "Workflows imported" || warn "Workflow import failed — import manually via n8n UI"
  else
    warn "n8n container not ready — import workflows manually via the n8n UI at http://$GEIVS_HOST/automation/"
  fi
else
  echo -e "${BLUE}  [dry-run] import n8n workflows${NC}"
fi

# ── Step 16: Tailscale ────────────────────────────────────────
step "Configuring Tailscale remote access"

if [ -n "${TAILSCALE_KEY:-}" ]; then
  if [ "$DRY_RUN" = false ]; then
    if ! command -v tailscale &>/dev/null; then
      echo -e "${BLUE}  Installing Tailscale...${NC}"
      curl -fsSL https://tailscale.com/install.sh | sh
    fi
    sudo tailscale up --authkey="$TAILSCALE_KEY" --hostname="geivs-$(hostname)" --ssh 2>/dev/null || \
      warn "Tailscale auth failed — run 'sudo tailscale up' manually"
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
    ok "Tailscale connected — IP: $TS_IP"
  else
    echo -e "${BLUE}  [dry-run] tailscale up --authkey=... --hostname=geivs-$(hostname)${NC}"
  fi
else
  warn "No Tailscale key provided — skipping (add later with: sudo tailscale up)"
fi

# ── Step 17: Final Summary ────────────────────────────────────
step "Installation complete"

TS_IP=""
command -v tailscale &>/dev/null && TS_IP=$(tailscale ip -4 2>/dev/null || true)

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              GEIVS Installation Complete                 ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}Access URLs${NC}                                             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Web UI:       http://${GEIVS_HOST}                          ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Automation:   http://${GEIVS_HOST}/automation/               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Monitoring:   http://${GEIVS_HOST}/monitor/                  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Image Gen:    http://${GEIVS_HOST}/imagine/                  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Search:       http://${GEIVS_HOST}/search/                   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Portainer:    http://${GEIVS_HOST}/portainer/                ${CYAN}║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}Credentials${NC}                                             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Email:        ${ADMIN_EMAIL}                   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Password:     ${ADMIN_PASSWORD}                            ${CYAN}║${NC}"
[ -n "$TS_IP" ] && \
echo -e "${CYAN}║${NC}  Tailscale:    ${TS_IP}                                  ${CYAN}║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}Next Steps${NC}                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  1. Open the Web UI and sign in                          ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  2. Go to /automation/ → add email credentials           ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  3. Configure Signal number in /automation/               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  4. Add Google Calendar OAuth in n8n credentials         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  5. Wait for model download to finish, then chat!        ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Config saved to: ${BOLD}$GEIVS_DIR/.env${NC}"
echo -e "  Model pull log:  ${BOLD}$GEIVS_DIR/logs/model-pull.log${NC}"
echo ""
