#!/bin/bash
# =============================================================
# GEIVS Gateway Setup
# Fetches the containerized gateway (bridge / shim / render / email),
# writes its secrets, and brings it up alongside the main GEIVS stack.
#
# Layout it creates (all siblings under $HOME, matching the overlay's
# relative paths ../geivs-gateway and ../geivs-secrets):
#   ~/geivs             — the main stack (docker-compose.pro.yml, .env)
#   ~/geivs-gateway     — gateway image source + docker-compose.gateway.yml
#   ~/geivs-secrets     — jeeves-bridge.env, jeeves-email.env (mode 600)
#
# Secrets are taken from the environment when set (the installer passes what
# it already collected), otherwise prompted for. Safe to re-run.
#
# Usage (standalone):  bash geivs-gateway-setup.sh
# Usage (from installer): OWNER_SIGNAL=+1... GMAIL_USER=... GMAIL_PASS=... \
#                         GEIVS_DIR=~/geivs bash geivs-gateway-setup.sh
# =============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }
err()  { echo -e "${RED}  ✗ $1${NC}"; }
info() { echo -e "${BLUE}  → $1${NC}"; }

# The gateway ships as a subdirectory of the GEIVS repo. Override GATEWAY_RAW to
# point elsewhere (e.g. a standalone repo) if you publish it separately.
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/an0ndroid/GEIVS/main}"
GATEWAY_RAW="${GATEWAY_RAW:-$REPO_RAW/geivs-gateway}"

GEIVS_DIR="${GEIVS_DIR:-$HOME/geivs}"
PARENT_DIR="$(dirname "$GEIVS_DIR")"
GATEWAY_DIR="$PARENT_DIR/geivs-gateway"
SECRETS_DIR="$PARENT_DIR/geivs-secrets"

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.pro.yml}"

echo ""
echo -e "${CYAN}── GEIVS Gateway Setup ${NC}"

if [ ! -f "$GEIVS_DIR/$COMPOSE_FILE" ]; then
  err "Main stack not found at $GEIVS_DIR/$COMPOSE_FILE — run the GEIVS installer first."
  exit 1
fi

# ── 1. Fetch the gateway source ──────────────────────────────
info "Downloading gateway source to $GATEWAY_DIR"
mkdir -p "$GATEWAY_DIR/services"

fetch() {  # url dest
  if curl -fsSL "$1" -o "$2" 2>/dev/null; then
    ok "$(basename "$2")"
  else
    err "Could not download $(basename "$2") from $1"
    return 1
  fi
}

# The Dockerfile COPYs services/ wholesale, so fetch every service module.
fetch "$GATEWAY_RAW/Dockerfile" "$GATEWAY_DIR/Dockerfile"
fetch "$GATEWAY_RAW/docker-compose.gateway.yml" "$GATEWAY_DIR/docker-compose.gateway.yml"
for svc in common.py bridge.py openai_shim.py render-bridge.py \
           jeeves-email-server.py system_health.py; do
  fetch "$GATEWAY_RAW/services/$svc" "$GATEWAY_DIR/services/$svc"
done

# ── 2. Collect secrets (env wins; otherwise prompt) ──────────
info "Writing gateway secrets to $SECRETS_DIR"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

if [ -z "${OWNER_SIGNAL:-}" ]; then
  echo -e "  ${BOLD}The gateway's Signal bridge only accepts commands from an allow-list.${NC}"
  read -rp "  Your personal Signal number (allowed to command GEIVS, e.g. +12125551234): " OWNER_SIGNAL < /dev/tty
fi
if [ -z "${GMAIL_USER:-}" ]; then
  read -rp "  Gmail address for the email service (blank to skip email service): " GMAIL_USER < /dev/tty
fi
if [ -n "${GMAIL_USER:-}" ] && [ -z "${GMAIL_PASS:-}" ]; then
  read -rsp "  Gmail app password: " GMAIL_PASS < /dev/tty; echo ""
fi

umask 177
if [ -n "${OWNER_SIGNAL:-}" ]; then
  printf 'JEEVES_OWNERS=%s\n' "$OWNER_SIGNAL" > "$SECRETS_DIR/jeeves-bridge.env"
  ok "jeeves-bridge.env (Signal allow-list)"
else
  warn "No owner number given — the Signal bridge will reject all senders until you edit $SECRETS_DIR/jeeves-bridge.env"
  printf 'JEEVES_OWNERS=\n' > "$SECRETS_DIR/jeeves-bridge.env"
fi
if [ -n "${GMAIL_USER:-}" ]; then
  printf 'GMAIL_USER=%s\nGMAIL_PASS=%s\n' "$GMAIL_USER" "${GMAIL_PASS:-}" > "$SECRETS_DIR/jeeves-email.env"
  ok "jeeves-email.env (Gmail IMAP/SMTP)"
else
  # File must exist — the overlay references it via env_file.
  printf 'GMAIL_USER=\nGMAIL_PASS=\n' > "$SECRETS_DIR/jeeves-email.env"
  warn "No Gmail given — the email service container will idle until you fill $SECRETS_DIR/jeeves-email.env"
fi
umask 022

# ── 3. Build + start the gateway overlay ─────────────────────
info "Building and starting the gateway containers (first build pulls Chromium — a few minutes)"
cd "$GEIVS_DIR"
docker compose \
  -f "$COMPOSE_FILE" \
  -f "$GATEWAY_DIR/docker-compose.gateway.yml" \
  --env-file .env \
  up -d --build geivs-bridge geivs-shim geivs-render geivs-email 2>&1 \
  | grep -E "(Building|Built|Created|Started|Error|error)" || true

echo ""
ok "Gateway services up: geivs-bridge, geivs-shim, geivs-render, geivs-email"
echo -e "  ${BOLD}Note:${NC} the ${BOLD}Server Health${NC} dashboard tile needs the host-side"
echo -e "  system_health service (:4090) — not started here; see docs to run it as a host service."
echo ""
