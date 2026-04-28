#!/usr/bin/env bash
# Configure gl-hotspot — distribution AP
# Renders hostapd + dnsmasq templates and starts services

set -euo pipefail

CONF="/etc/ghostlink/ghostlink.conf"
TEMPLATES="/opt/ghostlink/network/templates"
IFACE="gl-hotspot"
HOTSPOT_IP="192.168.50.1"

ini_get() {
    local section="$1" key="$2"
    awk -F'=' "/^\[${section}\]/{s=1} s && /^${key}=/{print \$2; exit}" "$CONF"
}

HOTSPOT_SSID=$(ini_get hotspot ssid)
HOTSPOT_PASS=$(ini_get hotspot password)
HOTSPOT_CHAN=$(ini_get hotspot channel)
HOTSPOT_CHAN="${HOTSPOT_CHAN:-6}"

# Static IP for the AP
ip addr flush dev "$IFACE" 2>/dev/null || true
ip addr add "${HOTSPOT_IP}/24" dev "$IFACE"
ip link set "$IFACE" up

# Render hostapd config
export HOTSPOT_IFACE="$IFACE"
export HOTSPOT_SSID
export HOTSPOT_PASS
export HOTSPOT_CHAN
envsubst < "$TEMPLATES/hostapd.conf.j2" > /etc/hostapd/hostapd.conf

# Render dnsmasq config
export HOTSPOT_IFACE
envsubst < "$TEMPLATES/dnsmasq.conf.j2" > /etc/dnsmasq.conf

sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' \
    /etc/default/hostapd 2>/dev/null || true

systemctl restart hostapd dnsmasq
echo "gl-hotspot: AP '$HOTSPOT_SSID' on ch${HOTSPOT_CHAN} @ $HOTSPOT_IP"
