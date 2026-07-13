#!/usr/bin/env python3
"""OpenAI-compatible shim for the Jeeves tool-agent.

Presents /v1/models and /v1/chat/completions (OpenAI format, with streaming) so
front-ends like AnythingLLM/Open WebUI can use "Jeeves" as a model. Internally
it forwards the conversation to the n8n Jeeves HTTP agent
(POST /webhook/jeeves-agent -> {"reply": "..."}), which runs gpt-oss with the
calendar/email/reminder tools.

RAG stays in the front-end: AnythingLLM injects retrieved document context into
the request (usually the system message); we pass that context plus the latest
user turn to the agent, so Jeeves answers grounded in the docs AND can use tools.

Binds on 127.0.0.1 and 172.17.0.1 (docker gateway) so containers can reach it.
No secrets here; it only proxies to the local agent.
"""
import hashlib
import json
import os
import time
import urllib.request
import logging
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AGENT_URL = os.environ.get("JEEVES_AGENT_URL", "http://127.0.0.1:5001/webhook/jeeves-agent")
PORT = int(os.environ.get("SHIM_PORT", "8788"))
# Comma-separated bind addresses. Host default keeps loopback + docker gateway;
# in a container set GEIVS_BINDS=0.0.0.0 to listen on the container network.
BINDS = tuple(a.strip() for a in (os.environ.get("GEIVS_BINDS") or "127.0.0.1,172.17.0.1").split(",") if a.strip())
MODEL_ID = "jeeves"
AGENT_TIMEOUT = 300

log = logging.getLogger("jeeves-openai-shim")


def call_agent(message, session):
    body = json.dumps({"message": message, "session": session}).encode()
    req = urllib.request.Request(AGENT_URL, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=AGENT_TIMEOUT) as r:
        data = json.loads(r.read().decode())
    return str(data.get("reply", "")).strip() or "(no response)"


def build_message(messages):
    """Flatten the OpenAI messages into one prompt for the agent.

    Keep any system/context (AnythingLLM injects RAG context there) and the
    latest user turn. A short tail of prior turns is included for continuity.
    """
    context = "\n".join(m.get("content", "") for m in messages
                        if m.get("role") == "system" and m.get("content"))
    user_turns = [m for m in messages if m.get("role") == "user" and m.get("content")]
    last_user = user_turns[-1]["content"] if user_turns else ""
    parts = []
    if context.strip():
        parts.append("Relevant context:\n" + context.strip())
    parts.append(last_user)
    return "\n\n".join(parts), last_user


def session_for(messages):
    first_user = next((m.get("content", "") for m in messages
                       if m.get("role") == "user"), "seed")
    return "allm-" + hashlib.sha1(first_user.encode()).hexdigest()[:12]


def completion_json(reply, stream_chunk=False):
    now = int(time.time())
    if stream_chunk:
        return {"id": f"chatcmpl-{now}", "object": "chat.completion.chunk",
                "created": now, "model": MODEL_ID,
                "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                             "finish_reason": None}]}
    return {"id": f"chatcmpl-{now}", "object": "chat.completion", "created": now,
            "model": MODEL_ID,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": reply},
                         "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        b = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._send(200, {"object": "list", "data": [
                {"id": MODEL_ID, "object": "model", "created": 0, "owned_by": "geivs"}]})
        else:
            self._send(200, {"status": "ok"})

    def do_POST(self):
        if not self.path.rstrip("/").endswith("/chat/completions"):
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length).decode())
            messages = payload.get("messages", [])
            stream = bool(payload.get("stream"))
        except Exception as e:
            self._send(400, {"error": {"message": f"bad request: {e}"}})
            return

        message, last_user = build_message(messages)
        session = session_for(messages)
        log.info("chat (stream=%s) session=%s q=%.60s", stream, session, last_user)
        try:
            reply = call_agent(message, session)
        except Exception as e:
            log.error("agent call failed: %s", e)
            reply = "Sorry, my agent backend isn't responding right now."

        if not stream:
            self._send(200, completion_json(reply))
            return
        # single-chunk SSE stream (satisfies OpenAI streaming clients)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        now = int(time.time())
        first = completion_json(reply, stream_chunk=True)
        stop = {"id": f"chatcmpl-{now}", "object": "chat.completion.chunk",
                "created": now, "model": MODEL_ID,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
        for obj in (first, stop):
            self.wfile.write(f"data: {json.dumps(obj)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, fmt, *args):
        return


def serve(bind):
    while True:
        try:
            httpd = ThreadingHTTPServer((bind, PORT), Handler)
        except OSError as e:
            log.error("bind %s:%s failed (%s); retry 10s", bind, PORT, e)
            time.sleep(10)
            continue
        log.info("OpenAI shim on http://%s:%s/v1", bind, PORT)
        httpd.serve_forever()


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    threads = [threading.Thread(target=serve, args=(b,), daemon=True) for b in BINDS]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
