#!/bin/bash
# =============================================================
# GEIVS Pro — Model Pull Script
# Run after docker compose is up to pull all required models
# Usage: ./pull-models.sh
# Optional: ./pull-models.sh --update (pulls latest versions)
# =============================================================

set -e

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
UPDATE_MODE=false

# Parse args
if [[ "$1" == "--update" ]]; then
    UPDATE_MODE=true
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================
# Model definitions
# Format: "name:tag|description|vram_required_gb"
# =============================================================

MODELS=(
    "llama3.3:70b|Best all-around conversationalist — primary model|40"
    "qwen2.5:72b|Strong reasoning and multilingual support|40"
    "gemma3:27b|Google's best open model, natural conversation|16"
    "qwen2.5:9b|Fast lightweight model for quick tasks|6"
)

# =============================================================
# Helper functions
# =============================================================

print_banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         GEIVS Pro — Model Manager                ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

check_ollama() {
    echo -e "${BLUE}Checking Ollama connection at ${OLLAMA_HOST}...${NC}"
    for i in {1..10}; do
        if curl -sf "${OLLAMA_HOST}/api/tags" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Ollama is running${NC}"
            return 0
        fi
        echo -e "${YELLOW}  Waiting for Ollama... (${i}/10)${NC}"
        sleep 5
    done
    echo -e "${RED}✗ Could not connect to Ollama at ${OLLAMA_HOST}${NC}"
    echo -e "${RED}  Make sure GEIVS is running: docker compose -f docker-compose.pro.yml up -d${NC}"
    exit 1
}

get_installed_models() {
    curl -sf "${OLLAMA_HOST}/api/tags" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//'
}

model_is_installed() {
    local model="$1"
    get_installed_models | grep -q "^${model}$"
}

pull_model() {
    local model="$1"
    local description="$2"
    local vram="$3"

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Model:${NC}       ${model}"
    echo -e "${BLUE}Purpose:${NC}     ${description}"
    echo -e "${BLUE}VRAM needed:${NC} ~${vram}GB"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if model_is_installed "$model" && [ "$UPDATE_MODE" = false ]; then
        echo -e "${GREEN}✓ Already installed — skipping (use --update to force refresh)${NC}"
        return 0
    fi

    echo -e "${YELLOW}Pulling ${model}...${NC}"
    if curl -sf -X POST "${OLLAMA_HOST}/api/pull" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${model}\", \"stream\": false}" \
        --max-time 3600 > /dev/null; then
        echo -e "${GREEN}✓ ${model} installed successfully${NC}"
    else
        echo -e "${RED}✗ Failed to pull ${model}${NC}"
        echo -e "${YELLOW}  You can retry manually: docker exec geivs_ollama ollama pull ${model}${NC}"
    fi
}

print_summary() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              Installed Models                    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    get_installed_models | while read -r model; do
        echo -e "  ${GREEN}✓${NC} ${model}"
    done
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         GEIVS Pro is ready to use                ║${NC}"
    echo -e "${CYAN}║   Open your browser to http://localhost           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

# =============================================================
# Main
# =============================================================

print_banner

if [ "$UPDATE_MODE" = true ]; then
    echo -e "${YELLOW}Running in UPDATE mode — all models will be refreshed${NC}"
fi

check_ollama

echo ""
echo -e "${BLUE}Starting model downloads. This may take a while${NC}"
echo -e "${BLUE}depending on your internet connection.${NC}"
echo ""

for entry in "${MODELS[@]}"; do
    IFS='|' read -r model description vram <<< "$entry"
    pull_model "$model" "$description" "$vram"
done

print_summary
