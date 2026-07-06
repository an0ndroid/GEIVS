#!/bin/bash
# GEIVS CPU/VM Model Downloader - small models for CPU inference

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
CYAN="\033[0;36m"
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║      GEIVS CPU/VM — Model Downloader            ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${CYAN}Checking Ollama at ${OLLAMA_URL}...${NC}"
for i in $(seq 1 30); do
  if curl -sf "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Ollama is ready${NC}"
    break
  fi
  sleep 2
done

pull_model() {
  local model=$1
  local purpose=$2
  local size=$3
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}Model:${NC}    $model"
  echo -e "${CYAN}Purpose:${NC}  $purpose"
  echo -e "${CYAN}Size:${NC}     $size"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}Pulling ${model}...${NC}"
  if docker exec geivs_ollama ollama pull "$model"; then
    echo -e "${GREEN}✓ ${model} installed successfully${NC}"
  else
    echo -e "${RED}✗ Failed to pull ${model}${NC}"
    echo -e "${YELLOW}  Retry: docker exec geivs_ollama ollama pull ${model}${NC}"
  fi
}

pull_model "gemma3:4b"   "Primary model — ~4GB RAM, runs well on CPU" "~3GB"
pull_model "qwen2.5:7b"  "Strong reasoning, lightweight"               "~5GB"

# Optional, opt-in only — not pulled by default. Both are MoE models (only a
# few billion params active per token), so they get noticeably better tool
# calling than the dense models above at a similar CPU token rate, but need
# more RAM headroom (~16-20GB+) than this script's default 16GB-minimum target.
# Uncomment the lines below if your box has 32GB+ RAM:
# pull_model "gemma4:26b"  "MoE, ~3.8B active params/token — needs ~20GB RAM" "~18GB"
# pull_model "gpt-oss:20b" "MoE, strong agentic tool calling — needs ~16GB+ RAM" "~13GB"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Installed Models                    ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
docker exec geivs_ollama ollama list 2>/dev/null || true

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   CPU stack is ready — open http://localhost     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
