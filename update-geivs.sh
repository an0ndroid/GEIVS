#!/bin/bash
# =============================================================
# GEIVS Pro — Update Script
# Updates all Docker images and Ollama models
# Usage: ./update-geivs.sh
# =============================================================

set -e

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.pro.yml}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         GEIVS Pro — Update Manager               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_banner

# --- Step 1: Pull latest Docker images ---
echo -e "${BLUE}Step 1/3 — Pulling latest Docker images...${NC}"
docker compose -f "$COMPOSE_FILE" pull
echo -e "${GREEN}✓ Docker images updated${NC}"
echo ""

# --- Step 2: Restart services with new images ---
echo -e "${BLUE}Step 2/3 — Restarting GEIVS services...${NC}"
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans
echo -e "${GREEN}✓ Services restarted${NC}"
echo ""

# --- Step 3: Update Ollama models ---
echo -e "${BLUE}Step 3/3 — Updating Ollama models...${NC}"
./pull-models.sh --update
echo ""

# --- Cleanup old images ---
echo -e "${YELLOW}Cleaning up old Docker images...${NC}"
docker image prune -f
echo -e "${GREEN}✓ Cleanup complete${NC}"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         GEIVS Pro update complete                ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
