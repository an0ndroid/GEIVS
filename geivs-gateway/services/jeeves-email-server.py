#!/usr/bin/env python3
"""Jeeves email service on port 4091.
GET  /email/inbox       - unread emails (last 10)
GET  /email/inbox?n=5   - unread emails (last n)
POST /email/send        - send email (JSON: to, subject, body)
"""
import os, imaplib, smtplib, json, email, email.utils
from email.mime.text import MIMEText
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime

GMAIL_USER = os.environ["GMAIL_USER"]
GMAIL_PASS = os.environ["GMAIL_PASS"]

def get_unread(limit=10):
    msgs = []
    try:
        m = imaplib.IMAP4_SSL("imap.gmail.com")
        m.login(GMAIL_USER, GMAIL_PASS)
        m.select("INBOX")
        _, ids = m.search(None, "UNSEEN")
        uids = ids[0].split()[-limit:]
        for uid in reversed(uids):
            _, data = m.fetch(uid, "(RFC822)")
            msg = email.message_from_bytes(data[0][1])
            sender = email.utils.parseaddr(msg["From"])[1]
            subject = msg["Subject"] or "(no subject)"
            date = msg["Date"] or ""
            body = ""
            if msg.is_multipart():
                for part in msg.walk():
                    if part.get_content_type() == "text/plain":
                        body = part.get_payload(decode=True).decode("utf-8","ignore")[:500]
                        break
            else:
                body = msg.get_payload(decode=True).decode("utf-8","ignore")[:500]
            msgs.append(f"From: {sender}\nSubject: {subject}\nDate: {date}\n{body.strip()}")
        m.logout()
    except Exception as e:
        return f"Error reading inbox: {e}"
    if not msgs:
        return "No unread emails."
    return f"{len(msgs)} unread email(s):\n\n" + "\n\n---\n\n".join(msgs)

def send_email(to, subject, body):
    try:
        msg = MIMEText(body)
        msg["Subject"] = subject
        msg["From"] = GMAIL_USER
        msg["To"] = to
        with smtplib.SMTP_SSL("smtp.gmail.com", 465) as s:
            s.login(GMAIL_USER, GMAIL_PASS)
            s.send_message(msg)
        return f"Email sent to {to}."
    except Exception as e:
        return f"Error sending email: {e}"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/email/inbox":
            n = int(parse_qs(parsed.query).get("n", [10])[0])
            result = get_unread(n)
            self.respond(result)
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):
        if self.path == "/email/send":
            length = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(length))
            result = send_email(data["to"], data["subject"], data["body"])
            self.respond(result)
        else:
            self.send_response(404); self.end_headers()

    def respond(self, text):
        body = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args): pass

if __name__ == "__main__":
    host = os.environ.get("GEIVS_BIND_HOST", "127.0.0.1")
    port = int(os.environ.get("EMAIL_PORT", "4091"))
    print(f"Jeeves email server on {host}:{port} ({GMAIL_USER})")
    HTTPServer((host, port), Handler).serve_forever()
