"""System stats API."""

import os
import subprocess
from flask import Blueprint, jsonify

bp = Blueprint("system", __name__)


@bp.get("/api/system/stats")
def stats():
    import psutil
    cpu = psutil.cpu_percent(interval=0.5)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage("/")

    # CPU temperature (RPi)
    temp = None
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            temp = round(int(f.read()) / 1000, 1)
    except Exception:
        pass

    return jsonify({
        "cpu_percent": cpu,
        "cpu_temp_c": temp,
        "mem_total_mb": round(mem.total / 1024 / 1024),
        "mem_used_mb": round(mem.used / 1024 / 1024),
        "mem_percent": mem.percent,
        "disk_total_gb": round(disk.total / 1024 / 1024 / 1024, 1),
        "disk_used_gb": round(disk.used / 1024 / 1024 / 1024, 1),
        "disk_percent": disk.percent,
    })


@bp.get("/api/system/services")
def services():
    units = ["gl-identity", "gl-network", "gl-dashboard", "gl-fan",
             "hostapd", "dnsmasq"]
    result = {}
    for unit in units:
        r = subprocess.run(
            ["systemctl", "is-active", unit],
            capture_output=True, text=True,
        )
        result[unit] = r.stdout.strip()
    return jsonify(result)
