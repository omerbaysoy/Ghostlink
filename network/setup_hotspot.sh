#!/usr/bin/env bash
# Configure gl-hotspot (RTL88x2BU) as the distribution AP
# Renders hostapd + dnsmasq configs from ghostlink.conf and starts services
set -euo pipefail

CONF="/etc/ghostlink/ghostlink.conf"
TEMPLATES="/opt/ghostlink/network/templates"
IFACE="gl-hotspot"
HOTSPOT_IP="192.168.50.1"

log()     { echo "  [hotspot] $*"; }
log_ok()  { echo "  [hotspot] ✓ $*"; }
log_err() { echo "  [hotspot] ✗ $*" >&2; }
log_warn(){ echo "  [hotspot] ⚠ $*"; }

ini_get() {
    local section="$1" key="$2" default="${3:-}"
    local val
    val=$(awk -F'=' "/^\[${section}\]/{s=1} s && /^${key}=/{print \$2; exit}" "$CONF" 2>/dev/null)
    echo "${val:-$default}"
}

# ── Verify interface and AP mode support ──────────────────────────────────────
if ! [[ -d "/sys/class/net/$IFACE" ]]; then
    log_err "$IFACE not found — is RTL88x2BU adapter plugged in?"
    log_err "Plug in the adapter and rerun: ghostlink hotspot start"
    exit 1
fi

# Check AP mode capability via iw
phy=$(iw dev "$IFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
if [[ -n "$phy" ]]; then
    if ! iw phy "$phy" info 2>/dev/null | awk '
        /Supported interface modes:/{found=1; next}
        found && /\* AP/{ok=1}
        found && /Supported commands:/{found=0}
        END{exit ok ? 0 : 1}
    '; then
        log_err "$IFACE ($phy) does not report AP mode support"
        log_err "Ensure RTL88x2BU (88x2bu driver) is loaded correctly"
        log_err "Check: iw phy $phy info | grep -A20 'interface modes'"
        exit 1
    fi
    log_ok "$IFACE supports AP mode ($phy)"
fi

# ── Read config ───────────────────────────────────────────────────────────────
HOTSPOT_SSID=$(ini_get hotspot ssid "GhostNet")
HOTSPOT_PASS=$(ini_get hotspot password "changeme")
HOTSPOT_CHAN=$(ini_get hotspot channel "6")

if [[ "${#HOTSPOT_PASS}" -lt 8 ]]; then
    log_err "Hotspot password must be at least 8 characters"
    exit 1
fi

# ── Assign static IP to hotspot interface ─────────────────────────────────────
ip addr flush dev "$IFACE" 2>/dev/null || true
ip addr add "${HOTSPOT_IP}/24" dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up

# ── Render configs ────────────────────────────────────────────────────────────
mkdir -p /etc/hostapd

export HOTSPOT_IFACE="$IFACE"
export HOTSPOT_SSID
export HOTSPOT_PASS
export HOTSPOT_CHAN

envsubst < "$TEMPLATES/hostapd.conf.j2" > /etc/hostapd/hostapd.conf
envsubst < "$TEMPLATES/dnsmasq.conf.j2" > /etc/dnsmasq.conf

# Ensure hostapd picks up the config file
sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' \
    /etc/default/hostapd 2>/dev/null || true

# ── Start services ────────────────────────────────────────────────────────────
systemctl restart dnsmasq  || { log_err "dnsmasq failed to start — check: journalctl -u dnsmasq"; exit 1; }
systemctl unmask hostapd 2>/dev/null || true
systemctl restart hostapd  || { log_err "hostapd failed to start — check: journalctl -u hostapd"; exit 1; }

log_ok "Hotspot '$HOTSPOT_SSID' running on ch${HOTSPOT_CHAN} @ $HOTSPOT_IP"
log_ok "Clients connect to: $HOTSPOT_SSID (password: [configured])"
