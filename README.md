# GEIVS Pro

**General Encrypted Intelligent Valet Software — Pro Edition**

A fully self-hosted personal AI platform targeting 24GB VRAM GPU hardware. Private, local, no subscriptions, no cloud dependency.

---

## What is GEIVS?

GEIVS is a personal AI assistant that runs entirely on your own hardware. It combines a capable local language model with a suite of integrated services — email, messaging, calendar, social media, image generation, and more — all managed through a single conversational interface.

Your data stays on your machine. Always.

---

## Requirements

- **OS:** Ubuntu 24.04 LTS (recommended)
- **GPU:** NVIDIA GPU with 24GB VRAM (RTX 4090, RTX Pro 4500, or equivalent)
- **RAM:** 32GB recommended
- **Storage:** 200GB+ free space (models are large)
- **Software:** Docker, Docker Compose, NVIDIA Container Toolkit

---

## Quick Start

### 1. Clone the repo

```bash
git clone https://github.com/an0ndroid/GEIVS.git
cd GEIVS
```

### 2. Configure environment

```bash
cp .env.example .env
nano .env
```

Generate secure keys:
```bash
openssl rand -hex 32  # for WEBUI_SECRET_KEY
openssl rand -hex 32  # for N8N_ENCRYPTION_KEY
openssl rand -hex 32  # for JWT_SECRET
```

### 3. Install NVIDIA Container Toolkit

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### 4. Start the stack

```bash
docker compose -f docker-compose.pro.yml up -d
```

### 5. Pull models

```bash
chmod +x pull-models.sh
./pull-models.sh
```

### 6. Run first boot init

```bash
chmod +x onboarding-init.sh
./onboarding-init.sh
```

### 7. Open your browser

```
http://your-server-ip
```

GEIVS will greet you and walk you through setup.

---

## Services & Ports

| Service | Port | Description |
|---------|------|-------------|
| Open WebUI | 3000 | Primary chat interface |
| Ollama | 11434 | Local LLM inference |
| n8n | 5678 | Automation workflows |
| ComfyUI | 8188 | Image generation |
| Postiz | 5100 | Social media scheduler |
| Portainer | 9000 | Container management |
| SearXNG | 8080 | Self-hosted search |
| Qdrant | 6333 | Vector database |
| Signal CLI | 8090 | Signal messenger API |
| Piper TTS | 5000 | Text-to-speech |
| Nginx | 80/443 | Reverse proxy |

All services accessible via Nginx at `http://your-server-ip` with clean URL paths.

---

## File Structure

```
GEIVS/
├── docker-compose.pro.yml      # Main stack definition
├── .env.example                # Environment variables template
├── pull-models.sh              # Model download script
├── update-geivs.sh             # Full stack update script
├── onboarding-init.sh          # First boot configuration
├── geivs-state.json            # Default state template
├── geivs-system-prompt.md      # Butler personality prompt
├── nginx/
│   └── geivs.conf              # Nginx reverse proxy config
└── n8n-workflows/
    ├── geivs-email-setup.json
    ├── geivs-signal-setup.json
    ├── geivs-telegram-setup.json
    ├── geivs-calendar-setup.json
    ├── geivs-storage-setup.json
    └── geivs-dashboard.json
```

---

## Models (24GB VRAM)

| Model | Purpose | VRAM |
|-------|---------|------|
| llama3.3:70b | Primary conversational model | ~40GB* |
| qwen2.5:72b | Reasoning and multilingual | ~40GB* |
| gemma3:27b | Natural conversation | ~16GB |
| qwen2.5:9b | Fast lightweight tasks | ~6GB |

*70B models require quantization to fit in 24GB. Ollama handles this automatically.

---

## Updating GEIVS

```bash
./update-geivs.sh
```

This updates all Docker images and refreshes Ollama models.

---

## Integrations

GEIVS supports the following integrations, configured during onboarding:

- **Email:** Gmail, Outlook, any IMAP/SMTP provider
- **Messaging:** Signal, Telegram, WhatsApp, Discord
- **Calendar:** Google Calendar, Outlook Calendar
- **Storage:** Local files, Nextcloud, Google Drive
- **Social Media:** Twitter/X, LinkedIn, Facebook, Instagram (via Postiz)
- **Image Generation:** Stable Diffusion via ComfyUI (local, no API key)

---

## Troubleshooting

**GPU not detected:**
Ensure NVIDIA Container Toolkit is installed and `sudo nvidia-ctk runtime configure --runtime=docker` has been run.

**SearXNG won't start:**
```bash
docker run --rm -v user_searxng_data:/etc/searxng busybox chmod 777 /etc/searxng
docker restart geivs_searxng
```

**Out of disk space:**
Models are large. Ensure 200GB+ is available. Check with `df -h`.

**Container logs:**
```bash
docker logs geivs_<service_name> --tail 50
```

---

## License

MIT

---

*GEIVS Pro — Your data. Your hardware. Your terms.*

---

## VM Install Notes

If running GEIVS inside a VM (for testing or development), the LVM volume may not use all available disk space by default. Expand it with:

```bash
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

Verify with `df -h` — the root partition should now reflect the full disk size.

Also note that GPU passthrough is not available in most VM configurations. Remove the `deploy` blocks from the `ollama` and `comfyui` services in `docker-compose.pro.yml` when running in a VM, and use smaller models that fit in RAM for testing.
