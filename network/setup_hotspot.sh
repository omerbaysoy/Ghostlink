#!/usr/bin/env bash
# Configure hotspot AP — RTL88x2BU preferred, RTL8188EUS fallback
# Renders hostapd + dnsmasq configs from ghostlink.conf and starts services
set -euo pipefail

CONF="/etc/ghostlink/ghostlink.conf"
TEMPLATES="/opt/ghostlink/network/templates"

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

# ── Resolve effective hotspot interface ──────────────────────────────────────
# Preferred: gl-hotspot (RTL88x2BU). Fallback: gl-aux (RTL8188EUS) when
# gl-hotspot is missing and aux.fallback_hotspot=true in config.

PREFERRED_IFACE="gl-hotspot"
AUX_IFACE="gl-aux"
HOTSPOT_IP="192.168.50.1"
FALLBACK_ACTIVE=false

if [[ -d "/sys/class/net/$PREFERRED_IFACE" ]]; then
    IFACE="$PREFERRED_IFACE"
    log "Using preferred hotspot interface: $IFACE (RTL88x2BU)"
else
    log_warn "$PREFERRED_IFACE not found (RTL88x2BU adapter missing or not enumerated)"
    FALLBACK=$(ini_get aux fallback_hotspot "false")
    if [[ "$FALLBACK" == "true" && -d "/sys/class/net/$AUX_IFACE" ]]; then
        IFACE="$AUX_IFACE"
        FALLBACK_ACTIVE=true
        log_warn "Falling back to $IFACE (RTL8188EUS) — performance may be lower"
    else
        log_err "$PREFERRED_IFACE not found — RTL88x2BU adapter not detected"
        log_err "Plug in the adapter and rerun: ghostlink hotspot start"
        if [[ -d "/sys/class/net/$AUX_IFACE" ]]; then
            log_warn "RTL8188EUS ($AUX_IFACE) is present but fallback_hotspot=false"
            log_warn "Enable: set [aux] fallback_hotspot=true in $CONF"
        fi
        exit 1
    fi
fi

# Save effective hotspot interface for NAT to read
mkdir -p /run/ghostlink
echo "HOTSPOT_IFACE=$IFACE" > /run/ghostlink/hotspot.state
echo "FALLBACK=$FALLBACK_ACTIVE" >> /run/ghostlink/hotspot.state

# ── Verify AP mode support ────────────────────────────────────────────────────
phy=$(iw dev "$IFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
if [[ -n "$phy" ]]; then
    if ! iw phy "$phy" info 2>/dev/null | awk '
        /Supported interface modes:/{found=1; next}
        found && /\* AP/{ok=1}
        found && /Supported commands:/{found=0}
        END{exit ok ? 0 : 1}
    '; then
        log_err "$IFACE ($phy) does not report AP mode support"
        log_err "Ensure the correct driver is loaded (88x2bu for RTL88x2BU, 8188eu for RTL8188EUS)"
        log_err "Check: iw phy $phy info | grep -A20 'interface modes'"
        exit 1
    fi
    log_ok "$IFACE supports AP mode ($phy)$($FALLBACK_ACTIVE && echo ' [fallback]' || echo '')"
fi

# ── Read config ───────────────────────────────────────────────────────────────
HOTSPOT_SSID=$(ini_get hotspot ssid "Ghostlink-AP")
HOTSPOT_PASS=$(ini_get hotspot password "ghostlink1234")
HOTSPOT_CHAN=$(ini_get hotspot channel "6")

if [[ "${#HOTSPOT_PASS}" -lt 8 ]]; then
    log_err "Hotspot password must be at least 8 characters"
    exit 1
fi

# ── Assign static IP ──────────────────────────────────────────────────────────
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
systemctl restart dnsmasq  || { log_err "dnsmasq failed — check: journalctl -u dnsmasq"; exit 1; }
systemctl unmask hostapd 2>/dev/null || true
systemctl restart hostapd  || { log_err "hostapd failed — check: journalctl -u hostapd"; exit 1; }

if $FALLBACK_ACTIVE; then
    log_ok "Hotspot '$HOTSPOT_SSID' running on $IFACE (gl-aux fallback) ch${HOTSPOT_CHAN} @ $HOTSPOT_IP"
else
    log_ok "Hotspot '$HOTSPOT_SSID' running on $IFACE ch${HOTSPOT_CHAN} @ $HOTSPOT_IP"
fi
