#!/usr/bin/env python3
"""Tiny HTML->PNG render service for the Jeeves daily briefing.

Runs on the host (not in Docker) so n8n (in Docker) can POST a fully-built
HTML string and get back a filesystem path to a rendered PNG - which the
Signal bridge can then attach directly, no bytes need to cross the Docker
boundary.

POST /render on 127.0.0.1:8766 and 172.17.0.1:8766
Body: {"html": "<html>...</html>"}
Response: {"path": "/tmp/jeeves-render/briefing-<uuid>.png"}
"""
import json
import logging
import os
import shutil
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

from playwright.sync_api import sync_playwright

BIND_ADDR = "0.0.0.0"
PORT = int(os.environ.get("JEEVES_RENDER_PORT", "8766"))
OUT_DIR = os.environ.get("JEEVES_RENDER_DIR", "/tmp/jeeves-render")
# Also copy each render here so the GEIVS dashboard (served by nginx from the
# geivs-dashboard folder) can display the latest briefing image in the browser.
LATEST_PATH = os.environ.get(
    "JEEVES_BRIEF_LATEST",
    os.path.expanduser("~/jeeves-butler/geivs-dashboard/briefs/latest.png"),
)
VIEWPORT_WIDTH = 1264

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("render-bridge")

os.makedirs(OUT_DIR, exist_ok=True)

_playwright = sync_playwright().start()
_browser = _playwright.chromium.launch()


def render_html_to_png(html: str) -> str:
    page = _browser.new_page(viewport={"width": VIEWPORT_WIDTH, "height": 800})
    try:
        page.set_content(html, wait_until="networkidle")
        out_path = os.path.join(OUT_DIR, f"briefing-{uuid.uuid4().hex}.png")
        page.screenshot(path=out_path, full_page=True)
        try:
            os.makedirs(os.path.dirname(LATEST_PATH), exist_ok=True)
            shutil.copyfile(out_path, LATEST_PATH)
        except Exception as e:
            log.warning("could not copy render to dashboard path %s: %s", LATEST_PATH, e)
        return out_path
    finally:
        page.close()


class RenderHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path.rstrip("/") != "/render":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(length).decode())
            html = data["html"]
        except Exception:
            self.send_error(400, "expected JSON body with 'html'")
            return
        try:
            out_path = render_html_to_png(html)
            body = json.dumps({"path": out_path}).encode()
            self.send_response(200)
        except Exception as e:
            log.error("render failed: %s", e)
            body = json.dumps({"error": str(e)}).encode()
            self.send_response(502)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        log.info("/render %s", fmt % args)


def main():
    httpd = HTTPServer((BIND_ADDR, PORT), RenderHandler)
    log.info("render endpoint on http://%s:%s/render", BIND_ADDR, PORT)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
