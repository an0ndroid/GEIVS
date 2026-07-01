#!/bin/bash
# =============================================================
# GEIVS Pro — Onboarding Init Script
# Runs on first boot to seed Open WebUI with butler personality
# and initialize the state tracking file
# Usage: ./onboarding-init.sh
# =============================================================

set -e

OPENWEBUI_URL="${OPENWEBUI_URL:-http://localhost:3000}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
STATE_FILE="${STATE_FILE:-/etc/geivs/geivs-state.json}"
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-/etc/geivs/geivs-system-prompt.md}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@geivs.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme}"
ADMIN_NAME="${ADMIN_NAME:-Admin}"

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

get_openwebui_token() {
    # Try to sign in and get a JWT token
    local response
    response=$(curl -sf -X POST "${OPENWEBUI_URL}/api/v1/auths/signin" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"${ADMIN_EMAIL}\", \"password\": \"${ADMIN_PASSWORD}\"}" 2>/dev/null)

    if echo "$response" | grep -q "token"; then
        echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])"
        return 0
    fi

    # If signin fails, try to create the admin account
    echo -e "${YELLOW}Admin account not found, creating...${NC}" >&2
    response=$(curl -sf -X POST "${OPENWEBUI_URL}/api/v1/auths/signup" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${ADMIN_NAME}\", \"email\": \"${ADMIN_EMAIL}\", \"password\": \"${ADMIN_PASSWORD}\"}" 2>/dev/null)

    if echo "$response" | grep -q "token"; then
        echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])"
        return 0
    fi

    echo -e "${RED}✗ Could not authenticate with Open WebUI${NC}" >&2
    return 1
}

load_system_prompt() {
    if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
        echo -e "${RED}✗ System prompt file not found at ${SYSTEM_PROMPT_FILE}${NC}"
        return 1
    fi
    cat "$SYSTEM_PROMPT_FILE"
}

configure_openwebui() {
    local token="$1"
    local system_prompt="$2"

    echo -e "${BLUE}Configuring Open WebUI with GEIVS butler persona...${NC}"

    # Set default model
    curl -sf -X POST "${OPENWEBUI_URL}/api/v1/configs/default/model" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"${PRIMARY_MODEL:-qwen2.5:7b}\"}" > /dev/null 2>&1 || true

    # Create GEIVS model preset with butler system prompt
    local escaped_prompt
    escaped_prompt=$(echo "$system_prompt" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")

    curl -sf -X POST "${OPENWEBUI_URL}/api/v1/models/create" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{
            \"id\": \"geivs-butler\",
            \"name\": \"GEIVS\",
            \"base_model_id\": \"${PRIMARY_MODEL:-qwen2.5:7b}\",
            \"params\": {
                \"system\": ${escaped_prompt},
                \"temperature\": 0.7,
                \"top_p\": 0.9
            },
            \"meta\": {
                \"description\": \"Your personal AI valet\",
                \"profile_image_url\": \"/static/geivs-avatar.png\"
            }
        }" > /dev/null 2>&1 || true

    echo -e "${GREEN}✓ GEIVS butler persona configured in Open WebUI${NC}"
}

seed_welcome_message() {
    local token="$1"

    echo -e "${BLUE}Seeding welcome message...${NC}"

    # Create a new chat with the opening butler message
    curl -sf -X POST "${OPENWEBUI_URL}/api/v1/chats/new" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d '{
            "chat": {
                "title": "Welcome to GEIVS",
                "models": ["geivs-butler"],
                "messages": [
                    {
                        "role": "assistant",
                        "content": "Good day. I am GEIVS — your General Encrypted Intelligent Valet Software. I am running entirely on your own hardware, which means our conversations remain yours alone. No subscriptions, no cloud, no outside observers.\n\nBefore we proceed to setup, I thought it proper to give you a full account of what I am capable of. It will only take a few minutes, and you will then be in a position to decide what you actually need.\n\nShall I begin the briefing, or would you prefer to skip straight to configuration?"
                    }
                ]
            }
        }' > /dev/null 2>&1 || true

    echo -e "${GREEN}✓ Welcome message seeded${NC}"
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

# Wait for dependencies
wait_for_service "Open WebUI" "${OPENWEBUI_URL}/health"
wait_for_service "Ollama" "${OLLAMA_URL}/api/tags"

# Initialize state
init_state_file

# Load system prompt
echo -e "${BLUE}Loading butler system prompt...${NC}"
SYSTEM_PROMPT=$(load_system_prompt)
echo -e "${GREEN}✓ System prompt loaded${NC}"

# Authenticate with Open WebUI
echo -e "${BLUE}Authenticating with Open WebUI...${NC}"
TOKEN=$(get_openwebui_token)
if [ -z "$TOKEN" ]; then
    echo -e "${RED}✗ Failed to get Open WebUI token — skipping UI configuration${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Authenticated${NC}"

# Configure Open WebUI
configure_openwebui "$TOKEN" "$SYSTEM_PROMPT"

# Seed welcome message
seed_welcome_message "$TOKEN"

# Kick off model pull in background
echo -e "${BLUE}Starting model downloads in background...${NC}"
LOG_DIR="$(dirname "$STATE_FILE")/logs"
mkdir -p "$LOG_DIR"
nohup ./pull-models.sh > "$LOG_DIR/model-pull.log" 2>&1 &
echo -e "${GREEN}✓ Model pull started (check $LOG_DIR/model-pull.log for progress)${NC}"

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
