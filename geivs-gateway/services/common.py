"""Shared helpers for geivs-gateway services.

Small, dependency-free utilities every gateway service needs: dual-interface
HTTP serving (loopback + docker gateway), config/secret loading, and logging.

Kept strictly stdlib-only so any service can import it whether it runs under
/usr/bin/python3 or the render venv, with no extra installs.
"""
import logging
import os
import threading
import time
from http.server import ThreadingHTTPServer

# Every gateway HTTP service binds both: 127.0.0.1 for host scripts, and the
# docker bridge gateway (172.17.0.1) so containers (n8n, dashboard) can reach it.
DEFAULT_BINDS = ("127.0.0.1", "172.17.0.1")

SECRETS_DIR = os.environ.get("GEIVS_SECRETS_DIR", os.path.expanduser("~/geivs-secrets"))


def get_logger(name):
    """Standard gateway logger: timestamped INFO lines to stderr/journal."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    return logging.getLogger(name)


def env(name, default=None):
    """Read an environment variable with a default."""
    return os.environ.get(name, default)


def env_int(name, default):
    """Read an environment variable as int, falling back to `default` on error."""
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return int(default)


def env_list(name, default=""):
    """Read a comma-separated environment variable into a list of trimmed values."""
    raw = os.environ.get(name) or default
    return [v.strip() for v in raw.split(",") if v.strip()]


def secret(name, default=None):
    """Read a secret from geivs-secrets/<name> (a plain value file).

    Falls back to an env var named after `name` (uppercased, dashes -> underscores),
    then to `default`. Never raises for a missing secret.
    """
    path = os.path.join(SECRETS_DIR, name)
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return os.environ.get(name.upper().replace("-", "_"), default)


def serve(handler_cls, port, binds=DEFAULT_BINDS, log=None):
    """Serve `handler_cls` on `port` across every bind address.

    Each bind runs in its own daemon thread and retries if the interface isn't
    ready yet (docker0 may not exist at boot). Blocks forever. This is the
    pattern every gateway HTTP service was hand-rolling.
    """
    log = log or get_logger("geivs-gateway")

    def _serve_one(bind):
        while True:
            try:
                httpd = ThreadingHTTPServer((bind, port), handler_cls)
            except OSError as e:
                log.error("bind %s:%s failed (%s), retrying in 10s", bind, port, e)
                time.sleep(10)
                continue
            log.info("listening on http://%s:%s", bind, port)
            httpd.serve_forever()

    threads = [threading.Thread(target=_serve_one, args=(b,), daemon=True) for b in binds]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
