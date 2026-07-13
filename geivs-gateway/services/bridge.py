#!/usr/bin/env python3
"""Jeeves bridge: connects Signal to n8n (docker).

Supports two Signal backends, selected via SIGNAL_API_MODE:
- "daemon" (default, Richard's dev box): signal-cli daemon mode — JSON-RPC
  send over SIGNAL_RPC, incoming messages via the /api/v1/events SSE stream.
- "rest" (product/container path): bbernhard/signal-cli-rest-api — JSON send
  over POST {SIGNAL_REST_URL}/v2/send, incoming messages via polling GET
  {SIGNAL_REST_URL}/v1/receive/{account} (stdlib has no websocket client, and
  this project is stdlib-only, so polling is used instead of the v1 websocket
  endpoint; functionally equivalent for this use case).

- Serves POST /send on 127.0.0.1:8765 and 172.17.0.1:8765 so host scripts and
  n8n workflows can send Signal messages. Body: {"message": "...",
  "recipient": "+1..."} (recipient optional, defaults to the owner).
"""
import base64
import json
import logging
import mimetypes
import os
import re
import socket
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SIGNAL_API_MODE = os.environ.get("SIGNAL_API_MODE", "daemon")  # "daemon" or "rest"
SIGNAL_RPC = os.environ.get("SIGNAL_RPC", "http://127.0.0.1:8080/api/v1/rpc")
SIGNAL_EVENTS = os.environ.get("SIGNAL_EVENTS", "http://127.0.0.1:8080/api/v1/events")
SIGNAL_REST_URL = os.environ.get("SIGNAL_REST_URL", "http://signal-cli:8080")
REST_POLL_INTERVAL = float(os.environ.get("SIGNAL_REST_POLL_INTERVAL", "2"))
N8N_WEBHOOK = os.environ.get("JEEVES_WEBHOOK", "http://127.0.0.1:5001/webhook/jeeves")
# Messages matching this go straight to the visual Morning Briefing workflow
# (rendered PNG report) instead of the conversational agent.
BRIEF_WEBHOOK = os.environ.get("JEEVES_BRIEF_WEBHOOK", "http://127.0.0.1:5001/webhook/jeeves-brief-test")
BRIEF_RE = re.compile(r"\b(daily|morning)\s+brief|^\s*brief\s*$|\bmy\s+brief\b", re.I)
# Authorized Signal senders. Prefer JEEVES_OWNERS (comma-separated, allows
# per-client numbers); fall back to legacy JEEVES_OWNER, then the default.
_OWNERS_RAW = os.environ.get("JEEVES_OWNERS") or os.environ.get("JEEVES_OWNER", "+10000000000")
OWNERS = [n.strip() for n in _OWNERS_RAW.split(",") if n.strip()]
OWNER = OWNERS[0]  # primary number: default recipient for outgoing sends
# The bot's own registered Signal number (rest mode only — daemon mode doesn't
# need it since the daemon is already bound to one account).
SIGNAL_ACCOUNT = os.environ.get("SIGNAL_ACCOUNT", "")
SEND_PORT = int(os.environ.get("JEEVES_SEND_PORT", "8765"))
SEND_BINDS = tuple(a.strip() for a in (os.environ.get("GEIVS_BINDS") or "127.0.0.1,172.17.0.1").split(",") if a.strip())
ATTACHMENTS_DIR = os.environ.get(
    "SIGNAL_ATTACHMENTS_DIR", os.path.expanduser("~/.local/share/signal-cli/attachments")
)
WHISPER_URL = os.environ.get("WHISPER_URL", "http://127.0.0.1:8500/v1/audio/transcriptions")
PIPER_HOST = os.environ.get("PIPER_HOST", "127.0.0.1")
PIPER_PORT = int(os.environ.get("PIPER_PORT", "10200"))
PIPER_VOICE = os.environ.get("PIPER_VOICE", "en_GB-alan-medium")
TTS_TMP_DIR = os.environ.get("TTS_TMP_DIR", "/tmp/jeeves-tts")

log = logging.getLogger("jeeves-bridge")


def rpc(method, params):
    """daemon mode: signal-cli's JSON-RPC endpoint."""
    body = json.dumps({"jsonrpc": "2.0", "method": method, "id": 1, "params": params}).encode()
    req = urllib.request.Request(SIGNAL_RPC, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def rest_request(method, path, body=None, timeout=30):
    """rest mode: bbernhard/signal-cli-rest-api plain REST endpoint."""
    url = SIGNAL_REST_URL.rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if data is not None else {}
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return json.loads(raw.decode()) if raw else None


def rest_health():
    """204 = healthy. Raises on any other status or connection failure."""
    rest_request("GET", "/v1/health")
    return True


def _file_to_base64_attachment(file_path):
    """bbernhard's API takes attachments as base64 strings (optionally
    prefixed with a data: URI so it can infer content-type/filename)."""
    filename = os.path.basename(file_path)
    ctype = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    with open(file_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    return f"data:{ctype};filename={filename};base64,{b64}"


def send_signal(message, recipient=None):
    recipient = recipient or OWNER
    if SIGNAL_API_MODE == "rest":
        try:
            rest_request(
                "POST", "/v2/send",
                {"message": message, "number": SIGNAL_ACCOUNT, "recipients": [recipient]},
            )
            return True
        except Exception as e:
            log.error("signal rest send failed: %s", e)
            return False
    try:
        result = rpc("send", {"recipient": [recipient], "message": message})
    except Exception as e:
        log.error("signal rpc failed: %s", e)
        return False
    if "error" in result:
        log.error("signal send failed: %s", result["error"])
        return False
    return True


def send_signal_voice(message, wav_path, recipient=None):
    recipient = recipient or OWNER
    if SIGNAL_API_MODE == "rest":
        try:
            rest_request(
                "POST", "/v2/send",
                {
                    "message": message,
                    "number": SIGNAL_ACCOUNT,
                    "recipients": [recipient],
                    "base64_attachments": [_file_to_base64_attachment(wav_path)],
                },
            )
            return True
        except Exception as e:
            log.error("signal rest voice send failed: %s", e)
            return False
    try:
        result = rpc(
            "send",
            {
                "recipient": [recipient],
                "message": message,
                "attachment": [wav_path],
                "voiceNote": True,
            },
        )
    except Exception as e:
        log.error("signal voice rpc failed: %s", e)
        return False
    if "error" in result:
        log.error("signal voice send failed: %s", result["error"])
        return False
    return True


def send_signal_attachment(message, file_path, recipient=None):
    """Send a plain file attachment (image, PDF, etc.) - not marked as a
    voice note, so Signal shows it as a regular photo/file attachment."""
    recipient = recipient or OWNER
    if SIGNAL_API_MODE == "rest":
        try:
            rest_request(
                "POST", "/v2/send",
                {
                    "message": message,
                    "number": SIGNAL_ACCOUNT,
                    "recipients": [recipient],
                    "base64_attachments": [_file_to_base64_attachment(file_path)],
                },
            )
            return True
        except Exception as e:
            log.error("signal rest attachment send failed: %s", e)
            return False
    try:
        result = rpc(
            "send",
            {
                "recipient": [recipient],
                "message": message,
                "attachment": [file_path],
            },
        )
    except Exception as e:
        log.error("signal attachment rpc failed: %s", e)
        return False
    if "error" in result:
        log.error("signal attachment send failed: %s", result["error"])
        return False
    return True


def transcribe_audio(filepath):
    """POST the attachment to the local faster-whisper server (OpenAI-compatible)."""
    boundary = uuid.uuid4().hex
    filename = os.path.basename(filepath)
    ctype = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    with open(filepath, "rb") as f:
        file_bytes = f.read()
    parts = []
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode()
    )
    parts.append(f"Content-Type: {ctype}\r\n\r\n".encode())
    parts.append(file_bytes)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    body = b"".join(parts)
    req = urllib.request.Request(
        WHISPER_URL,
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        result = json.loads(resp.read().decode())
    return (result.get("text") or "").strip()


def _wyoming_read_msg(sock, buf):
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            raise EOFError("wyoming connection closed")
        buf += chunk
    idx = buf.index(b"\n")
    header = json.loads(buf[:idx])
    buf = buf[idx + 1 :]

    def recv_exact(n):
        nonlocal buf
        while len(buf) < n:
            chunk = sock.recv(65536)
            if not chunk:
                raise EOFError("wyoming connection closed mid-message")
            buf += chunk
        out, buf = buf[:n], buf[n:]
        return out

    data = None
    dlen = header.get("data_length")
    if dlen:
        data = json.loads(recv_exact(dlen))
    payload = None
    plen = header.get("payload_length")
    if plen:
        payload = recv_exact(plen)
    return header, data, payload, buf


def synthesize_speech(text, voice=PIPER_VOICE):
    """Speak `text` via piper's Wyoming protocol (port 10200) and return a WAV file path."""
    s = socket.create_connection((PIPER_HOST, PIPER_PORT), timeout=15)
    s.settimeout(30)
    try:
        req = {"type": "synthesize", "data": {"text": text, "voice": {"name": voice}}}
        s.sendall(json.dumps(req).encode() + b"\n")
        buf = b""
        audio = b""
        fmt = None
        while True:
            header, data, payload, buf = _wyoming_read_msg(s, buf)
            t = header.get("type")
            if t == "audio-start":
                fmt = data
            elif t == "audio-chunk":
                audio += payload or b""
            elif t == "audio-stop":
                break
    finally:
        s.close()

    os.makedirs(TTS_TMP_DIR, exist_ok=True)
    out_path = os.path.join(TTS_TMP_DIR, f"{uuid.uuid4().hex}.wav")
    fmt = fmt or {"rate": 22050, "width": 2, "channels": 1}
    with wave.open(out_path, "wb") as w:
        w.setnchannels(fmt.get("channels", 1))
        w.setsampwidth(fmt.get("width", 2))
        w.setframerate(fmt.get("rate", 22050))
        w.writeframes(audio)
    return out_path


def forward_to_n8n(payload, reply_with_voice=False):
    body = json.dumps(payload).encode()
    req = urllib.request.Request(N8N_WEBHOOK, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            raw = resp.read().decode()
    except urllib.error.URLError as e:
        log.error("n8n webhook unreachable: %s", e)
        send_signal("Sorry - my brain (n8n) isn't answering right now.")
        return
    try:
        data = json.loads(raw)
    except ValueError:
        data = {}
    reply = data.get("reply") if isinstance(data, dict) else None
    if not reply:
        return
    recipient = payload.get("sender")
    if reply_with_voice:
        try:
            wav_path = synthesize_speech(str(reply))
            if send_signal_voice(str(reply), wav_path, recipient):
                return
            log.warning("voice send failed, falling back to text")
        except Exception as e:
            log.error("piper synthesis failed (%s), falling back to text", e)
    send_signal(str(reply), recipient)


def trigger_brief():
    """Fire the visual Morning Briefing workflow; it gathers data, renders a PNG,
    and sends it to the owner over Signal via its own 'Send to Signal' node."""
    body = json.dumps({"source": "signal"}).encode()
    req = urllib.request.Request(BRIEF_WEBHOOK, data=body, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=300)
    except Exception as e:
        log.error("brief webhook failed: %s", e)
        send_signal("Sorry - I couldn't put your briefing together just now.")


def handle_event(data):
    envelope = data.get("envelope", data)
    dm = envelope.get("dataMessage") or {}
    message = dm.get("message")
    sender = envelope.get("sourceNumber")
    if sender not in OWNERS:
        if sender:
            log.warning("ignoring message from non-authorized sender %s", sender)
        return

    is_voice = False
    attachments = dm.get("attachments") or []
    voice_attachment = next(
        (a for a in attachments if (a.get("contentType") or "").startswith("audio/")), None
    )
    if voice_attachment and not message:
        attachment_path = os.path.join(ATTACHMENTS_DIR, voice_attachment["id"])
        try:
            message = transcribe_audio(attachment_path)
            is_voice = True
            log.info("transcribed voice note: %.80s", message)
        except Exception as e:
            log.error("whisper transcription failed: %s", e)
            send_signal("Sorry - I couldn't transcribe that voice note.", sender)
            return

    if not message:
        return
    log.info("owner message (voice=%s): %.80s", is_voice, message)
    if BRIEF_RE.search(message):
        log.info("routing to visual morning briefing")
        send_signal("Putting your briefing together, one moment...", sender)
        threading.Thread(target=trigger_brief, daemon=True).start()
        return
    payload = {
        "sender": sender,
        "message": message,
        "timestamp": dm.get("timestamp"),
        "is_voice": is_voice,
    }
    # jeevesagent2 responds via its own "Send to Signal" node (POST /send) rather
    # than the webhook HTTP response, so reply_with_voice here only matters for
    # simpler respond-with-output workflows that still return {"reply": ...}.
    threading.Thread(
        target=forward_to_n8n, args=(payload,), kwargs={"reply_with_voice": is_voice}, daemon=True
    ).start()


def _backoff_sleep(attempt, base=1, cap=30):
    time.sleep(min(cap, base * (2 ** attempt)))


def sse_loop():
    # Loopback connection to the daemon: TCP death without FIN can't happen on
    # lo, so no read timeout — a dropped daemon closes the stream cleanly.
    attempt = 0
    while True:
        try:
            req = urllib.request.Request(SIGNAL_EVENTS, headers={"Accept": "text/event-stream"})
            with urllib.request.urlopen(req) as resp:
                log.info("SSE connected to signal-cli")
                attempt = 0
                for raw in resp:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    try:
                        handle_event(json.loads(line[5:].strip()))
                    except ValueError:
                        log.warning("unparseable SSE data: %.120s", line)
        except Exception as e:
            log.error("SSE stream dropped: %s", e)
        _backoff_sleep(attempt)
        attempt += 1


def rest_poll_loop():
    """Poll bbernhard/signal-cli-rest-api's GET /v1/receive/{account} instead
    of a websocket (stdlib has no WS client, and this endpoint returns the
    same envelope-shaped JSON messages signal-cli itself emits)."""
    if not SIGNAL_ACCOUNT:
        log.error("SIGNAL_API_MODE=rest requires SIGNAL_ACCOUNT (the bot's own Signal number)")
        return
    attempt = 0
    while True:
        try:
            messages = rest_request("GET", f"/v1/receive/{SIGNAL_ACCOUNT}", timeout=30) or []
            attempt = 0
            for item in messages:
                try:
                    handle_event(item)
                except Exception:
                    log.exception("error handling rest message: %.200s", item)
        except Exception as e:
            log.error("rest receive poll failed: %s", e)
            _backoff_sleep(attempt)
            attempt += 1
            continue
        time.sleep(REST_POLL_INTERVAL)


class SendHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path.rstrip("/") != "/send":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(length).decode())
            message = data.get("message", "")
            if not message and not data.get("attachment"):
                raise ValueError("need 'message' or 'attachment'")
        except Exception:
            self.send_error(400, "expected JSON body with 'message' and/or 'attachment'")
            return
        recipient = data.get("recipient")
        ok = False
        if data.get("attachment"):
            ok = send_signal_attachment(message, data["attachment"], recipient)
        elif data.get("voice"):
            try:
                wav_path = synthesize_speech(str(message))
                ok = send_signal_voice(str(message), wav_path, recipient)
            except Exception as e:
                log.error("piper synthesis failed (%s), falling back to text", e)
            if not ok:
                ok = send_signal(message, recipient)
        else:
            ok = send_signal(message, recipient)
        body = json.dumps({"ok": ok}).encode()
        self.send_response(200 if ok else 502)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        log.info("/send %s", fmt % args)


def serve(bind):
    while True:
        try:
            httpd = ThreadingHTTPServer((bind, SEND_PORT), SendHandler)
        except OSError as e:
            # docker0 may not exist yet at boot; retry until it does
            log.error("bind %s:%s failed (%s), retrying in 10s", bind, SEND_PORT, e)
            time.sleep(10)
            continue
        log.info("send endpoint on http://%s:%s/send", bind, SEND_PORT)
        httpd.serve_forever()


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    for bind in SEND_BINDS:
        threading.Thread(target=serve, args=(bind,), daemon=True).start()
    log.info("signal API mode: %s", SIGNAL_API_MODE)
    if SIGNAL_API_MODE == "rest":
        rest_poll_loop()
    else:
        sse_loop()


if __name__ == "__main__":
    main()
