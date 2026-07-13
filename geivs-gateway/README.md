# geivs-gateway

The single, documented home for the Python "glue" services that sit between GEIVS's
front doors (Signal, web chat, email) and its brains (n8n + Ollama). This package
**consolidates** services that grew organically across `~/jeeves-butler/` and `~/`.

> Rule of the road (decided 2026-07-12): the existing agent stays in n8n; **new**
> business logic is born here as tested Python, not as new n8n workflow JSON.

## Topology — what talks to what

```
  Signal app
     │
     ▼
  signal-cli daemon  (:8080, the GEIVS bot's own Signal number)
     │  SSE events
     ▼
  bridge.py ───────────────▶ n8n  POST /webhook/jeeves ──▶ "Jeeves Agent v2"
   (Signal in/out;             ▲                            (Ollama + 13 tool workflows)
    /send on :8765)            │
                               │
  Open WebUI / front-ends ─▶ openai_shim.py (:8788) ───────┘  (OpenAI-compatible façade)

  docker containers ─▶ ollama-bridge.py (172.17.0.1:11434) ─▶ host Ollama (127.0.0.1:11434)
  n8n daily briefing ─▶ render-bridge.py  (HTML → PNG)
  email in/out ──────▶ jeeves-email  (:4090)     health probe ─▶ jeeves-health (:4091)
```

## Service inventory (live as of 2026-07-12)

| systemd unit          | source (today)                         | port(s)                 | role |
|-----------------------|----------------------------------------|-------------------------|------|
| signal-daemon         | /opt/signal-cli (not python)           | 127.0.0.1:8080          | Signal transport |
| jeeves-bridge         | ~/jeeves-butler/bridge.py              | 8765 (127 + 172.17.0.1) | Signal ⇄ n8n; owner allow-list |
| jeeves-openai-shim    | ~/jeeves-butler/openai_shim.py         | 8788                    | OpenAI API façade → n8n agent |
| jeeves-ollama-bridge  | ~/jeeves-butler/ollama-bridge.py       | 172.17.0.1:11434        | docker → host Ollama |
| render-bridge         | ~/jeeves-butler/render-bridge.py       | (internal)              | HTML→PNG for briefing |
| jeeves-email          | ~/jeeves-email-server.py               | 4090                    | email HTTP service |
| jeeves-health         | ~/jeeves-health-server.py              | 4091                    | health endpoint |

Secrets live in `~/geivs-secrets/` (per-service env files, mode 600).
`bridge.py` already loads `~/geivs-secrets/jeeves-bridge.env` (owner allow-list).

## Layout
- `services/`  — the consolidated Python services (moved here at cutover)
- `systemd/`   — the unit files that point at `services/`
- `.env.example` — consolidated, documented env vars
- `MIGRATION.md` — the safe, per-service cutover plan
- `Dockerfile` + `docker-compose.gateway.yml` — the containerized packaging (product)

## Deployment

**Richard's box (today):** host `systemd` units run `services/*.py` directly
(loopback + docker-gateway binds). This is the reference install; nothing here
changes it.

**Product (containerized):** the gateway ships as ONE image (`Dockerfile`) with
four services defined in `docker-compose.gateway.yml`, run as an overlay that
merges with the main GEIVS stack so it shares `geivs-net` and addresses
`n8n` / `ollama` / `signal-cli` / `whisper` / `piper` by container name:

```
cd ~/jeeves-stack
docker compose -f docker-compose.cpu.yml \
  -f ../geivs-gateway/docker-compose.gateway.yml up -d --build
```

Containerized set: **bridge, shim, render, email**. Deliberately excluded:
- `system_health` — stays a **host** service (needs host CPU/temps/SMART + docker.sock).
- `ollama-bridge` — **not needed** in the product; Ollama is a container at `ollama:11434`.

All network addresses are env-driven (`GEIVS_BINDS`, `JEEVES_AGENT_URL`,
`SIGNAL_RPC`, `JEEVES_WEBHOOK`, …) with host defaults preserved, so the same
`services/*.py` run unchanged on the host or in a container.

## Development

Shared helpers live in `services/common.py` — dual-interface HTTP serving
(`serve`), config/secret loading (`env`, `env_int`, `env_list`, `secret`), and
`get_logger`. Stdlib-only, so services run under `/usr/bin/python3` or the
render venv with no installs.

Tests use stdlib `unittest` (no pytest/install needed):

    ./run-tests.sh          # or: python3 -m unittest discover -s tests

**The rule (Phase 2):** a new capability is a small service in `services/` that
uses `common.py`, plus a test in `tests/`. Business logic goes here as tested
Python — n8n is for wiring and automation, not logic. `system_health.py` is the
reference example (uses `common.serve`, covered by `tests/test_system_health.py`).
