#!/bin/bash
# =============================================================
# GEIVS Pro — Onboarding Init Script
# Runs on first boot to initialize the state-tracking file. Model
# downloads are handled by geivs-install.sh Step 14 (pulls the user's
# chosen PRIMARY_MODEL from the host), not here. The web face is the
# GEIVS dashboard (static, served by nginx) plus AnythingLLM for
# knowledge/admin — neither needs chat-UI seeding here.
# Usage: ./onboarding-init.sh
# =============================================================

set -e

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
STATE_FILE="${STATE_FILE:-/etc/geivs/geivs-state.json}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================================
# Helper functions
# =============================================================

print_banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         GEIVS Pro — First Boot Init              ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

wait_for_service() {
    local name="$1"
    local url="$2"
    local max_attempts=30

    echo -e "${BLUE}Waiting for ${name}...${NC}"
    for i in $(seq 1 $max_attempts); do
        if curl -sf "$url" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ ${name} is ready${NC}"
            return 0
        fi
        echo -e "${YELLOW}  ${name} not ready yet... (${i}/${max_attempts})${NC}"
        sleep 5
    done
    echo -e "${RED}✗ ${name} did not become ready in time${NC}"
    return 1
}

is_first_boot() {
    if [ ! -f "$STATE_FILE" ]; then
        return 0 # true, is first boot
    fi
    local configured
    configured=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('onboarding_complete', False))" 2>/dev/null || echo "False")
    if [ "$configured" = "False" ]; then
        return 0 # true, onboarding not complete
    fi
    return 1 # false, already configured
}

init_state_file() {
    echo -e "${BLUE}Initializing GEIVS state file...${NC}"
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" << 'EOF'
{
    "geivs_version": "1.0.0",
    "onboarding_complete": false,
    "persona": {
        "name": "GEIVS",
        "gender": "male",
        "voice": "en_GB-alan-medium"
    },
    "integrations": {
        "email": {
            "configured": false,
            "provider": null,
            "address": null
        },
        "signal": {
            "configured": false,
            "phone_number": null
        },
        "telegram": {
            "configured": false,
            "bot_token": null
        },
        "whatsapp": {
            "configured": false
        },
        "discord": {
            "configured": false,
            "bot_token": null
        },
        "google_calendar": {
            "configured": false
        },
        "outlook_calendar": {
            "configured": false
        },
        "google_drive": {
            "configured": false
        },
        "nextcloud": {
            "configured": false,
            "url": null
        },
        "postiz": {
            "configured": false,
            "platforms": []
        }
    },
    "models": {
        "primary": "${PRIMARY_MODEL:-qwen2.5:7b}",
        "fast": "qwen2.5:9b",
        "pulled": []
    },
    "first_boot_at": null,
    "last_seen": null
}
EOF
    # Stamp the first boot time
    python3 -c "
import json, datetime
with open('$STATE_FILE', 'r') as f:
    d = json.load(f)
d['first_boot_at'] = datetime.datetime.utcnow().isoformat()
with open('$STATE_FILE', 'w') as f:
    json.dump(d, f, indent=4)
"
    echo -e "${GREEN}✓ State file created at ${STATE_FILE}${NC}"
}

# =============================================================
# Main
# =============================================================

print_banner

if ! is_first_boot; then
    echo -e "${GREEN}GEIVS is already configured. Skipping onboarding init.${NC}"
    echo -e "${YELLOW}To re-run onboarding, delete ${STATE_FILE} and restart.${NC}"
    exit 0
fi

echo -e "${BLUE}First boot detected — initializing GEIVS...${NC}"
echo ""

# Wait for the inference engine, then seed the state file
wait_for_service "Ollama" "${OLLAMA_URL}/api/tags"
init_state_file

# NOTE: model pulling is NOT done here. geivs-install.sh Step 14 already pulls
# PRIMARY_MODEL (the model the user actually chose, GPU/CPU-appropriate) from
# the HOST via `docker exec geivs_ollama ollama pull`. This container has no
# docker socket, so it can't run pull-models-cpu.sh's `docker exec` calls
# anyway; running pull-models.sh's fixed GPU-sized model list (llama3.3:70b
# etc.) here was both redundant with Step 14 and wrong on CPU-only installs.

echo ""
# Mark onboarding complete
python3 - "$STATE_FILE" << 'PYEOF'
import json, datetime, sys
path = sys.argv[1]
with open(path, 'r+') as f:
    d = json.load(f)
    d['onboarding_complete'] = True
    d['last_seen'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    f.seek(0)
    json.dump(d, f, indent=4)
    f.truncate()
PYEOF
echo -e "${GREEN}✓ Onboarding state marked complete${NC}"
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     GEIVS first boot init complete               ║${NC}"
echo -e "${CYAN}║     Open your browser to http://localhost         ║${NC}"
echo -e "${CYAN}║     GEIVS is ready to greet you                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
