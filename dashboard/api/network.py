"""Network status and control API."""

import subprocess
import json
import os
from flask import Blueprint, jsonify, request

bp = Blueprint("network", __name__)

IFACES = ["gl-mgmt", "gl-upstream", "gl-hotspot"]
REPO = "/opt/ghostlink"


def _iface_info(iface: str) -> dict:
    info = {"name": iface, "state": "missing", "address": None, "mac": None, "driver": None}
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
        driver_path = f"/sys/class/net/{iface}/device/driver"
        if os.path.islink(driver_path):
            info["driver"] = os.path.basename(os.readlink(driver_path))
    except Exception:
        pass
    return info


def _read_state_file(path: str) -> dict:
    result = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if "=" in line:
                    k, _, v = line.partition("=")
                    result[k] = v
    except Exception:
        pass
    return result


@bp.get("/api/network/interfaces")
def interfaces():
    return jsonify([_iface_info(i) for i in IFACES])


@bp.get("/api/network/inventory")
def inventory():
    r = subprocess.run(
        [f"{REPO}/network/hw_inventory.sh", "json"],
        capture_output=True, text=True, timeout=10,
    )
    try:
        return jsonify(json.loads(r.stdout))
    except Exception:
        return jsonify({"error": r.stderr or "inventory failed"}), 500


# ── Management WiFi ───────────────────────────────────────────────────────────

@bp.get("/api/network/mgmt/status")
def mgmt_status():
    state = _read_state_file("/run/ghostlink/mgmt.state")
    info = _iface_info("gl-mgmt")
    return jsonify({"interface": info, "state": state})


@bp.post("/api/network/mgmt/configure")
def mgmt_configure():
    body = request.get_json(silent=True) or {}
    ssid = body.get("ssid", "")
    password = body.get("password", "")
    if not ssid:
        return jsonify({"error": "ssid required"}), 400
    args = [f"{REPO}/network/mgmt.sh", "configure", ssid]
    if password:
        args.append(password)
    r = subprocess.run(args, capture_output=True, text=True, timeout=30)
    return jsonify({"ok": r.returncode == 0, "output": r.stdout + r.stderr})


# ── Upstream mode ─────────────────────────────────────────────────────────────

@bp.get("/api/network/upstream/state")
def upstream_state():
    state = _read_state_file("/var/lib/ghostlink/upstream.state")
    info = _iface_info("gl-upstream")
    return jsonify({"interface": info, "state": state})


@bp.post("/api/network/upstream/mode")
def upstream_mode():
    body = request.get_json(silent=True) or {}
    mode = body.get("mode", "")
    if mode not in ("monitor", "station", "managed"):
        return jsonify({"error": "mode must be monitor or station"}), 400
    script_mode = "station" if mode == "managed" else mode
    r = subprocess.run(
        [f"{REPO}/network/upstream_mode.sh", script_mode],
        capture_output=True, text=True, timeout=20,
    )
    return jsonify({"ok": r.returncode == 0, "output": r.stdout + r.stderr})


@bp.post("/api/network/upstream/connect")
def upstream_connect():
    body = request.get_json(silent=True) or {}
    ssid = body.get("ssid", "")
    password = body.get("password", "")
    if not ssid:
        return jsonify({"error": "ssid required"}), 400
    args = [f"{REPO}/network/upstream_mode.sh", "connect", ssid]
    if password:
        args.append(password)
    r = subprocess.run(args, capture_output=True, text=True, timeout=40)
    return jsonify({"ok": r.returncode == 0, "output": r.stdout + r.stderr})


@bp.post("/api/network/upstream/disconnect")
def upstream_disconnect():
    r = subprocess.run(
        [f"{REPO}/network/upstream_mode.sh", "disconnect"],
        capture_output=True, text=True, timeout=15,
    )
    return jsonify({"ok": r.returncode == 0, "output": r.stdout + r.stderr})


# ── Hotspot ───────────────────────────────────────────────────────────────────

@bp.get("/api/network/hotspot/status")
def hotspot_status():
    services = {}
    for svc in ("hostapd", "dnsmasq"):
        r = subprocess.run(
            ["systemctl", "is-active", svc],
            capture_output=True, text=True,
        )
        services[svc] = r.stdout.strip()
    info = _iface_info("gl-hotspot")
    return jsonify({"interface": info, "services": services})


@bp.post("/api/network/hotspot")
def hotspot_control():
    body = request.get_json(silent=True) or {}
    action = body.get("action", "")
    if action in ("start", "on"):
        r = subprocess.run(
            [f"{REPO}/network/setup_hotspot.sh"],
            capture_output=True, text=True, timeout=30,
        )
        return jsonify({"ok": r.returncode == 0, "output": r.stdout + r.stderr})
    elif action in ("stop", "off"):
        subprocess.run(["systemctl", "stop", "hostapd", "dnsmasq"])
        return jsonify({"status": "ok", "action": "stop"})
    else:
        return jsonify({"error": "action must be start or stop"}), 400


# ── NAT ───────────────────────────────────────────────────────────────────────

@bp.get("/api/network/nat/status")
def nat_status():
    r = subprocess.run(
        [f"{REPO}/network/nat.sh", "status"],
        capture_output=True, text=True, timeout=10,
    )
    return jsonify({"ok": r.returncode == 0, "output": r.stdout})


@bp.post("/api/network/nat")
def nat_control():
    body = request.get_json(silent=True) or {}
    action = body.get("action", "")
    if action in ("up", "start"):
        cmd = "up"
    elif action in ("down", "stop"):
        cmd = "down"
    else:
        return jsonify({"error": "action must be up or down"}), 400
    r = subprocess.run(
        [f"{REPO}/network/nat.sh", cmd],
        capture_output=True, text=True, timeout=15,
    )
    return jsonify({"ok": r.returncode == 0, "output": r.stdout + r.stderr})


# ── Scan ──────────────────────────────────────────────────────────────────────

@bp.get("/api/network/scan")
def scan():
    duration = int(request.args.get("duration", 10))
    iface = request.args.get("interface", "gl-upstream")
    result = subprocess.run(
        [f"{REPO}/venv/bin/python3", f"{REPO}/pentest/scan.py",
         iface, "--duration", str(duration), "--json"],
        capture_output=True, text=True, timeout=duration + 15,
    )
    try:
        return jsonify(json.loads(result.stdout))
    except Exception:
        return jsonify({"error": result.stderr or "scan failed"}), 500
