#!/usr/bin/env python3
"""GEIVS system health service.

Reports CPU / RAM / disk / load, CPU + GPU temperatures, per-disk SMART health,
and Docker container status. Self-contained (psutil + smartctl) so it does not
depend on Netdata being up.

Endpoints (served on 127.0.0.1:4090 and 172.17.0.1:4090 so host scripts,
n8n containers, and the dashboard can all reach it):
  GET /health        plain-text summary  (back-compat: OpenClaw fetches this)
  GET /health.json   full JSON
  GET /               plain-text summary

Replaces jeeves-health-server.py as the first geivs-gateway service.
"""
import json
import subprocess
import time
from http.server import BaseHTTPRequestHandler

import psutil

import common

PORT = 4090
BINDS = ("127.0.0.1", "172.17.0.1")
DISKS = ("sda", "sdb")
SMART_TTL = 300     # SMART reads are slow; cache 5 min
DOCKER_TTL = 20

# thresholds for the overall status roll-up
CPU_TEMP_WARN, CPU_TEMP_CRIT = 80, 90
GPU_TEMP_WARN, GPU_TEMP_CRIT = 85, 95
DISK_WARN, DISK_CRIT = 85, 95
RAM_WARN = 90
LIFE_WARN = 10       # % SSD life remaining

_cache = {"smart": (0, None), "docker": (0, None)}


def _run(cmd, timeout=15):
    return subprocess.check_output(cmd, timeout=timeout, text=True, stderr=subprocess.DEVNULL)


def cpu_ram_disk():
    vm = psutil.virtual_memory()
    du = psutil.disk_usage("/")
    try:
        load = psutil.getloadavg()
    except (OSError, AttributeError):
        load = (0, 0, 0)
    return {
        "cpu_percent": psutil.cpu_percent(interval=0.3),
        "cores": psutil.cpu_count(),
        "load": [round(x, 2) for x in load],
        "ram_used_gb": round(vm.used / 1e9, 1),
        "ram_total_gb": round(vm.total / 1e9, 1),
        "ram_percent": vm.percent,
        "disk_used_gb": round(du.used / 1e9, 1),
        "disk_free_gb": round(du.free / 1e9, 1),
        "disk_percent": du.percent,
    }


def temps():
    out = {"cpu_c": None, "gpu_c": None}
    try:
        t = psutil.sensors_temperatures()
    except Exception:
        return out
    for chip, arr in t.items():
        for s in arr:
            label = (s.label or "").lower()
            if chip in ("k10temp", "coretemp") and out["cpu_c"] is None:
                if label in ("tctl", "tdie", "package id 0", ""):
                    out["cpu_c"] = round(s.current, 1)
            if chip == "amdgpu" and label in ("edge", ""):
                out["gpu_c"] = round(s.current, 1)
    return out


def _parse_smart(dev):
    d = {"device": dev, "health": None, "reallocated": None, "uncorrectable": None,
         "crc_errors": None, "power_on_hours": None, "temp_c": None, "life_remaining_pct": None}
    try:
        out = _run(["sudo", "-n", "smartctl", "-H", "-A", f"/dev/{dev}"])
    except Exception:
        return d
    for line in out.splitlines():
        low = line.lower()
        if "overall-health" in low:
            d["health"] = line.split(":")[-1].strip()
            continue
        parts = line.split()
        if len(parts) < 10 or not parts[0].isdigit():
            continue
        name, value, raw = parts[1], parts[3], parts[9]
        try:
            if name == "Reallocated_Sector_Ct":
                d["reallocated"] = int(raw)
            elif name == "Reported_Uncorrect":
                d["uncorrectable"] = int(raw)
            elif name == "UDMA_CRC_Error_Count":
                d["crc_errors"] = int(raw)
            elif name == "Power_On_Hours":
                d["power_on_hours"] = int(raw)
            elif name == "Temperature_Celsius":
                d["temp_c"] = int(raw.split()[0])
            elif name == "Percent_Lifetime_Remain":
                d["life_remaining_pct"] = int(value)   # normalized value = % remaining
        except (ValueError, IndexError):
            pass
    return d


def smart():
    ts, val = _cache["smart"]
    if val is not None and time.time() - ts < SMART_TTL:
        return val
    val = [_parse_smart(dev) for dev in DISKS]
    _cache["smart"] = (time.time(), val)
    return val


def containers():
    ts, val = _cache["docker"]
    if val is not None and time.time() - ts < DOCKER_TTL:
        return val
    try:
        out = _run(["sudo", "-n", "docker", "ps", "--format", "{{.Names}}: {{.Status}}"])
        val = [l for l in out.strip().splitlines() if l]
    except Exception:
        val = []
    _cache["docker"] = (time.time(), val)
    return val


def roll_up(sys, tp, sm):
    alerts, level = [], "ok"

    def bump(new):
        nonlocal level
        order = {"ok": 0, "warn": 1, "critical": 2}
        if order[new] > order[level]:
            level = new

    if sys["disk_percent"] >= DISK_CRIT:
        alerts.append(f"disk {sys['disk_percent']}% full"); bump("critical")
    elif sys["disk_percent"] >= DISK_WARN:
        alerts.append(f"disk {sys['disk_percent']}% full"); bump("warn")
    if sys["ram_percent"] >= RAM_WARN:
        alerts.append(f"RAM {sys['ram_percent']}% used"); bump("warn")
    if tp["cpu_c"] and tp["cpu_c"] >= CPU_TEMP_CRIT:
        alerts.append(f"CPU {tp['cpu_c']}C"); bump("critical")
    elif tp["cpu_c"] and tp["cpu_c"] >= CPU_TEMP_WARN:
        alerts.append(f"CPU {tp['cpu_c']}C"); bump("warn")
    if tp["gpu_c"] and tp["gpu_c"] >= GPU_TEMP_CRIT:
        alerts.append(f"GPU {tp['gpu_c']}C"); bump("critical")
    elif tp["gpu_c"] and tp["gpu_c"] >= GPU_TEMP_WARN:
        alerts.append(f"GPU {tp['gpu_c']}C"); bump("warn")
    for dsk in sm:
        if dsk["health"] and dsk["health"].upper() != "PASSED":
            alerts.append(f"{dsk['device']} SMART {dsk['health']}"); bump("critical")
        if dsk["reallocated"]:
            alerts.append(f"{dsk['device']} {dsk['reallocated']} reallocated sectors"); bump("critical")
        if dsk["uncorrectable"]:
            alerts.append(f"{dsk['device']} {dsk['uncorrectable']} uncorrectable errors"); bump("critical")
        if dsk["crc_errors"]:
            alerts.append(f"{dsk['device']} {dsk['crc_errors']} CRC errors"); bump("warn")
        if dsk["life_remaining_pct"] is not None and dsk["life_remaining_pct"] < LIFE_WARN:
            alerts.append(f"{dsk['device']} {dsk['life_remaining_pct']}% life left"); bump("warn")
    return level, alerts


def report():
    sys = cpu_ram_disk()
    tp = temps()
    sm = smart()
    ct = containers()
    level, alerts = roll_up(sys, tp, sm)
    return {"status": level, "alerts": alerts, "system": sys, "temps": tp,
            "disks": sm, "containers": ct, "ts": int(time.time())}


def as_text(r):
    s, tp = r["system"], r["temps"]
    lines = [
        f"Jeeves server health: {r['status'].upper()}",
        f"CPU: {s['cpu_percent']}% busy, load {s['load'][0]} ({s['cores']} cores)"
        + (f", {tp['cpu_c']}C" if tp["cpu_c"] else ""),
        f"RAM: {s['ram_used_gb']}GB / {s['ram_total_gb']}GB ({s['ram_percent']}%)",
        f"Disk: {s['disk_used_gb']}GB used, {s['disk_free_gb']}GB free ({s['disk_percent']}%)",
        f"GPU: {tp['gpu_c']}C" if tp["gpu_c"] else "GPU: n/a",
    ]
    for d in r["disks"]:
        life = f", {d['life_remaining_pct']}% life" if d["life_remaining_pct"] is not None else ""
        lines.append(f"{d['device']}: SMART {d['health'] or '?'}, {d['temp_c']}C{life}, "
                     f"{d['uncorrectable']} uncorrectable")
    if r["alerts"]:
        lines.append("ALERTS: " + "; ".join(r["alerts"]))
    if r["containers"]:
        lines.append("")
        lines.append("Containers:")
        lines.extend(r["containers"])
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/") or "/"
        try:
            r = report()
        except Exception as e:
            self.send_error(500, f"health collection failed: {e}")
            return
        if path in ("/health.json", "/json"):
            body = json.dumps(r).encode()
            ctype = "application/json"
        else:
            body = as_text(r).encode()
            ctype = "text/plain; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def main():
    common.serve(Handler, PORT, BINDS)


if __name__ == "__main__":
    main()
