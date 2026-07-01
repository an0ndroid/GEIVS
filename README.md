# GEIVS Pro

**General Encrypted Intelligent Valet Software — Pro Edition**

A fully self-hosted AI platform for small businesses. Private, local, no subscriptions, no cloud dependency.

---

## What is GEIVS?

GEIVS gives your business a private AI assistant that runs entirely on your own hardware. It combines a capable local language model with a full suite of integrated services — email, messaging, calendar, social media, image generation, web search, and more — all managed through a single conversational interface.

The assistant's name and personality are set during installation. Your data stays on your machine. Always.

---

## Requirements

| | Minimum | Recommended |
|---|---|---|
| OS | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS |
| GPU | NVIDIA 8GB VRAM | NVIDIA 24GB VRAM (RTX 4090) |
| RAM | 16GB | 32GB+ |
| Storage | 100GB free | 240GB+ free |

> No GPU? See [CPU / VM Mode](#cpu--vm-mode) below.

All software dependencies (Docker, NVIDIA drivers, Container Toolkit, etc.) are installed automatically by `geivs-prep.sh`.

---

## Installation

Two scripts, run in order. Both are idempotent — safe to re-run.

### Step 1 — Prepare and harden the server

Run as root on a **fresh Ubuntu install**. Installs NVIDIA drivers, Docker, NVIDIA Container Toolkit, UFW firewall, fail2ban, swap, and kernel tuning.

```bash
curl -fsSL https://raw.githubusercontent.com/an0ndroid/GEIVS/main/geivs-prep.sh | sudo bash
```

If NVIDIA drivers were newly installed, reboot before continuing:

```bash
sudo reboot
```

### Step 2 — Install GEIVS

Run as your normal user (not root). Downloads the stack, generates all secrets, starts all services, imports n8n workflows, and walks you through connecting email, Signal, Google Calendar, and social media.

```bash
curl -fsSL https://raw.githubusercontent.com/an0ndroid/GEIVS/main/geivs-install.sh | bash
```

The installer will prompt for your business name, assistant persona name, and preferred AI model. Once complete, open `http://your-server-ip` to start.

> ⏱ First install takes 60–90 minutes — most of that is downloading Docker images (15+ GB). Leave it running.

---

## What Each Script Does

### geivs-prep.sh

| Step | Action |
|------|--------|
| System update | Full apt upgrade |
| Prerequisites | curl, git, python3, jq, htop, chrony, build-essential, and more |
| Timezone & NTP | Sets timezone, enables chrony (accurate time for automation workflows) |
| NVIDIA drivers | Auto-detects and installs recommended driver |
| Docker Engine | Official Docker install |
| NVIDIA Container Toolkit | Installs toolkit, sets nvidia as Docker default runtime |
| Swap | Creates 32GB swap file (configurable) for model memory overflow |
| Kernel tuning | SYN flood protection, inotify limits, TCP buffers, vm.swappiness=10 |
| System limits | 1M file handles, 64K processes for Docker/Ollama/n8n |
| SSH hardening | Disables root login, tightens auth timeouts |
| UFW firewall | Allows 22/tcp, 80/tcp, 443/tcp, 41641/udp (Tailscale) |
| fail2ban | 4 failed SSH attempts = 2h ban |
| Auto security updates | Unattended security patches, no auto-reboot |

### geivs-install.sh

| Step | Action |
|------|--------|
| GPU detection | Identifies NVIDIA / AMD / CPU-only and configures accordingly |
| Configuration | Prompts for hostname, admin email/password, business name, persona name, AI model |
| Secrets | Generates all keys (WebUI, n8n encryption, JWT, API key, etc.) |
| .env | Writes fully populated environment file (chmod 600) |
| Compose file | Downloads and patches docker-compose.pro.yml |
| nginx config | Downloads reverse proxy config |
| Workflows | Downloads all 13 n8n automation workflows |
| Support files | Downloads onboarding script, system prompt, model pull scripts |
| Stack start | `docker compose up -d` |
| SearXNG patch | Enables JSON format required for Open WebUI web search |
| Onboarding | Runs first-boot Open WebUI configuration |
| Model download | Pulls primary AI model in background |
| Workflow import | Imports all n8n workflows via API |
| Tailscale | Configures remote access (if key provided) |
| Email setup | Collects IMAP/SMTP credentials, creates n8n credentials, activates email workflows |
| Signal setup | Registers phone number, verifies SMS code, activates Signal workflows |
| Google Calendar | Guided OAuth setup instructions (browser-based) |
| Social media | Guided Postiz account setup |
| Summary | Prints all URLs, credentials, and integration status |

---

## Access URLs

All services route through nginx on port 80.

| URL | Service |
|-----|---------|
| `http://your-ip/` | Open WebUI — chat with your AI assistant |
| `http://your-ip/automation/` | n8n workflow automation |
| `http://your-ip/monitor/` | Uptime Kuma monitoring |
| `http://your-ip/imagine/` | ComfyUI image generation |
| `http://your-ip/search/` | SearXNG private search |
| `http://your-ip/social/` | Postiz social media scheduler |
| `http://your-ip/portainer/` | Portainer container management |

---

## Services

| Container | Purpose |
|-----------|---------|
| ollama | Local LLM inference |
| openwebui | Primary chat interface |
| n8n | Automation workflows |
| comfyui | Stable Diffusion image generation |
| piper | Text-to-speech |
| faster-whisper | Speech-to-text transcription |
| searxng | Self-hosted web search |
| qdrant | Vector database for memory |
| signal-cli | Signal messenger integration |
| postiz | Social media scheduling |
| crawl4ai | Web scraping for AI research |
| uptime-kuma | Service health monitoring |
| portainer | Container management UI |
| nginx | Reverse proxy |

---

## n8n Workflows

| Workflow | Function |
|----------|---------|
| geivs-email-bot | Reads and replies to email via your AI assistant |
| geivs-signal-bot | Sends and receives Signal messages |
| geivs-daily-briefing | Morning summary: weather, calendar, email digest |
| geivs-email-draft | Drafts email responses for review |
| geivs-calendar-integration | Google Calendar read/write |
| geivs-dashboard | Status overview |
| geivs-email-transcription | Transcribes voice email attachments |
| geivs-signal-transcription | Transcribes Signal voice messages |
| geivs-email-setup | Email credential setup helper |
| geivs-signal-setup | Signal registration helper |
| geivs-calendar-setup | Calendar OAuth setup helper |
| geivs-storage-setup | Storage configuration helper |
| geivs-telegram-setup | Telegram bot setup helper |

---

## Models

| Model | Size | Best for |
|-------|------|---------|
| llama3.3:70b | ~42GB | Best quality (GPU required) |
| gemma3:12b | ~8GB | Balanced quality and speed |
| qwen2.5:7b | ~4.7GB | Fast, efficient, good reasoning |
| gemma3:4b | ~3GB | CPU mode / low RAM systems |

The installer prompts you to choose. Ollama handles quantization automatically.

---

## Integrations

| Integration | Provider |
|-------------|---------|
| Email | Gmail, Outlook, any IMAP/SMTP |
| Messaging | Signal, Telegram, Discord |
| Calendar | Google Calendar |
| Social Media | Twitter/X, LinkedIn, Facebook, Instagram (via Postiz) |
| Image Generation | Stable Diffusion via ComfyUI (local, no API key needed) |
| Speech-to-Text | faster-whisper (local, no API key needed) |
| Web Search | SearXNG (local, private) |

---

## File Structure

```
GEIVS/
├── geivs-prep.sh               # Step 1: server hardening and prerequisites
├── geivs-install.sh            # Step 2: full GEIVS stack installer
├── docker-compose.pro.yml      # GPU stack definition
├── docker-compose.cpu.yml      # CPU-only stack definition
├── update-geivs.sh             # Update all images and models
├── onboarding-init.sh          # First-boot Open WebUI configuration
├── geivs-state.json            # Default assistant state template
├── geivs-system-prompt.md      # Default assistant persona and instructions
├── pull-models.sh              # GPU model download script
├── pull-models-cpu.sh          # CPU model download script
├── nginx/
│   └── geivs.conf              # Nginx reverse proxy configuration
└── n8n-workflows/
    ├── geivs-email-bot.json
    ├── geivs-signal-bot.json
    ├── geivs-daily-briefing.json
    ├── geivs-email-draft.json
    ├── geivs-calendar-integration.json
    ├── geivs-dashboard.json
    ├── geivs-email-transcription.json
    ├── geivs-signal-transcription.json
    ├── geivs-email-setup.json
    ├── geivs-signal-setup.json
    ├── geivs-calendar-setup.json
    ├── geivs-storage-setup.json
    └── geivs-telegram-setup.json
```

---

## Updating GEIVS

```bash
cd ~/geivs && bash update-geivs.sh
```

Pulls latest Docker images and refreshes Ollama models.

---

## CPU / VM Mode

No NVIDIA GPU? The installer detects this automatically and configures the CPU stack.

| | GPU (Pro) | CPU |
|---|---|---|
| GPU required | Yes | No |
| Default model | llama3.3:70b | qwen2.5:7b |
| ComfyUI image | latest-cuda | latest-cpu |
| Whisper mode | cuda / medium | cpu / tiny |
| Recommended RAM | 32GB | 16GB minimum |

---

## VM Notes

If running in a VM, LVM may not use all available disk by default. Expand it:

```bash
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
df -h
```

GPU passthrough is not available in most VM configurations — use the CPU stack.

---

## Troubleshooting

**GPU not detected after install:**
```bash
nvidia-smi          # verify driver is loaded — if this fails, reboot
```

**SearXNG web search not working in Open WebUI:**
```bash
docker exec geivs_searxng grep -A5 'formats:' /etc/searxng/settings.yml
# should show both: - html and - json
```

**n8n workflows not imported:**
```bash
for f in ~/geivs/n8n-workflows/*.json; do
  docker cp "$f" geivs_n8n:/tmp/
done
docker exec geivs_n8n n8n import:workflow --separate --input=/tmp/
```

**View any container's logs:**
```bash
docker logs geivs_<service> --tail 50 -f
```

**Out of disk space:**
```bash
df -h
docker system prune -f
```

---

## License

MIT

---

*GEIVS Pro — Your data. Your hardware. Your terms.*
