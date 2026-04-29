#!/usr/bin/env bash
# WiFi hardware inventory — reads chipset, driver, USB IDs from sysfs
# Outputs KEY=VALUE blocks per interface, separated by ---
# Usage: hw_inventory.sh [text|json]
#
# Role detection (driver-based, not capability-based):
#   brcmfmac         → onboard (gl-mgmt candidate)
#   88XXau / 8812au  → RTL8812AU (gl-upstream candidate)
#   88x2bu / rtl88x2bu → RTL88x2BU (gl-hotspot candidate)

set -euo pipefail

FORMAT="${1:-text}"

role_for_driver() {
    case "${1:-}" in
        brcmfmac|brcmfmac_sdio)            echo "gl-mgmt"    ;;
        88XXau|8812au|rtl8812au)            echo "gl-upstream" ;;
        88x2bu|rtl88x2bu)                   echo "gl-hotspot"  ;;
        8188eu|rtl8188eus|r8188eu)          echo "gl-aux"      ;;
        *)                                   echo ""            ;;
    esac
}

if [[ "$FORMAT" == "json" ]]; then
    python3 - <<'PY'
import os, json

def read(path, default=""):
    try:
        return open(path).read().strip()
    except Exception:
        return default

def usb_id(dev_path):
    curr = dev_path
    while curr and curr != "/":
        v = os.path.join(curr, "idVendor")
        p = os.path.join(curr, "idProduct")
        if os.path.exists(v) and os.path.exists(p):
            return read(v) + ":" + read(p)
        curr = os.path.dirname(curr)
    return ""

result = {}
for name in sorted(os.listdir("/sys/class/net")):
    if not name.startswith("wlan") and not name.startswith("gl-"):
        continue
    base = f"/sys/class/net/{name}"
    mac = read(f"{base}/address")
    drv_link = f"{base}/device/driver"
    driver = os.path.basename(os.path.realpath(drv_link)) if os.path.islink(drv_link) else "unknown"
    dev_path = os.path.realpath(f"{base}/device") if os.path.exists(f"{base}/device") else ""
    itype = "unknown"
    uid = ""
    if "/usb" in dev_path:
        itype = "usb"
        uid = usb_id(dev_path)
    elif any(x in dev_path for x in ["/sdio", "/platform", "/pcie"]):
        itype = "onboard"

    result[name] = {"mac": mac, "driver": driver, "type": itype, "usb_id": uid}

print(json.dumps(result, indent=2))
PY
    exit 0
fi

# Text output
for iface_path in /sys/class/net/wlan* /sys/class/net/gl-*; do
    [[ -e "$iface_path" ]] || continue
    name=$(basename "$iface_path")

    mac=$(cat "$iface_path/address" 2>/dev/null || echo "unknown")

    driver="unknown"
    if [[ -L "$iface_path/device/driver" ]]; then
        driver=$(basename "$(readlink -f "$iface_path/device/driver")")
    fi

    dev_path=$(readlink -f "$iface_path/device" 2>/dev/null || echo "")
    itype="unknown"
    usb_id=""

    if [[ "$dev_path" == *"/usb"* ]]; then
        itype="usb"
        curr="$dev_path"
        while [[ "$curr" != "/" ]]; do
            if [[ -f "$curr/idVendor" && -f "$curr/idProduct" ]]; then
                vid=$(cat "$curr/idVendor" | tr -d '[:space:]')
                pid=$(cat "$curr/idProduct" | tr -d '[:space:]')
                usb_id="${vid}:${pid}"
                break
            fi
            curr=$(dirname "$curr")
        done
    elif [[ "$dev_path" == *"/sdio"* || "$dev_path" == *"/platform"* || "$dev_path" == *"/pcie"* ]]; then
        itype="onboard"
    fi

    role=$(role_for_driver "$driver")

    echo "IFACE=$name"
    echo "MAC=$mac"
    echo "DRIVER=$driver"
    echo "TYPE=$itype"
    echo "USB_ID=$usb_id"
    echo "ROLE=$role"
    echo "---"
done
