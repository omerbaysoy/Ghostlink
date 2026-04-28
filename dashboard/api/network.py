"""Network status and control API."""

import subprocess
import json
import os
from flask import Blueprint, jsonify, request

bp = Blueprint("network", __name__)

IFACES = ["gl-mgmt", "gl-upstream", "gl-hotspot"]


def _iface_info(iface: str) -> dict:
    info = {"name": iface, "state": "missing", "address": None, "mac": None}
    try:
        with open(f"/sys/class/net/{iface}/operstate") as f:
            info["state"] = f.read().strip()
        with open(f"/sys/class/net/{iface}/address") as f:
            info["mac"] = f.read().strip()
        r = subprocess.run(
            ["ip", "-4", "addr", "show", iface],
            capture_output=True, text=True,
        )
        for line in r.stdout.splitlines():
            if "inet " in line:
                info["address"] = line.strip().split()[1]
    except Exception:
        pass
    return info


@bp.get("/api/network/interfaces")
def interfaces():
    return jsonify([_iface_info(i) for i in IFACES])


@bp.get("/api/network/scan")
def scan():
    duration = int(request.args.get("duration", 10))
    iface = request.args.get("interface", "gl-upstream")
    result = subprocess.run(
        ["/opt/ghostlink/venv/bin/python3", "/opt/ghostlink/pentest/scan.py",
         iface, "--duration", str(duration), "--json"],
        capture_output=True, text=True, timeout=duration + 15,
    )
    try:
        return jsonify(json.loads(result.stdout))
    except Exception:
        return jsonify({"error": result.stderr or "scan failed"}), 500


@bp.post("/api/network/hotspot")
def hotspot_control():
    action = request.json.get("action", "")
    if action == "on":
        subprocess.run(["systemctl", "start", "hostapd", "dnsmasq"])
    elif action == "off":
        subprocess.run(["systemctl", "stop", "hostapd", "dnsmasq"])
    else:
        return jsonify({"error": "unknown action"}), 400
    return jsonify({"status": "ok", "action": action})
