"""Identity management API."""

import json
import subprocess
import os
from flask import Blueprint, jsonify, request

bp = Blueprint("identity", __name__)

STATE_FILE = "/var/lib/ghostlink/identity.state"
PROFILES_FILE = "/etc/ghostlink/device_profiles.json"
REPO = "/opt/ghostlink"


def _read_state() -> dict:
    if not os.path.exists(STATE_FILE):
        return {}
    state = {}
    with open(STATE_FILE) as f:
        for line in f:
            if "=" in line:
                k, _, v = line.strip().partition("=")
                state[k] = v
    return state


@bp.get("/api/identity/status")
def status():
    state = _read_state()
    return jsonify(state)


@bp.get("/api/identity/profiles")
def profiles():
    try:
        with open(PROFILES_FILE) as f:
            data = json.load(f)
        return jsonify(list(data.keys()))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@bp.post("/api/identity/rotate")
def rotate():
    body = request.json or {}
    profile = body.get("profile", "random")
    iface = body.get("interface", "gl-upstream")
    r = subprocess.run(
        ["bash", f"{REPO}/identity/rotate.sh", iface, profile],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return jsonify({"error": r.stderr}), 500
    return jsonify({"status": "ok", "output": r.stdout.strip()})


@bp.post("/api/identity/restore")
def restore():
    iface = (request.json or {}).get("interface", "gl-upstream")
    r = subprocess.run(
        ["bash", f"{REPO}/identity/restore.sh", iface],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return jsonify({"error": r.stderr}), 500
    return jsonify({"status": "ok", "output": r.stdout.strip()})
