# GEIVS gateway image — one image runs any of the containerized gateway services
# (bridge, openai_shim, render-bridge, jeeves-email-server). The per-service
# command is set in docker-compose.gateway.yml.
#
# Chromium (for render-bridge's HTML->PNG) is the only heavy dependency; the
# other services are stdlib-only and simply ignore it.
# Pin bookworm (Debian 12): Playwright 1.47's --with-deps targets it. The
# rolling python:3.12-slim tracks Debian 13 (trixie), where playwright asks for
# obsolete font packages and the browser-deps install fails.
FROM python:3.12-slim-bookworm

# tini = clean PID 1 / signal handling for the long-running HTTP servers.
RUN apt-get update && apt-get install -y --no-install-recommends \
        tini ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# playwright (+ its Chromium and system deps) for render-bridge; psutil is only
# used by system_health, which stays a host service — harmless to include.
RUN pip install --no-cache-dir playwright==1.47.0 psutil \
    && playwright install --with-deps chromium

COPY services/ /app/services/

# Containers listen on all interfaces (compose networks are isolated already).
ENV GEIVS_BINDS=0.0.0.0 \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["/usr/bin/tini", "--"]
# Default target; each compose service overrides this with its own command.
CMD ["python3", "services/bridge.py"]
